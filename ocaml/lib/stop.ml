open Async
open Core

type t = {
  project : Project_name.t;
  target : Target_name.t;
  resource_key : Resource_key.t;
  route_removed : bool;
  containers : string list;
}

let project t = t.project
let target t = t.target
let resource_key t = t.resource_key
let route_removed t = t.route_removed
let containers t = t.containers

let placements =
  Deployment_plan.
    [
      Single_container;
      Web_slot { slot = Blue; port = 0 };
      Web_slot { slot = Green; port = 0 };
    ]

let stop_local ~store ~working_directory ~target:target_name =
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
  let operation_id =
    Uuid.create_random (Random.State.make_self_init ()) |> Uuid.to_string
  in
  let record message =
    Store.record_prune_event store ~operation_id ~working_directory
      ~target:target_name ~message:("stop: " ^ message)
  in
  let%bind () = record "requested: remove owned route, stop owned containers" in
  let%bind.Deferred result =
    Mutation_guard.with_mutation ~project ~target (fun () ->
        let open Deferred.Or_error.Let_syntax in
        let%bind candidates =
          Deferred.return
            (Resource_key.candidates ~project ~target:target_name
               ~repository_identity)
        in
        let%bind resource_key =
          Podman.select_resource_key ~project ~target ~repository_identity
            ~candidates
        in
        let%bind connection = Podman.ensure_connection ~target ~resource_key in
        let%bind containers =
          Deferred.Or_error.List.filter_map placements ~how:`Sequential
            ~f:(fun placement ->
              Podman.find_owned_placement ~connection ~project ~target
                ~resource_key ~repository_identity ~placement)
        in
        let%bind deletion =
          match Configuration.Target.kind target with
          | Non_web -> Deferred.Or_error.return None
          | Web web ->
              let%map deletion =
                Caddy.preflight_delete (Caddy.create ~target ~resource_key ~web)
              in
              Some deletion
        in
        let%bind () = record "ownership preflight complete" in
        let%bind route_removed =
          match deletion with
          | None -> Deferred.Or_error.return false
          | Some deletion ->
              let%bind () = record "removing owned route" in
              let%bind removed = Caddy.execute_delete deletion in
              let%map () = record "route step complete" in
              removed
        in
        let%bind () =
          Deferred.Or_error.List.iter containers ~how:`Sequential
            ~f:(fun candidate ->
              let id = Podman.candidate_id candidate in
              let%bind () = record ("stopping container " ^ id) in
              let%bind () = Podman.stop_candidate ~connection ~candidate in
              record ("stopped container " ^ id))
        in
        Deferred.Or_error.return
          {
            project;
            target = target_name;
            resource_key;
            route_removed;
            containers = List.map containers ~f:Podman.candidate_name;
          })
  in
  let message =
    match result with
    | Ok _ -> "succeeded"
    | Error error -> "failed or unknown: " ^ Error.to_string_hum error
  in
  let%bind.Deferred recorded = record message in
  match (result, recorded) with
  | Ok result, Ok () -> Deferred.Or_error.return result
  | Error error, Ok () ->
      Deferred.Or_error.fail
        (Error.tag error ~tag:("Stop operation " ^ operation_id))
  | _, Error error ->
      Deferred.Or_error.fail
        (Error.tag error
           ~tag:
             ("Stop operation " ^ operation_id
            ^ ": terminal reporting failed; inspect remote state and \
               prune_events"))
