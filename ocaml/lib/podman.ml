open Async
open Core

type image = { reference : string; id : string }
type candidate = { name : string; id : string }
type secret_mount = { source : string; target : string }

type runtime_container = {
  name : string;
  id : string;
  revision : string option;
  operation_id : string option;
  started_at : string option;
}

type log_line = { timestamp : string option; text : string }
type log_snapshot = { lines : log_line list; truncated : bool }
type runtime_stats = { cpu_percent : float option; memory_used_bytes : int64 }

let podman_timeout = Time_ns.Span.of_min 5.
let build_timeout = Time_ns.Span.of_hr 1.
let max_output = 1_048_576
let image_reference (image : image) = image.reference
let image_id (image : image) = image.id
let candidate_name (candidate : candidate) = candidate.name
let candidate_id (candidate : candidate) = candidate.id
let runtime_container_name container = container.name
let runtime_container_id container = container.id
let runtime_container_revision container = container.revision
let runtime_container_operation_id container = container.operation_id
let runtime_container_started_at container = container.started_at

let run ?stdin ?ignore_termination ?(timeout = podman_timeout) args =
  Process_runner.run ?stdin ?ignore_termination ~timeout
    ~max_output_bytes:max_output ~prog:"podman" ~args ()

let run_ok ?stdin ?ignore_termination ?timeout ?(redact = Fn.id) args =
  let open Deferred.Or_error.Let_syntax in
  let%bind result = run ?stdin ?ignore_termination ?timeout args in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result
  | Error failure ->
      Deferred.Or_error.errorf "podman failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr |> redact)

let list_connections () =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    run_ok [ "system"; "connection"; "list"; "--format"; "json" ]
  in
  Deferred.return (Podman_connection.all_of_json result.stdout)

type remote_ownership = {
  remote_resource_key : string;
  remote_repository : string option;
}

let remote_ownerships_of_containers output =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  let label labels name =
    match List.Assoc.find labels ~equal:String.equal name with
    | Some (`String value) when not (String.is_empty value) -> Some value
    | _ -> None
  in
  match json with
  | `List containers ->
      List.filter_map containers ~f:(function
        | `Assoc container -> (
            match List.Assoc.find container ~equal:String.equal "Labels" with
            | Some (`Assoc labels) ->
                label labels "io.nixploy.resource_key"
                |> Option.map ~f:(fun remote_resource_key ->
                    {
                      remote_resource_key;
                      remote_repository =
                        Option.first_some
                          (label labels "io.nixploy.repository_identity")
                          (Option.first_some
                             (label labels "io.nixploy.repository")
                             (label labels "nixploy.repository"));
                    })
            | _ -> None)
        | _ -> None)
      |> Or_error.return
  | _ -> Or_error.error_string "remote Podman list must be a JSON array"

let resource_keys_of_containers output =
  let open Or_error.Let_syntax in
  let%map ownerships = remote_ownerships_of_containers output in
  List.map ownerships ~f:(fun ownership -> ownership.remote_resource_key)
  |> List.dedup_and_sort ~compare:String.compare

let discover_remote_resource_keys ~project ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 30.)
      ~max_output_bytes:max_output
      [
        "podman";
        "ps";
        "-a";
        "--filter";
        "label=io.nixploy.managed=true";
        "--filter";
        "label=io.nixploy.project=" ^ Project_name.to_string project;
        "--filter";
        "label=io.nixploy.target="
        ^ (Configuration.Target.name target |> Target_name.to_string);
        "--format";
        "json";
      ]
  in
  match result.exit_status with
  | Ok () -> Deferred.return (remote_ownerships_of_containers result.stdout)
  | Error failure ->
      Deferred.Or_error.errorf "remote Podman discovery failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let select_resource_key ~project ~target ~repository_identity ~candidates =
  let open Deferred.Or_error.Let_syntax in
  let candidates =
    List.fold candidates ~init:[] ~f:(fun keys key ->
        if List.mem keys key ~equal:Resource_key.equal then keys
        else key :: keys)
    |> List.rev
  in
  let canonical =
    match candidates with
    | canonical :: _ -> canonical
    | [] -> raise_s [%message "resource key candidates must not be empty"]
  in
  let%bind remote_ownerships = discover_remote_resource_keys ~project ~target in
  let missing_repository =
    List.exists remote_ownerships ~f:(fun ownership ->
        Option.is_none ownership.remote_repository)
  in
  if missing_repository then
    Deferred.Or_error.error_string
      "remote workload lacks repository ownership metadata"
  else
    let requested_ownerships =
      List.filter remote_ownerships ~f:(fun ownership ->
          Option.equal String.equal ownership.remote_repository
            (Some repository_identity))
    in
    let recognize ownership =
      List.find candidates ~f:(fun key ->
          String.equal
            (Resource_key.to_string key)
            ownership.remote_resource_key)
      |> Option.map ~f:(fun key -> (key, ownership))
    in
    let unexpected =
      List.exists requested_ownerships ~f:(fun ownership ->
          Option.is_none (recognize ownership))
    in
    if unexpected then
      Deferred.Or_error.error_string
        "remote workloads owned by this repository use an unexpected resource \
         identity"
    else
      let recognized = List.filter_map requested_ownerships ~f:recognize in
      let recognized_keys =
        List.map recognized ~f:fst
        |> List.dedup_and_sort ~compare:Resource_key.compare
      in
      match recognized_keys with
      | _ :: _ :: _ ->
          Deferred.Or_error.error_string
            "multiple recognized workload identities exist for this repository \
             and target"
      | [ selected ] -> Deferred.Or_error.return selected
      | [] -> (
          let%bind connections = list_connections () in
          let safe_connection_candidates =
            List.filter candidates ~f:(fun key ->
                not
                  (Resource_key.equal key
                     (List.nth candidates 1 |> Option.value ~default:canonical)))
          in
          let matching =
            List.filter safe_connection_candidates ~f:(fun key ->
                Podman_connection.find_by_name connections
                  (Resource_key.to_string key)
                |> Option.is_some)
          in
          match matching with
          | _ :: _ :: _ ->
              Deferred.Or_error.error_string
                "multiple recognized Podman connections exist for this target"
          | [ selected ] -> Deferred.Or_error.return selected
          | [] -> Deferred.Or_error.return canonical)

let verify_ssh target =
  let open Deferred.Or_error.Let_syntax in
  let%bind preflight =
    Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 30.)
      ~max_output_bytes:65_536 [ "true" ]
  in
  match preflight.exit_status with
  | Ok () -> Deferred.Or_error.return ()
  | Error failure ->
      Deferred.Or_error.errorf "SSH preflight failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip preflight.stderr)

let remove_connection ~name =
  let%map result = run_ok [ "system"; "connection"; "remove"; name ] in
  Or_error.map result ~f:(fun _ -> ())

let add_connection ~target ~name ~identity =
  let identity_args =
    Option.value_map identity ~default:[] ~f:(fun path ->
        [ "--identity"; path ])
  in
  let%map result =
    run_ok
      ([
         "system";
         "connection";
         "add";
         name;
         "--port";
         Int.to_string (Configuration.Target.port target);
       ]
      @ identity_args
      @ [
          Configuration.Target.user target
          ^ "@"
          ^ Configuration.Target.host target;
        ])
  in
  Or_error.map result ~f:(fun _ -> ())

let ensure_connection ~target ~resource_key =
  let open Deferred.Or_error.Let_syntax in
  let name = Resource_key.to_string resource_key in
  let identity =
    match Sys.getenv "SSH_AUTH_SOCK" with
    | Some socket when not (String.is_empty (String.strip socket)) -> None
    | _ -> Remote_command.identity_file target
  in
  let%bind connections = list_connections () in
  let%bind () =
    match Podman_connection.find_by_name connections name with
    | Some connection
      when Podman_connection.matches_target connection target
           && Podman_connection.matches_identity connection identity ->
        Deferred.Or_error.return ()
    | Some _ ->
        let%bind () = verify_ssh target in
        let%bind () = remove_connection ~name in
        add_connection ~target ~name ~identity
    | None ->
        let%bind () = verify_ssh target in
        add_connection ~target ~name ~identity
  in
  let%map _ = run_ok [ "--connection"; name; "info" ] in
  name

let loaded_reference output =
  let prefixes = [ "Loaded image: "; "Loaded image(s): " ] in
  String.split_lines output
  |> List.find_map ~f:(fun line ->
      let line = String.strip line in
      List.find_map prefixes ~f:(fun prefix ->
          if String.Caseless.is_prefix line ~prefix then
            Some (String.drop_prefix line (String.length prefix) |> String.strip)
          else None))
  |> function
  | Some reference when not (String.is_empty reference) -> Ok reference
  | _ ->
      Or_error.error_string "Podman did not report the loaded image reference"

let image_id_of_inspect output =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  match json with
  | `List [ `Assoc fields ] -> (
      match List.Assoc.find fields ~equal:String.equal "Id" with
      | Some (`String id) when not (String.is_empty id) -> Ok id
      | _ -> Or_error.error_string "loaded image inspect is missing Id")
  | _ ->
      Or_error.error_string
        "loaded image inspect must contain exactly one image"

let build_and_load ~connection ~source ~image_output =
  let open Deferred.Or_error.Let_syntax in
  let%bind build =
    Process_runner.run ~working_directory:(Source.path source)
      ~timeout:build_timeout ~max_output_bytes:max_output ~prog:"nix"
      ~args:
        [
          "build";
          "--no-update-lock-file";
          "--no-write-lock-file";
          "path:.#" ^ image_output;
          "--print-out-paths";
          "--no-link";
        ]
      ()
  in
  let%bind output_path =
    match build.exit_status with
    | Error failure ->
        Deferred.Or_error.errorf "Nix image build failed (%s): %s"
          (Core_unix.Exit_or_signal.to_string_hum (Error failure))
          (String.strip build.stderr)
    | Ok () -> (
        match
          String.split_lines build.stdout
          |> List.filter ~f:(Fn.non String.is_empty)
        with
        | [ path ] when String.is_prefix path ~prefix:"/nix/store/" ->
            Deferred.Or_error.return path
        | _ ->
            Deferred.Or_error.error_string
              "Nix build did not return one store path")
  in
  let%bind loaded =
    run_ok [ "--connection"; connection; "load"; "-i"; output_path ]
  in
  let%bind reference = Deferred.return (loaded_reference loaded.stdout) in
  let%bind inspected =
    run_ok
      [ "--connection"; connection; "inspect"; "--type"; "image"; reference ]
  in
  let%map id = Deferred.return (image_id_of_inspect inspected.stdout) in
  { reference; id }

let labels fields =
  List.concat_map fields ~f:(fun (name, value) ->
      [ "--label"; name ^ "=" ^ value ])

let inspect_container ?ignore_termination ~connection name =
  run_ok ?ignore_termination
    [ "--connection"; connection; "inspect"; "--type"; "container"; name ]

let label fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) -> Some value
  | _ -> None

let has_label fields name =
  List.Assoc.find fields ~equal:String.equal name |> Option.is_some

let owned_container output ~project ~target ~resource_key =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  match json with
  | `List [ `Assoc container ] -> (
      match List.Assoc.find container ~equal:String.equal "Config" with
      | Some (`Assoc config) -> (
          match List.Assoc.find config ~equal:String.equal "Labels" with
          | Some (`Assoc labels) ->
              Ok
                (Option.equal String.equal
                   (label labels "io.nixploy.managed")
                   (Some "true")
                && Option.equal String.equal
                     (label labels "io.nixploy.project")
                     (Some (Project_name.to_string project))
                && Option.equal String.equal
                     (label labels "io.nixploy.target")
                     (Some
                        (Target_name.to_string
                           (Configuration.Target.name target)))
                && Option.equal String.equal
                     (label labels "io.nixploy.resource_key")
                     (Some (Resource_key.to_string resource_key)))
          | _ -> Ok false)
      | _ -> Ok false)
  | _ ->
      Or_error.error_string
        "container inspect must contain exactly one container"

let owned_operation output ~project ~target ~resource_key ~operation_id =
  let open Or_error.Let_syntax in
  let%bind owned = owned_container output ~project ~target ~resource_key in
  if not owned then Ok false
  else
    let%bind json =
      Or_error.try_with (fun () -> Yojson.Safe.from_string output)
    in
    match json with
    | `List [ `Assoc container ] -> (
        match List.Assoc.find container ~equal:String.equal "Config" with
        | Some (`Assoc config) -> (
            match List.Assoc.find config ~equal:String.equal "Labels" with
            | Some (`Assoc labels) ->
                Ok
                  (Option.equal String.equal
                     (label labels "io.nixploy.operation_id")
                     (Some operation_id))
            | _ -> Ok false)
        | _ -> Ok false)
    | _ ->
        Or_error.error_string
          "container inspect must contain exactly one container"

let owned_candidate_collision output ~project ~target ~resource_key =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  match json with
  | `List [ `Assoc container ] -> (
      match List.Assoc.find container ~equal:String.equal "Config" with
      | Some (`Assoc config) -> (
          match List.Assoc.find config ~equal:String.equal "Labels" with
          | Some (`Assoc labels) ->
              let modern_managed = label labels "io.nixploy.managed" in
              let modern_project = label labels "io.nixploy.project" in
              let modern_target = label labels "io.nixploy.target" in
              let modern_resource = label labels "io.nixploy.resource_key" in
              if
                List.exists
                  [
                    "io.nixploy.managed";
                    "io.nixploy.project";
                    "io.nixploy.target";
                    "io.nixploy.resource_key";
                  ]
                  ~f:(has_label labels)
              then
                Ok
                  (Option.equal String.equal modern_managed (Some "true")
                  && Option.equal String.equal modern_resource
                       (Some (Resource_key.to_string resource_key))
                  && Option.equal String.equal modern_project
                       (Some (Project_name.to_string project))
                  && Option.equal String.equal modern_target
                       (Some
                          (Configuration.Target.name target
                          |> Target_name.to_string)))
              else
                Ok
                  (Option.equal String.equal
                     (label labels "nixploy.project")
                     (Some (Project_name.to_string project))
                  && Option.equal String.equal
                       (label labels "nixploy.target")
                       (Some
                          (Configuration.Target.name target
                          |> Target_name.to_string)))
          | _ -> Ok false)
      | _ -> Ok false)
  | _ ->
      Or_error.error_string
        "container inspect must contain exactly one container"

let repository_owned output ~repository_identity =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  match json with
  | `List [ `Assoc container ] -> (
      match List.Assoc.find container ~equal:String.equal "Config" with
      | Some (`Assoc config) -> (
          match List.Assoc.find config ~equal:String.equal "Labels" with
          | Some (`Assoc labels) ->
              let repository =
                Option.first_some
                  (label labels "io.nixploy.repository_identity")
                  (Option.first_some
                     (label labels "io.nixploy.repository")
                     (label labels "nixploy.repository"))
              in
              Ok
                (Option.equal String.equal repository (Some repository_identity))
          | _ -> Ok false)
      | _ -> Ok false)
  | _ ->
      Or_error.error_string
        "container inspect must contain exactly one container"

let find_owned_placement ~connection ~project ~target ~resource_key
    ~repository_identity ~placement =
  let open Deferred.Or_error.Let_syntax in
  let name = Deployment_plan.container_name ~resource_key placement in
  let%bind exists =
    run [ "--connection"; connection; "container"; "exists"; name ]
  in
  match exists.exit_status with
  | Error (`Exit_non_zero 1) -> Deferred.Or_error.return None
  | Error failure ->
      Deferred.Or_error.errorf "could not inspect deployment placement (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip exists.stderr)
  | Ok () -> (
      let%bind inspected = inspect_container ~connection name in
      let%bind owned =
        Deferred.return
          (let open Or_error.Let_syntax in
           let%bind target_owned =
             owned_candidate_collision inspected.stdout ~project ~target
               ~resource_key
           in
           let%map repository_owned =
             repository_owned inspected.stdout ~repository_identity
           in
           target_owned && repository_owned)
      in
      if not owned then
        Deferred.Or_error.errorf
          "container %s exists but is not owned by this repository and target"
          name
      else
        let%bind json =
          Deferred.return
            (Or_error.try_with (fun () ->
                 Yojson.Safe.from_string inspected.stdout))
        in
        match json with
        | `List [ `Assoc container ] -> (
            match List.Assoc.find container ~equal:String.equal "Id" with
            | Some (`String id) when not (String.is_empty id) ->
                Deferred.Or_error.return (Some { name; id })
            | _ ->
                Deferred.Or_error.error_string
                  "deployment placement inspect did not contain an ID")
        | _ ->
            Deferred.Or_error.error_string
              "deployment placement inspect must contain exactly one container")

let remove_owned_placement ~connection ~project ~target ~resource_key
    ~repository_identity ~placement =
  let open Deferred.Or_error.Let_syntax in
  let%bind candidate =
    find_owned_placement ~connection ~project ~target ~resource_key
      ~repository_identity ~placement
  in
  match candidate with
  | None -> Deferred.Or_error.return ()
  | Some candidate ->
      let%map _ =
        run_ok [ "--connection"; connection; "rm"; "-f"; candidate.id ]
      in
      ()

let prepare_candidate = remove_owned_placement

type prune_container = { prune_id : string; prune_name : string }

type prepared_prune = {
  prune_connection : string;
  prune_containers : prune_container list;
  prune_secret_names : string list;
}

let secret_names_of_json output =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  let secret_name = function
    | `Assoc fields -> (
        match List.Assoc.find fields ~equal:String.equal "Name" with
        | Some (`String name) when not (String.is_empty name) -> Ok name
        | _ -> (
            match List.Assoc.find fields ~equal:String.equal "Spec" with
            | Some (`Assoc spec) -> (
                match List.Assoc.find spec ~equal:String.equal "Name" with
                | Some (`String name) when not (String.is_empty name) -> Ok name
                | _ -> Or_error.error_string "Podman secret is missing its name"
                )
            | _ -> Or_error.error_string "Podman secret is missing its name"))
    | _ -> Or_error.error_string "Podman secret list entry must be an object"
  in
  match json with
  | `List secrets -> Or_error.all (List.map secrets ~f:secret_name)
  | _ -> Or_error.error_string "Podman secret list must be a JSON array"

let inspect_prune_container ~connection ~project ~target ~resource_key name =
  let open Deferred.Or_error.Let_syntax in
  let%bind exists =
    run [ "--connection"; connection; "container"; "exists"; name ]
  in
  match exists.exit_status with
  | Error (`Exit_non_zero 1) -> Deferred.Or_error.return None
  | Error failure ->
      Deferred.Or_error.errorf "could not inspect prune container (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip exists.stderr)
  | Ok () -> (
      let%bind inspected = inspect_container ~connection name in
      let%bind owned =
        Deferred.return
          (owned_candidate_collision inspected.stdout ~project ~target
             ~resource_key)
      in
      if not owned then
        Deferred.Or_error.errorf
          "container %s exists but is not owned by this target" name
      else
        let%bind json =
          Deferred.return
            (Or_error.try_with (fun () ->
                 Yojson.Safe.from_string inspected.stdout))
        in
        match json with
        | `List [ `Assoc fields ] -> (
            match List.Assoc.find fields ~equal:String.equal "Id" with
            | Some (`String id) when not (String.is_empty id) ->
                Deferred.Or_error.return
                  (Some { prune_id = id; prune_name = name })
            | _ ->
                Deferred.Or_error.errorf
                  "container %s inspect did not contain an ID" name)
        | _ ->
            Deferred.Or_error.errorf
              "container %s inspect must contain exactly one container" name)

let preflight_prune_owned_resources ~connection ~project ~target ~resource_key =
  let open Deferred.Or_error.Let_syntax in
  let plan = Prune_plan.create ~resource_key in
  let%bind prune_containers =
    Deferred.Or_error.List.filter_map
      (Prune_plan.container_names plan)
      ~how:`Sequential
      ~f:(inspect_prune_container ~connection ~project ~target ~resource_key)
  in
  let%bind listed =
    run_ok [ "--connection"; connection; "secret"; "ls"; "--format"; "json" ]
  in
  let%map all_secret_names =
    Deferred.return (secret_names_of_json listed.stdout)
  in
  {
    prune_connection = connection;
    prune_containers;
    prune_secret_names = Prune_plan.select_secret_names plan all_secret_names;
  }

let execute_prepared_prune prepared =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    Deferred.Or_error.List.iter prepared.prune_containers ~how:`Sequential
      ~f:(fun container ->
        let%map _ =
          run_ok
            [
              "--connection";
              prepared.prune_connection;
              "rm";
              "-f";
              container.prune_id;
            ]
          |> Deferred.map
               ~f:
                 (Or_error.tag
                    ~tag:
                      (sprintf "could not remove owned container %s"
                         container.prune_name))
        in
        ())
  in
  let%map () =
    Deferred.Or_error.List.iter prepared.prune_secret_names ~how:`Sequential
      ~f:(fun name ->
        let%map _ =
          run_ok
            [ "--connection"; prepared.prune_connection; "secret"; "rm"; name ]
          |> Deferred.map
               ~f:
                 (Or_error.tag
                    ~tag:(sprintf "could not remove owned secret %s" name))
        in
        ())
  in
  ( List.length prepared.prune_containers,
    List.length prepared.prune_secret_names )

let find_owned_slot ~connection ~project ~target ~resource_key
    ~repository_identity ~slot =
  find_owned_placement ~connection ~project ~target ~resource_key
    ~repository_identity
    ~placement:(Deployment_plan.Web_slot { slot; port = 0 })

let secret_args secret_mounts =
  List.concat_map secret_mounts ~f:(fun secret ->
      [
        "--secret";
        sprintf "source=%s,type=env,target=%s" secret.source secret.target;
      ])

let install_secrets ~connection ~resource_key ~secrets =
  let open Deferred.Or_error.Let_syntax in
  let redact = Secrets.redact secrets in
  Deferred.Or_error.List.map secrets ~how:`Sequential ~f:(fun secret ->
      let remote_name =
        Resource_key.to_string resource_key ^ "-" ^ Secrets.name secret
      in
      let%bind _ =
        run [ "--connection"; connection; "secret"; "rm"; remote_name ]
      in
      let%map _ =
        run_ok ~stdin:(Secrets.value secret) ~redact
          [ "--connection"; connection; "secret"; "create"; remote_name; "-" ]
      in
      { source = remote_name; target = Secrets.name secret })

let runtime_args ?(include_ports = true) run ~port =
  let network =
    Configuration.Run.network run
    |> Option.value_map ~default:[] ~f:(fun network -> [ "--network"; network ])
  in
  let environment =
    Configuration.Run.rendered_environment run ~port
    |> List.concat_map ~f:(fun (name, value) -> [ "-e"; name ^ "=" ^ value ])
  in
  let ports =
    if include_ports then
      Configuration.Run.ports run
      |> List.concat_map ~f:(fun mapping -> [ "-p"; mapping ])
    else []
  in
  network @ environment @ ports

let pre_start_argvs ~connection ~run:run_config ~port ~secret_args
    ~image_reference =
  List.map (Configuration.Run.pre_start run_config) ~f:(fun command ->
      [ "--connection"; connection; "run"; "--rm" ]
      @ secret_args
      @ runtime_args ~include_ports:false run_config ~port
      @ [ image_reference ] @ command)

let runtime_argv ~connection ~name ~run:run_config ~port ~secret_args
    ~labels:metadata ~image_reference =
  let command =
    Configuration.Run.command run_config |> Option.value ~default:[]
  in
  [ "--connection"; connection; "run"; "-d"; "--name"; name ]
  @ secret_args
  @ runtime_args run_config ~port
  @ labels metadata @ [ image_reference ] @ command

let run_pre_start ~connection ~target ~placement ~image ~secrets ~secret_mounts
    =
  let open Deferred.Or_error.Let_syntax in
  let run_config = Configuration.Target.run target in
  let port = Deployment_plan.runtime_port placement in
  Deferred.Or_error.List.iter
    (pre_start_argvs ~connection ~run:run_config ~port
       ~secret_args:(secret_args secret_mounts)
       ~image_reference:image.reference)
    ~how:`Sequential
    ~f:(fun argv ->
      let%map _ = run_ok ~redact:(Secrets.redact secrets) argv in
      ())

let project_id repository =
  Digestif.SHA256.digest_string repository |> Digestif.SHA256.to_hex
  |> fun digest -> String.prefix digest 10

let cleanup_ambiguous_start ~connection ~project ~target ~resource_key
    ~operation_id ~name =
  let rec attempt remaining =
    let open Deferred.Or_error.Let_syntax in
    let%bind exists =
      run ~ignore_termination:true
        [ "--connection"; connection; "container"; "exists"; name ]
    in
    match exists.exit_status with
    | Error (`Exit_non_zero 1) when remaining > 1 ->
        let%bind.Deferred () = Clock_ns.after (Time_ns.Span.of_ms 200.) in
        attempt (remaining - 1)
    | Error (`Exit_non_zero 1) -> Deferred.Or_error.return ()
    | Error failure ->
        Deferred.Or_error.errorf
          "could not inspect ambiguous candidate launch (%s): %s"
          (Core_unix.Exit_or_signal.to_string_hum (Error failure))
          (String.strip exists.stderr)
    | Ok () ->
        let%bind inspected =
          inspect_container ~ignore_termination:true ~connection name
        in
        let%bind owned =
          Deferred.return
            (owned_operation inspected.stdout ~project ~target ~resource_key
               ~operation_id)
        in
        if not owned then
          Deferred.Or_error.errorf
            "ambiguous candidate %s is not owned by this operation" name
        else
          let%map _ =
            run_ok ~ignore_termination:true
              [ "--connection"; connection; "rm"; "-f"; name ]
          in
          ()
  in
  attempt 10

let start_candidate ~connection ~project ~target ~resource_key ~placement
    ~source ~configuration_digest ~operation_id ~deployed_at ~image ~secrets
    ~secret_mounts =
  let name = Deployment_plan.container_name ~resource_key placement in
  let port = Deployment_plan.runtime_port placement in
  let target_name = Configuration.Target.name target |> Target_name.to_string in
  let project_name = Project_name.to_string project in
  let repository = Source.repository source in
  let metadata =
    [
      ("nixploy.project", project_name);
      ("nixploy.project_id", project_id repository);
      ("nixploy.target", target_name);
      ("nixploy.repository", repository);
      ("nixploy.git_commit", Source.revision source);
      ("nixploy.deployed_at", deployed_at);
      ("io.nixploy.managed", "true");
      ("io.nixploy.project", project_name);
      ("io.nixploy.target", target_name);
      ("io.nixploy.repository", repository);
      ("io.nixploy.repository_identity", repository);
      ("io.nixploy.revision", Source.revision source);
      ("io.nixploy.deployed_at", deployed_at);
      ("io.nixploy.configuration_digest", configuration_digest);
      ("io.nixploy.operation_id", operation_id);
      ("io.nixploy.resource_key", Resource_key.to_string resource_key);
      ("org.opencontainers.image.source", repository);
      ("org.opencontainers.image.revision", Source.revision source);
    ]
  in
  let run_config = Configuration.Target.run target in
  let argv =
    runtime_argv ~connection ~name ~run:run_config ~port
      ~secret_args:(secret_args secret_mounts)
      ~labels:metadata ~image_reference:image.reference
  in
  let%bind.Deferred started = run_ok ~redact:(Secrets.redact secrets) argv in
  let started =
    Or_error.bind started ~f:(fun started ->
        let id = String.strip started.stdout in
        if String.is_empty id then
          Or_error.error_string "Podman did not return a container ID"
        else Or_error.return { name; id })
  in
  match started with
  | Ok candidate -> Deferred.Or_error.return candidate
  | Error primary -> (
      let%map.Deferred cleanup =
        cleanup_ambiguous_start ~connection ~project ~target ~resource_key
          ~operation_id ~name
      in
      match cleanup with
      | Ok () -> Error primary
      | Error cleanup ->
          Cancellation.mark_cleanup_failed ();
          Error
            (Error.create_s [%message (primary : Error.t) (cleanup : Error.t)]))

let verify_candidate ~connection ~project ~target ~resource_key ~source
    ~configuration_digest ~operation_id ~(image : image)
    ~(candidate : candidate) =
  let open Deferred.Or_error.Let_syntax in
  let%bind inspected = inspect_container ~connection candidate.name in
  let%bind json =
    Deferred.return
      (Or_error.try_with (fun () -> Yojson.Safe.from_string inspected.stdout))
  in
  match json with
  | `List [ `Assoc container ] ->
      let string_field fields name =
        match List.Assoc.find fields ~equal:String.equal name with
        | Some (`String value) -> Some value
        | _ -> None
      in
      let valid =
        Option.equal String.equal
          (string_field container "Id")
          (Some candidate.id)
        && Option.equal String.equal
             (string_field container "Name")
             (Some candidate.name)
        && Option.equal String.equal
             (string_field container "Image")
             (Some image.id)
        &&
        match List.Assoc.find container ~equal:String.equal "State" with
        | Some (`Assoc state) -> (
            match List.Assoc.find state ~equal:String.equal "Running" with
            | Some (`Bool true) -> true
            | _ -> false)
        | _ -> false
      in
      let%bind owned =
        Deferred.return
          (owned_container inspected.stdout ~project ~target ~resource_key)
      in
      let identity_valid =
        match List.Assoc.find container ~equal:String.equal "Config" with
        | Some (`Assoc config) -> (
            match List.Assoc.find config ~equal:String.equal "Labels" with
            | Some (`Assoc labels) ->
                Option.equal String.equal
                  (label labels "io.nixploy.revision")
                  (Some (Source.revision source))
                && Option.equal String.equal
                     (label labels "io.nixploy.configuration_digest")
                     (Some configuration_digest)
                && Option.equal String.equal
                     (label labels "io.nixploy.operation_id")
                     (Some operation_id)
            | _ -> false)
        | _ -> false
      in
      if valid && owned && identity_valid then Deferred.Or_error.return ()
      else
        Deferred.Or_error.error_string
          "candidate container readback did not match"
  | _ ->
      Deferred.Or_error.error_string
        "candidate inspect must contain exactly one container"

let remove_candidate ~connection ~(candidate : candidate) =
  let%bind.Deferred removed =
    run_ok ~ignore_termination:true
      [ "--connection"; connection; "rm"; "-f"; candidate.id ]
  in
  match removed with
  | Ok _ -> Deferred.Or_error.return ()
  | Error removal_error -> (
      let%map.Deferred exists =
        run ~ignore_termination:true
          [ "--connection"; connection; "container"; "exists"; candidate.id ]
      in
      match exists with
      | Ok { exit_status = Error (`Exit_non_zero 1); _ } -> Ok ()
      | _ -> Error removal_error)

let runtime_container_of_inspect output ~project ~target ~resource_key
    ~repository_identity ~expected_name =
  let open Or_error.Let_syntax in
  let%bind owned = owned_container output ~project ~target ~resource_key in
  if not owned then
    Or_error.error_string "active container is not owned by this application"
  else
    let%bind json =
      Or_error.try_with (fun () -> Yojson.Safe.from_string output)
    in
    match json with
    | `List [ `Assoc container ] ->
        let string_field fields name =
          match List.Assoc.find fields ~equal:String.equal name with
          | Some (`String value) when not (String.is_empty value) -> Some value
          | _ -> None
        in
        let name =
          string_field container "Name"
          |> Option.map ~f:(String.chop_prefix_if_exists ~prefix:"/")
        in
        let id = string_field container "Id" in
        let%bind state =
          match List.Assoc.find container ~equal:String.equal "State" with
          | Some (`Assoc state) -> Ok state
          | _ -> Or_error.error_string "active container state is missing"
        in
        let%bind () =
          match List.Assoc.find state ~equal:String.equal "Running" with
          | Some (`Bool true) -> Ok ()
          | _ -> Or_error.error_string "active container is not running"
        in
        let%bind labels =
          match List.Assoc.find container ~equal:String.equal "Config" with
          | Some (`Assoc config) -> (
              match List.Assoc.find config ~equal:String.equal "Labels" with
              | Some (`Assoc labels) -> Ok labels
              | _ -> Or_error.error_string "active container labels are missing"
              )
          | _ -> Or_error.error_string "active container config is missing"
        in
        let revision = label labels "io.nixploy.revision" in
        let operation_id = label labels "io.nixploy.operation_id" in
        let%bind () =
          if
            Option.equal String.equal
              (label labels "io.nixploy.repository_identity")
              (Some repository_identity)
          then Ok ()
          else
            Or_error.error_string
              "active container repository identity does not match"
        in
        let%bind id =
          Option.value_map id
            ~default:(Or_error.error_string "active container ID is missing")
            ~f:Or_error.return
        in
        let%bind name =
          match name with
          | Some name when String.equal name expected_name -> Ok name
          | _ -> Or_error.error_string "active container name does not match"
        in
        if Option.is_none revision || Option.is_none operation_id then
          Or_error.error_string
            "active container immutable identity is incomplete"
        else
          Ok
            {
              name;
              id;
              revision;
              operation_id;
              started_at = string_field state "StartedAt";
            }
    | _ ->
        Or_error.error_string
          "active container inspect must contain one container"

let find_running_placement ~connection ~project ~target ~resource_key
    ~repository_identity ~placement =
  let open Deferred.Or_error.Let_syntax in
  let name = Deployment_plan.container_name ~resource_key placement in
  let%bind inspected = inspect_container ~connection name in
  Deferred.return
    (runtime_container_of_inspect inspected.stdout ~project ~target
       ~resource_key ~repository_identity ~expected_name:name)

let find_running_slot ~connection ~project ~target ~resource_key
    ~repository_identity ~slot =
  find_running_placement ~connection ~project ~target ~resource_key
    ~repository_identity
    ~placement:(Deployment_plan.Web_slot { slot; port = 0 })

let parse_log_line line =
  match String.lsplit2 line ~on:' ' with
  | Some (timestamp, text)
    when String.mem timestamp 'T' && String.is_suffix timestamp ~suffix:"Z" ->
      { timestamp = Some timestamp; text }
  | _ -> { timestamp = None; text = line }

let redact_log_line line =
  let keys =
    [
      "authorization";
      "database_url";
      "api_key";
      "api-key";
      "password";
      "passwd";
      "token";
      "secret";
      "cookie";
    ]
  in
  let is_space character = Char.is_whitespace character in
  let is_value_end character =
    is_space character || Char.equal character ',' || Char.equal character ';'
  in
  let rec redact line position =
    let lowercase = String.lowercase line in
    let found =
      List.filter_map keys ~f:(fun key ->
          String.substr_index lowercase ~pos:position ~pattern:key
          |> Option.map ~f:(fun index -> (index, key)))
      |> List.min_elt ~compare:(fun (left, _) (right, _) ->
          Int.compare left right)
    in
    match found with
    | None -> line
    | Some (index, key) ->
        let after_key = index + String.length key in
        let rec skip_spaces cursor =
          if cursor < String.length line && is_space line.[cursor] then
            skip_spaces (cursor + 1)
          else cursor
        in
        let after_key =
          if after_key < String.length line && Char.equal line.[after_key] '"'
          then after_key + 1
          else after_key
        in
        let separator = skip_spaces after_key in
        if
          separator >= String.length line
          || not
               (Char.equal line.[separator] ':'
               || Char.equal line.[separator] '=')
        then redact line after_key
        else
          let value_start = skip_spaces (separator + 1) in
          let quoted =
            value_start < String.length line
            && (Char.equal line.[value_start] '"'
               || Char.equal line.[value_start] '\'')
          in
          let secret_start = if quoted then value_start + 1 else value_start in
          let rec value_end cursor =
            if cursor >= String.length line then cursor
            else if quoted && Char.equal line.[cursor] line.[value_start] then
              cursor
            else if
              (not quoted)
              &&
              if String.equal key "authorization" || String.equal key "cookie"
              then Char.equal line.[cursor] ',' || Char.equal line.[cursor] ';'
              else is_value_end line.[cursor]
            then cursor
            else value_end (cursor + 1)
          in
          let value_end = value_end secret_start in
          if Int.equal secret_start value_end then redact line value_end
          else
            let replacement = "[REDACTED]" in
            let line =
              String.prefix line secret_start
              ^ replacement
              ^ String.drop_prefix line value_end
            in
            redact line (secret_start + String.length replacement)
  in
  redact line 0

let bound_logs output =
  let max_bytes = 65_536 in
  let max_lines = 500 in
  let input = String.rstrip output |> String.split_lines in
  let rec take lines bytes count kept truncated =
    match lines with
    | [] ->
        {
          lines = List.map kept ~f:(Fn.compose parse_log_line redact_log_line);
          truncated;
        }
    | line :: rest ->
        let line_bytes = String.length line + 1 in
        if count >= max_lines || bytes + line_bytes > max_bytes then
          {
            lines = List.map kept ~f:(Fn.compose parse_log_line redact_log_line);
            truncated = true;
          }
        else take rest (bytes + line_bytes) (count + 1) (line :: kept) truncated
  in
  take (List.rev input) 0 0 [] false

let read_logs ~connection ~container =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Process_runner.run ~timeout:(Time_ns.Span.of_sec 30.)
      ~max_output_bytes:262_144 ~prog:"podman"
      ~args:
        [
          "--connection";
          connection;
          "logs";
          "--tail";
          "500";
          "--timestamps";
          container.id;
        ]
      ()
  in
  match result.exit_status with
  | Error failure ->
      Deferred.Or_error.errorf "Podman logs failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)
  | Ok () ->
      let output =
        if String.is_empty result.stderr then result.stdout
        else result.stdout ^ "\n" ^ result.stderr
      in
      Deferred.Or_error.return (bound_logs output)

let numeric_string fields names =
  List.find_map names ~f:(fun name ->
      match List.Assoc.find fields ~equal:String.Caseless.equal name with
      | Some (`String value) -> Some value
      | Some (`Float value) -> Some (Float.to_string value)
      | Some (`Int value) -> Some (Int.to_string value)
      | _ -> None)

let parse_percent value =
  let value = String.strip value in
  if String.equal value "--" then None
  else
    String.chop_suffix_if_exists value ~suffix:"%"
    |> Float.of_string |> Option.some

let bytes_of_human value =
  let value = String.strip value in
  let index =
    String.findi value ~f:(fun _ character ->
        not (Char.is_digit character || Char.equal character '.'))
    |> Option.value_map ~default:(String.length value) ~f:fst
  in
  let number = String.prefix value index |> Float.of_string in
  let unit =
    String.drop_prefix value index |> String.strip |> String.lowercase
  in
  let multiplier =
    match unit with
    | "" | "b" -> 1.
    | "kb" -> 1_000.
    | "kib" -> 1_024.
    | "mb" -> 1_000_000.
    | "mib" -> 1_048_576.
    | "gb" -> 1_000_000_000.
    | "gib" -> 1_073_741_824.
    | unit -> failwithf "unsupported memory unit %s" unit ()
  in
  Float.iround_nearest_exn (number *. multiplier) |> Int64.of_int

let parse_stats output =
  let open Or_error.Let_syntax in
  let%bind json =
    Or_error.try_with (fun () -> Yojson.Safe.from_string output)
  in
  let%bind fields =
    match json with
    | `Assoc fields -> Ok fields
    | `List [ `Assoc fields ] -> Ok fields
    | _ -> Or_error.error_string "Podman stats must contain one object"
  in
  let%bind cpu =
    numeric_string fields [ "cpu_percent"; "CPU"; "CPUPerc"; "cpu" ]
    |> Option.value_map
         ~default:(Or_error.error_string "Podman stats CPU is missing")
         ~f:(fun value -> Or_error.try_with (fun () -> parse_percent value))
  in
  let%bind memory =
    numeric_string fields [ "mem_usage"; "MemUsage"; "memUsage" ]
    |> Option.value_map
         ~default:(Or_error.error_string "Podman stats memory is missing")
         ~f:(fun value ->
           Or_error.try_with (fun () ->
               String.lsplit2 value ~on:'/'
               |> Option.value_map ~default:value ~f:fst
               |> bytes_of_human))
  in
  Ok { cpu_percent = cpu; memory_used_bytes = memory }

let read_stats ~connection ~container =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    run_ok ~timeout:(Time_ns.Span.of_sec 30.)
      [
        "--connection";
        connection;
        "stats";
        "--no-stream";
        "--format";
        "json";
        container.id;
      ]
  in
  Deferred.return (parse_stats result.stdout)

module For_testing = struct
  let pre_start_argvs = pre_start_argvs
  let runtime_argv = runtime_argv
  let loaded_reference = loaded_reference
  let resource_keys_of_containers = resource_keys_of_containers
  let parse_stats = parse_stats
  let bound_logs = bound_logs
  let owned_candidate_collision = owned_candidate_collision
end
