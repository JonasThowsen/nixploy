open Async
open Core

type t = {
  project : Project_name.t;
  target : Configuration.Target.t;
  resource_key : Resource_key.t;
  workloads : Workload.t list;
}

let max_podman_output_bytes = 1_048_576
let max_connection_output_bytes = 262_144
let query_timeout = Time_ns.Span.of_sec 30.
let project t = t.project
let target t = t.target
let resource_key t = t.resource_key
let workloads t = t.workloads

let load ~working_directory ~target:target_name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
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
  let%bind connection =
    match Podman_connection.find_by_name connections resource_key_text with
    | Some connection when Podman_connection.matches_target connection target ->
        Deferred.Or_error.return connection
    | Some _ ->
        Deferred.Or_error.error_string
          "the exact resource connection does not match the flake target"
    | None ->
        Deferred.Or_error.error_string
          "the exact resource connection is not configured"
  in
  let connection_name = Podman_connection.name connection in
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
  let%bind modern_output =
    query
      [
        "label=io.nixploy.managed=true";
        "label=io.nixploy.resource_key=" ^ resource_key_text;
      ]
  in
  let%bind modern =
    Deferred.return
      (Workload.all_owned_of_json ~ownership:`Modern ~project
         ~target:target_name ~resource_key ~repository_identity
         ~expected_names:names modern_output)
  in
  let%bind workloads =
    if not (List.is_empty modern) then Deferred.Or_error.return modern
    else
      let%map legacy =
        Deferred.Or_error.List.map names ~how:`Sequential ~f:(fun name ->
            let open Deferred.Or_error.Let_syntax in
            let%bind output = query [ "name=^" ^ name ^ "$" ] in
            Deferred.return
              (Workload.all_owned_of_json ~ownership:`Legacy ~project
                 ~target:target_name ~resource_key ~repository_identity
                 ~expected_names:[ name ] output))
      in
      List.concat legacy
  in
  Deferred.Or_error.return { project; target; resource_key; workloads }
