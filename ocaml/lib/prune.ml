open Async
open Core

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t = {
  project : Project_name.t;
  target : Target_name.t;
  resource_key : Resource_key.t;
  containers_removed : int;
  secrets_removed : int;
  route : route;
}

let project (t : t) = t.project
let target (t : t) = t.target
let resource_key (t : t) = t.resource_key
let containers_removed (t : t) = t.containers_removed
let secrets_removed (t : t) = t.secrets_removed
let route (t : t) = t.route

let prune_local ~store ~working_directory ~target:target_name ~confirmed =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    if confirmed then Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED: pass --yes to remove this \
         target's containers and configured route"
  in
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
      ~target:target_name ~message
  in
  let%bind () =
    record
      "requested: scoped containers and configured route only; secrets, \
       images, volumes and data retained"
  in
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
        let placements =
          Deployment_plan.
            [
              Single_container;
              Web_slot { slot = Blue; port = 0 };
              Web_slot { slot = Green; port = 0 };
            ]
        in
        let%bind containers =
          Deferred.Or_error.List.map placements ~how:`Sequential
            ~f:(fun placement ->
              Podman.find_owned_placement ~connection ~project ~target
                ~resource_key ~repository_identity ~placement)
        in
        let containers = List.filter_opt containers in
        let%bind () =
          let ids = List.map containers ~f:Podman.candidate_id in
          if List.contains_dup ids ~compare:String.compare then
            Deferred.Or_error.error_string
              "NIXPLOY_PRUNE_AMBIGUOUS_CONTAINER: multiple derived names \
               resolve to the same ID"
          else Deferred.Or_error.return ()
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
        let%bind () =
          record "ownership preflight complete; removing configured route"
        in
        let%bind route =
          match deletion with
          | None -> Deferred.Or_error.return Not_configured
          | Some deletion ->
              let%map removed = Caddy.execute_delete deletion in
              if removed then Removed else Missing
        in
        let%bind () = record "route step complete" in
        let%bind () =
          Deferred.Or_error.List.iter containers ~how:`Sequential
            ~f:(fun candidate ->
              let%bind () =
                record ("removing container " ^ Podman.candidate_id candidate)
              in
              let%bind () = Podman.remove_candidate ~connection ~candidate in
              record ("removed container " ^ Podman.candidate_id candidate))
        in
        let%map () = record "remote removals complete" in
        {
          project;
          target = target_name;
          resource_key;
          containers_removed = List.length containers;
          secrets_removed = 0;
          route;
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
        (Error.tag error ~tag:("Prune operation " ^ operation_id))
  | _, Error error ->
      Deferred.Or_error.fail
        (Error.tag error
           ~tag:
             ("Prune operation " ^ operation_id
            ^ ": terminal reporting failed; inspect remote state and \
               prune_events"))
