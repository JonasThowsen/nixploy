open Async
open Core

type image = { reference : string; id : string }
type candidate = { name : string; id : string }

let podman_timeout = Time_ns.Span.of_min 5.
let build_timeout = Time_ns.Span.of_hr 1.
let max_output = 1_048_576
let image_reference (image : image) = image.reference
let image_id (image : image) = image.id
let candidate_name (candidate : candidate) = candidate.name
let candidate_id (candidate : candidate) = candidate.id

let run ?stdin ?(timeout = podman_timeout) args =
  Process_runner.run ?stdin ~timeout ~max_output_bytes:max_output ~prog:"podman"
    ~args ()

let run_ok ?stdin ?timeout args =
  let open Deferred.Or_error.Let_syntax in
  let%bind result = run ?stdin ?timeout args in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result
  | Error failure ->
      Deferred.Or_error.errorf "podman failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let list_connections () =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    run_ok [ "system"; "connection"; "list"; "--format"; "json" ]
  in
  Deferred.return (Podman_connection.all_of_json result.stdout)

let ensure_connection ~target ~resource_key =
  let open Deferred.Or_error.Let_syntax in
  let name = Resource_key.to_string resource_key in
  let%bind connections = list_connections () in
  let%bind () =
    match Podman_connection.find_by_name connections name with
    | Some connection when Podman_connection.matches_target connection target ->
        Deferred.Or_error.return ()
    | Some _ ->
        Deferred.Or_error.errorf
          "Podman connection %s exists but does not match the flake target" name
    | None ->
        let%bind preflight =
          Remote_command.run ~target ~timeout:(Time_ns.Span.of_sec 30.)
            ~max_output_bytes:65_536 [ "true" ]
        in
        let%bind () =
          match preflight.exit_status with
          | Ok () -> Deferred.Or_error.return ()
          | Error failure ->
              Deferred.Or_error.errorf "SSH preflight failed (%s): %s"
                (Core_unix.Exit_or_signal.to_string_hum (Error failure))
                (String.strip preflight.stderr)
        in
        let identity =
          Configuration.Target.identity_file target
          |> Option.value_map ~default:[] ~f:(fun path ->
              [ "--identity"; path ])
        in
        let%map _ =
          run_ok
            ([
               "system";
               "connection";
               "add";
               name;
               "--port";
               Int.to_string (Configuration.Target.port target);
             ]
            @ identity
            @ [
                Configuration.Target.user target
                ^ "@"
                ^ Configuration.Target.host target;
              ])
        in
        ()
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

module For_testing = struct
  let loaded_reference = loaded_reference
end

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
          ".#" ^ image_output;
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

let inspect_container ~connection name =
  run_ok [ "--connection"; connection; "inspect"; "--type"; "container"; name ]

let label fields name =
  match List.Assoc.find fields ~equal:String.equal name with
  | Some (`String value) -> Some value
  | _ -> None

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

let prepare_candidate ~connection ~project ~target ~resource_key ~slot =
  let open Deferred.Or_error.Let_syntax in
  let name = Deployment_plan.container_name ~resource_key slot in
  let%bind exists =
    run [ "--connection"; connection; "container"; "exists"; name ]
  in
  match exists.exit_status with
  | Ok () ->
      let%bind inspected = inspect_container ~connection name in
      let%bind owned =
        Deferred.return
          (owned_container inspected.stdout ~project ~target ~resource_key)
      in
      if not owned then
        Deferred.Or_error.errorf
          "container %s exists but is not owned by this target" name
      else
        let%map _ = run_ok [ "--connection"; connection; "rm"; "-f"; name ] in
        ()
  | Error (`Exit_non_zero 1) -> Deferred.Or_error.return ()
  | Error failure ->
      Deferred.Or_error.errorf "could not inspect candidate collision (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip exists.stderr)

let runtime_args run ~port =
  let network =
    Configuration.Run.network run
    |> Option.value_map ~default:[] ~f:(fun network -> [ "--network"; network ])
  in
  let environment =
    Configuration.Run.rendered_environment run ~port
    |> List.concat_map ~f:(fun (name, value) -> [ "-e"; name ^ "=" ^ value ])
  in
  let ports =
    Configuration.Run.ports run
    |> List.concat_map ~f:(fun mapping -> [ "-p"; mapping ])
  in
  network @ environment @ ports

let run_pre_start ~connection ~target ~port ~image =
  let open Deferred.Or_error.Let_syntax in
  let run_config = Configuration.Target.run target in
  Deferred.Or_error.List.iter (Configuration.Run.pre_start run_config)
    ~how:`Sequential ~f:(fun command ->
      let%map _ =
        run_ok
          ([ "--connection"; connection; "run"; "--rm" ]
          @ runtime_args run_config ~port
          @ [ image.reference ] @ command)
      in
      ())

let project_id repository =
  Digestif.SHA256.digest_string repository |> Digestif.SHA256.to_hex
  |> fun digest -> String.prefix digest 10

let start_candidate ~connection ~project ~target ~resource_key ~slot ~port
    ~source ~configuration_digest ~operation_id ~deployed_at ~image =
  let open Deferred.Or_error.Let_syntax in
  let name = Deployment_plan.container_name ~resource_key slot in
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
  let command =
    Configuration.Run.command run_config |> Option.value ~default:[]
  in
  let%bind started =
    run_ok
      ([ "--connection"; connection; "run"; "-d"; "--name"; name ]
      @ runtime_args run_config ~port
      @ labels metadata @ [ image.reference ] @ command)
  in
  let id = String.strip started.stdout in
  if String.is_empty id then
    Deferred.Or_error.error_string "Podman did not return a container ID"
  else Deferred.Or_error.return { name; id }

let verify_candidate ~connection ~project ~target ~resource_key ~source
    ~configuration_digest ~operation_id ~(image : image) ~candidate =
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

let remove_candidate ~connection ~candidate =
  let%map result =
    run_ok [ "--connection"; connection; "rm"; "-f"; candidate.name ]
  in
  Or_error.map result ~f:(fun _ -> ())
