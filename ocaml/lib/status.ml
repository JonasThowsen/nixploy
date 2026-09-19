open Async
open Core

type role = Single | Active | Unrouted [@@deriving compare, equal, sexp]

type container = {
  workload : Workload.t;
  role : role;
  restart_policy : string option;
  stats : Podman.runtime_stats option;
}

type route =
  | Not_web
  | Missing
  | Routed of {
      domain : string;
      port : int;
      slot : Deployment_plan.slot option;
    }

type disk = { total_bytes : int64; available_bytes : int64; path : string }

type t = {
  project : Project_name.t;
  target : Configuration.Target.t;
  resource_key : Resource_key.t;
  containers : container list;
  runtime_error : Error.t option;
  route : route Or_error.t;
  secrets : Podman.Secret_status.t list Or_error.t;
  images : Podman.owned_image list Or_error.t;
  storage : Podman.storage_usage Or_error.t;
  host : Podman.host_info Or_error.t;
  disk : disk Or_error.t;
  guard : Mutation_guard.marker Or_error.t;
  readiness : Host_readiness.t;
}

let max_podman_output_bytes = 1_048_576
let max_connection_output_bytes = 262_144
let query_timeout = Time_ns.Span.of_sec 30.
let project t = t.project
let target t = t.target
let resource_key t = t.resource_key
let containers t = t.containers
let workloads t = List.map t.containers ~f:(fun container -> container.workload)
let route t = t.route
let secrets t = t.secrets
let images t = t.images
let storage t = t.storage
let host t = t.host
let disk t = t.disk
let guard t = t.guard
let readiness t = t.readiness
let runtime_error t = t.runtime_error

let parse_disk ~path output =
  (* POSIX [df -P -k]: a header line, then one line of 1024-byte blocks. *)
  match String.split_lines output with
  | [ _header; line ] -> (
      match
        String.split line ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
      with
      | _filesystem :: total :: _used :: available :: _ -> (
          match (Int64.of_string_opt total, Int64.of_string_opt available) with
          | Some total, Some available ->
              Ok
                {
                  total_bytes = Int64.(total * 1024L);
                  available_bytes = Int64.(available * 1024L);
                  path;
                }
          | _ -> Or_error.error_string "df reported non-numeric sizes")
      | _ -> Or_error.error_string "df output has too few columns")
  | _ -> Or_error.error_string "df must report exactly one filesystem"

let read_disk ~target ~path =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    Remote_command.run ~target ~timeout:query_timeout ~max_output_bytes:4096
      [ "df"; "-P"; "-k"; "--"; path ]
  in
  match result.exit_status with
  | Ok () -> Deferred.return (parse_disk ~path result.stdout)
  | Error failure ->
      Deferred.Or_error.errorf "df failed (%s): %s"
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

let slot_of_port web port =
  if Int.equal port (Configuration.Web.blue_port web) then
    Some Deployment_plan.Blue
  else if Int.equal port (Configuration.Web.green_port web) then Some Green
  else None

let read_route ~target ~resource_key =
  match Configuration.Target.kind target with
  | Non_web -> Deferred.Or_error.return Not_web
  | Web web -> (
      let open Deferred.Or_error.Let_syntax in
      let%map route = Caddy.inspect (Caddy.create ~target ~resource_key ~web) in
      match route with
      | Caddy.Missing -> Missing
      | Existing { active_port; domain } ->
          Routed
            { domain; port = active_port; slot = slot_of_port web active_port })

let role ~target ~resource_key ~route workload =
  let name = Workload.name workload in
  match (Configuration.Target.kind target, route) with
  | Non_web, _ ->
      if String.equal name (Resource_key.to_string resource_key) then Single
      else Unrouted
  | Web _, Ok (Routed { slot = Some slot; _ })
    when String.equal name
           (Deployment_plan.web_container_name ~resource_key slot) ->
      Active
  | Web _, _ -> Unrouted

let human_bytes bytes =
  let value = Int64.to_float bytes in
  let units = [ "KiB"; "MiB"; "GiB"; "TiB" ] in
  let rec scale value = function
    | [] -> sprintf "%.1f PiB" (value /. 1024.)
    | unit :: rest ->
        let value = value /. 1024. in
        if Float.(value < 1024.) then sprintf "%.1f %s" value unit
        else scale value rest
  in
  if Float.(value < 1024.) then sprintf "%Ld B" bytes else scale value units

let stopped t =
  let routed =
    match t.route with
    | Ok (Routed _) | Error _ -> true
    | Ok (Not_web | Missing) -> false
  in
  (not routed)
  && (not (List.is_empty t.containers))
  && List.for_all t.containers ~f:(fun container ->
      Option.equal String.equal container.restart_policy (Some "no")
      && not
           (Option.equal String.equal
              (Workload.state container.workload)
              (Some "running")))

let issues t =
  let kind = Configuration.Target.kind t.target in
  let serving =
    List.filter t.containers ~f:(fun container ->
        match container.role with Single | Active -> true | Unrouted -> false)
  in
  let not_running =
    List.filter_map serving ~f:(fun container ->
        let state = Workload.state container.workload in
        if Option.equal String.equal state (Some "running") then None
        else
          Some
            (sprintf "application container %s is %s%s"
               (Workload.name container.workload)
               (Option.value state ~default:"in an unknown state")
               (Workload.status container.workload
               |> Option.value_map ~default:"" ~f:(sprintf " (%s)"))))
  in
  let deployment =
    match (kind, t.route) with
    | Non_web, _ ->
        if List.is_empty serving then [ "no application container is deployed" ]
        else []
    | Web _, Error error ->
        [ "could not read the Caddy route: " ^ Error.to_string_hum error ]
    | Web _, Ok (Not_web | Missing) ->
        if List.is_empty t.containers then
          [ "no application container is deployed" ]
        else
          [
            "the Caddy route is missing, so no container is served; redeploy \
             to restore it";
          ]
    | Web web, Ok (Routed { domain; port; slot }) ->
        let domain_issue =
          if String.Caseless.equal domain (Configuration.Web.domain web) then []
          else
            [
              sprintf "the Caddy route serves %s, not the configured domain %s"
                domain
                (Configuration.Web.domain web);
            ]
        in
        let slot_issue =
          match slot with
          | None ->
              [ sprintf "the Caddy route targets undeclared port %d" port ]
          | Some slot when List.is_empty serving ->
              [
                sprintf
                  "the Caddy route serves the %s slot, but no owned container \
                   exists for it"
                  (Deployment_plan.slot_name slot);
              ]
          | Some _ -> []
        in
        domain_issue @ slot_issue
  in
  let unrouted =
    List.filter_map t.containers ~f:(fun container ->
        match container.role with
        | Unrouted ->
            Some
              (sprintf
                 "container %s is not served by the route; `nixploy prune \
                  --stale` removes it"
                 (Workload.name container.workload))
        | Single | Active -> None)
  in
  let restart =
    List.concat_map serving ~f:(fun container ->
        let name = Workload.name container.workload in
        let policy =
          match container.restart_policy with
          | Some "always" -> []
          | Some policy when not (String.is_empty policy) ->
              [
                sprintf
                  "%s has restart policy %s; redeploy so it returns after a \
                   reboot"
                  name policy;
              ]
          | (Some _ | None) when Option.is_none t.runtime_error ->
              [
                sprintf
                  "%s has no restart policy; redeploy so it returns after a \
                   reboot"
                  name;
              ]
          | Some _ | None -> []
        in
        let restarts =
          match Workload.restarts container.workload with
          | Some count when count > 0 ->
              [ sprintf "%s has restarted %d times" name count ]
          | Some _ | None -> []
        in
        policy @ restarts)
  in
  let guard =
    match t.guard with
    | Ok (Present directory) ->
        [
          sprintf
            "mutation marker %s is present: an operation is running or left \
             uncertainty evidence"
            directory;
        ]
    | Ok Absent | Error _ -> []
  in
  let readiness =
    Host_readiness.warnings t.readiness
    |> List.map ~f:(fun warning -> "reboot readiness " ^ warning)
  in
  let disk =
    match t.disk with
    | Ok disk when Int64.(disk.available_bytes * 10L < disk.total_bytes) ->
        [
          sprintf "only %s of %s is free on %s"
            (human_bytes disk.available_bytes)
            (human_bytes disk.total_bytes)
            disk.path;
        ]
    | Ok _ | Error _ -> []
  in
  let legacy_secrets =
    match t.secrets with
    | Ok secrets ->
        let legacy =
          List.count secrets ~f:(fun (secret : Podman.Secret_status.t) ->
              not secret.owned)
        in
        if legacy > 0 then
          [
            sprintf
              "%d unlabelled legacy secrets are retained; see MIGRATION.md"
              legacy;
          ]
        else []
    | Error _ -> []
  in
  let application =
    if stopped t then
      [
        "target is stopped (`nixploy stop`): deploy to start it again, or \
         `nixploy prune --yes` to remove it";
      ]
    else not_running @ deployment @ restart @ unrouted
  in
  application @ guard @ disk @ readiness @ legacy_secrets

let load ~working_directory ~target:target_name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind () =
    Deferred.return
      (Direct_mode.validate_configuration configuration ~target:target_name)
  in
  let%bind target =
    Deferred.return (Configuration.find_target configuration target_name)
  in
  let project = Configuration.project configuration in
  let%bind repository_identity =
    Source.repository_identity ~working_directory
  in
  let%bind candidates =
    Deferred.return
      (Resource_key.candidates ~project ~target:target_name ~repository_identity)
  in
  let%bind resource_key =
    Podman.select_resource_key ~project ~target ~repository_identity ~candidates
  in
  let%bind connection_output =
    Process_runner.run_stdout ~timeout:query_timeout
      ~max_output_bytes:max_connection_output_bytes ~prog:"podman"
      ~args:[ "system"; "connection"; "list"; "--format"; "json" ]
      ()
  in
  let%bind connections =
    Deferred.return (Podman_connection.all_of_json connection_output)
  in
  let resource_key_text = Resource_key.to_string resource_key in
  let%bind connection_name =
    match Podman_connection.find_by_name connections resource_key_text with
    | Some connection when Podman_connection.matches_target connection target ->
        Deferred.Or_error.return (Podman_connection.name connection)
    | Some _ ->
        Deferred.Or_error.error_string
          "the exact resource connection does not match the flake target"
    | None -> Podman.ensure_connection ~target ~resource_key
  in
  let names = Prune_plan.create ~resource_key |> Prune_plan.container_names in
  let query filters =
    Process_runner.run_stdout ~timeout:query_timeout
      ~max_output_bytes:max_podman_output_bytes ~prog:"podman"
      ~args:
        ([ "--connection"; connection_name; "ps"; "--all" ]
        @ List.concat_map filters ~f:(fun filter -> [ "--filter"; filter ])
        @ [ "--format"; "json" ])
      ()
  in
  (* Repeated name filters are OR'ed, so one query covers every placement;
     each returned container must still carry an exact derived name. *)
  let%bind output =
    query (List.map names ~f:(fun name -> "name=^" ^ name ^ "$"))
  in
  let%bind workloads =
    Deferred.return
      (Workload.all_owned_of_json ~project ~target:target_name ~resource_key
         ~repository_identity ~expected_names:names output)
  in
  let workloads =
    List.sort workloads ~compare:(fun left right ->
        String.compare (Workload.name left) (Workload.name right))
  in
  let names = List.map workloads ~f:Workload.name in
  let running =
    List.filter workloads ~f:(fun workload ->
        Option.equal String.equal (Workload.state workload) (Some "running"))
    |> List.map ~f:Workload.name
  in
  let connection = connection_name in
  (* Supplementary queries degrade to per-section errors. They run in small
     waves to stay well below sshd's default MaxStartups. *)
  let open Deferred.Let_syntax in
  let%bind policies = Podman.read_restart_policies ~connection ~names
  and stats = Podman.read_named_stats ~connection ~names:running
  and route = read_route ~target ~resource_key
  and secrets =
    Podman.read_secret_statuses ~connection ~project ~target ~resource_key
      ~repository_identity
  in
  let%map images = Podman.list_owned_images ~connection ~resource_key
  and storage = Podman.read_storage_usage ~connection
  and host, disk =
    let%bind host = Podman.read_host_info ~connection in
    let%map disk =
      match host with
      | Ok { graph_root = Some path; _ } -> read_disk ~target ~path
      | Ok { graph_root = None; _ } ->
          Deferred.Or_error.error_string "Podman did not report its graph root"
      | Error error -> Deferred.Or_error.fail error
    in
    (host, disk)
  and guard = Mutation_guard.inspect ~project ~target
  and readiness = Host_readiness.inspect ~target in
  let runtime_error =
    match (policies, stats) with
    | Ok _, Ok _ -> None
    | Error error, Ok _ | Ok _, Error error -> Some error
    | Error left, Error right -> Some (Error.of_list [ left; right ])
  in
  let policies = Result.ok policies |> Option.value ~default:[] in
  let stats = Result.ok stats |> Option.value ~default:[] in
  let containers =
    List.map workloads ~f:(fun workload ->
        let name = Workload.name workload in
        {
          workload;
          role = role ~target ~resource_key ~route workload;
          restart_policy =
            List.Assoc.find policies ~equal:String.equal name |> Option.join;
          stats = List.Assoc.find stats ~equal:String.equal name;
        })
  in
  Ok
    {
      project;
      target;
      resource_key;
      containers;
      runtime_error;
      route;
      secrets;
      images;
      storage;
      host;
      disk;
      guard;
      readiness;
    }

module For_testing = struct
  let create ~project ~target ~resource_key ~containers ~route ~secrets ~disk
      ~guard ~readiness =
    let not_observed = Or_error.error_string "not observed" in
    {
      project;
      target;
      resource_key;
      containers;
      runtime_error = None;
      route;
      secrets;
      images = not_observed;
      storage = not_observed;
      host = not_observed;
      disk;
      guard;
      readiness;
    }

  let parse_disk = parse_disk
end
