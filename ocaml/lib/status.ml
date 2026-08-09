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
  let%bind canonical_resource_key =
    Deferred.return (Resource_key.derive ~project ~target:target_name)
  in
  let%bind repository =
    Process_runner.run_stdout ~working_directory ~timeout:query_timeout
      ~max_output_bytes:65_536 ~prog:"git"
      ~args:[ "remote"; "get-url"; "origin" ]
      ()
  in
  let%bind legacy_resource_key =
    Deferred.return
      (Resource_key.derive_legacy ~project ~target:target_name
         ~repository:(String.strip repository))
  in
  let%bind resource_key =
    Podman.select_resource_key ~target ~canonical:canonical_resource_key
      ~legacy:legacy_resource_key
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
  let%bind connection =
    match
      Podman_connection.find_by_name connections
        (Resource_key.to_string resource_key)
    with
    | Some connection when Podman_connection.matches_target connection target ->
        Deferred.Or_error.return connection
    | _ ->
        Deferred.return (Podman_connection.find_for_target connections target)
  in
  let%bind output =
    Process_runner.run_stdout ~timeout:query_timeout
      ~max_output_bytes:max_podman_output_bytes ~prog:"podman"
      ~args:
        [
          "--connection";
          Podman_connection.name connection;
          "ps";
          "--all";
          "--filter";
          "label=nixploy.project=" ^ Project_name.to_string project;
          "--filter";
          "label=nixploy.target=" ^ Target_name.to_string target_name;
          "--format";
          "json";
        ]
      ()
  in
  let%map workloads = Deferred.return (Workload.all_of_json output) in
  { project; target; resource_key; workloads }
