open Async
open Core

type route = Not_configured | Missing | Kept [@@deriving compare, equal, sexp]

type mode = Everything | Stale of { keep : int }
[@@deriving compare, equal, sexp]

type t = {
  project : Project_name.t;
  target : Target_name.t;
  resource_key : Resource_key.t;
  mode : mode;
  dry_run : bool;
  containers : string list;
  secrets : string list;
  secrets_retained : int;
  image_references : string list;
  image_bytes : int64;
  route : route;
  notes : string list;
}

let project (t : t) = t.project
let target (t : t) = t.target
let resource_key (t : t) = t.resource_key
let mode (t : t) = t.mode
let dry_run (t : t) = t.dry_run
let containers (t : t) = t.containers
let secrets (t : t) = t.secrets
let image_references (t : t) = t.image_references
let image_bytes (t : t) = t.image_bytes
let containers_removed (t : t) = List.length t.containers
let secrets_removed (t : t) = List.length t.secrets
let secrets_retained (t : t) = t.secrets_retained
let route (t : t) = t.route
let notes (t : t) = t.notes

type observation = {
  placements : Podman.placement_state list;
  route : Caddy.route option;
  secrets : Podman.prepared_secret_prune;
  images : Podman.owned_image list;
}

type plan = {
  remove_placements : Podman.placement_state list;
  remove_secrets : Podman.prepared_secret_prune;
  remove_images : Podman.owned_image list;
  plan_notes : string list;
}

let placements =
  Deployment_plan.
    [
      Single_container;
      Web_slot { slot = Blue; port = 0 };
      Web_slot { slot = Green; port = 0 };
    ]

let observe ~connection ~project ~target ~resource_key ~repository_identity =
  let open Deferred.Or_error.Let_syntax in
  let%bind observed =
    Deferred.Or_error.List.filter_map placements ~how:`Sequential
      ~f:(fun placement ->
        Podman.observe_owned_placement ~connection ~project ~target
          ~resource_key ~repository_identity ~placement
        |> Deferred.Or_error.map
             ~f:(Option.map ~f:(fun state -> (placement, state))))
  in
  let%bind () =
    let ids =
      List.map observed ~f:(fun (_, state) ->
          Podman.candidate_id state.Podman.container)
    in
    if List.contains_dup ids ~compare:String.compare then
      Deferred.Or_error.error_string
        "NIXPLOY_PRUNE_AMBIGUOUS_CONTAINER: multiple derived names resolve to \
         the same ID"
    else Deferred.Or_error.return ()
  in
  let%bind route =
    match Configuration.Target.kind target with
    | Non_web -> Deferred.Or_error.return None
    | Web web ->
        let%map route =
          Caddy.inspect (Caddy.create ~target ~resource_key ~web)
        in
        Some route
  in
  let%bind secrets =
    Podman.preflight_prune_owned_secrets ~connection ~project ~target
      ~resource_key ~repository_identity
  in
  let%map images = Podman.list_owned_images ~connection ~resource_key in
  (observed, { placements = List.map observed ~f:snd; route; secrets; images })

let stale_route ~target route =
  match (Configuration.Target.kind target, route) with
  | Non_web, _ | Web _, None -> Stale_plan.Non_web
  | Web web, Some route -> (
      match route with
      | Caddy.Missing -> Missing
      | Existing { active_port; _ } ->
          Routed
            (if Int.equal active_port (Configuration.Web.blue_port web) then
               Some Deployment_plan.Blue
             else if Int.equal active_port (Configuration.Web.green_port web)
             then Some Green
             else None))

let active_error ~target =
  Or_error.errorf
    "NIXPLOY_PRUNE_ACTIVE: target %s is still live; run `nixploy stop -t %s` \
     first. Prune never removes a route or a running application."
    (Target_name.to_string (Configuration.Target.name target))
    (Target_name.to_string (Configuration.Target.name target))

let plan ~mode ~target ~observed observation =
  match mode with
  | Everything ->
      let routed =
        match observation.route with
        | Some (Caddy.Existing _) -> true
        | Some Caddy.Missing | None -> false
      in
      let running =
        List.exists observation.placements ~f:(fun state ->
            state.Podman.running)
      in
      if routed || running then active_error ~target
      else
        Ok
          {
            remove_placements = observation.placements;
            remove_secrets = observation.secrets;
            remove_images = observation.images;
            plan_notes = [];
          }
  | Stale { keep } ->
      let open Or_error.Let_syntax in
      let stale_container (placement, (state : Podman.placement_state)) =
        {
          Stale_plan.name = Podman.candidate_name state.container;
          placement;
          running = state.running;
          secret_names = state.secret_names;
          image_id = state.image_id;
        }
      in
      let stale_image (image : Podman.owned_image) =
        {
          Stale_plan.image_id = image.image_id;
          references = image.references;
          size_bytes = image.size_bytes;
          containers = image.containers;
        }
      in
      let%map stale =
        Stale_plan.create
          ~route:(stale_route ~target observation.route)
          ~containers:(List.map observed ~f:stale_container)
          ~owned_secrets:
            (Podman.prepared_secret_prune_names observation.secrets)
          ~images:(List.map observation.images ~f:stale_image)
          ~keep
      in
      let removed_names =
        List.map stale.remove_containers ~f:(fun container -> container.name)
      in
      let removed_image_ids =
        List.map stale.remove_images ~f:(fun image -> image.image_id)
      in
      {
        remove_placements =
          List.filter observation.placements ~f:(fun state ->
              List.mem removed_names
                (Podman.candidate_name state.container)
                ~equal:String.equal);
        remove_secrets =
          Podman.restrict_prepared_secret_prune observation.secrets
            ~remove:(List.mem stale.remove_secrets ~equal:String.equal);
        remove_images =
          List.filter observation.images ~f:(fun image ->
              List.mem removed_image_ids image.image_id ~equal:String.equal);
        plan_notes = stale.notes;
      }

let total_image_bytes images =
  List.sum
    (module Int64)
    images
    ~f:(fun (image : Podman.owned_image) ->
      Option.value image.size_bytes ~default:0L)

let planned_route observation ~mode =
  match (mode, observation.route) with
  | Stale _, _ -> Kept
  | Everything, None -> Not_configured
  | Everything, Some _ -> Missing

let execute ~record ~connection ~resource_key plan =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    Deferred.Or_error.List.iter plan.remove_placements ~how:`Sequential
      ~f:(fun state ->
        let candidate = state.Podman.container in
        let%bind () =
          record ("removing container " ^ Podman.candidate_id candidate)
        in
        let%bind () = Podman.remove_candidate ~connection ~candidate in
        record ("removed container " ^ Podman.candidate_id candidate))
  in
  let%bind () = record "removing preflighted owned secrets" in
  let%bind secrets_removed, secrets_retained =
    Podman.execute_prepared_secret_prune plan.remove_secrets
  in
  let%bind () =
    Deferred.Or_error.List.iter plan.remove_images ~how:`Sequential
      ~f:(fun image ->
        Deferred.Or_error.List.iter image.references ~how:`Sequential
          ~f:(fun reference ->
            let%bind () = record ("removing image reference " ^ reference) in
            Podman.remove_owned_image_reference ~connection ~resource_key
              reference))
  in
  let%map () =
    record
      (sprintf
         "remote removals complete: %d secrets removed, %d unlabelled secrets \
          retained, %d image references removed"
         secrets_removed secrets_retained
         (List.sum
            (module Int)
            plan.remove_images
            ~f:(fun image -> List.length image.references)))
  in
  secrets_retained

let prune_local ~store ~working_directory ~target:target_name ~confirmed ~mode
    ~dry_run =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    if confirmed || dry_run then Deferred.Or_error.return ()
    else
      Deferred.Or_error.error_string
        "NIXPLOY_PRUNE_CONFIRMATION_REQUIRED: pass --yes to remove this \
         target's resources, or --dry-run to preview"
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
    if dry_run then Deferred.Or_error.return ()
    else
      Store.record_prune_event store ~operation_id ~working_directory
        ~target:target_name ~message
  in
  let%bind () =
    record
      (match mode with
      | Everything ->
          "requested: stopped containers, owned secrets and owned images; \
           unlabelled secrets, unowned images, volumes and data retained"
      | Stale { keep } ->
          sprintf
            "requested: stale containers, unmounted owned secrets and owned \
             images beyond the newest %d; live resources retained"
            keep)
  in
  let prune ~remove =
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
    let%bind observed, observation =
      observe ~connection ~project ~target ~resource_key ~repository_identity
    in
    let%bind plan =
      Deferred.return (plan ~mode ~target ~observed observation)
    in
    let%bind () =
      if remove then record "ownership preflight complete"
      else Deferred.Or_error.return ()
    in
    let route = planned_route observation ~mode in
    let%map secrets_retained =
      if not remove then
        Deferred.Or_error.return
          (snd (Podman.prepared_secret_prune_counts plan.remove_secrets))
      else execute ~record ~connection ~resource_key plan
    in
    {
      project;
      target = target_name;
      resource_key;
      mode;
      dry_run;
      containers =
        List.map plan.remove_placements ~f:(fun state ->
            Podman.candidate_name state.container);
      secrets = Podman.prepared_secret_prune_names plan.remove_secrets;
      secrets_retained;
      image_references =
        List.concat_map plan.remove_images ~f:(fun image -> image.references);
      image_bytes = total_image_bytes plan.remove_images;
      route;
      notes = plan.plan_notes;
    }
  in
  let%bind.Deferred result =
    if dry_run then prune ~remove:false
    else
      (* Observe and plan read-only first: a refusal that changes nothing (a
         live target, failed ownership checks) must not leave a guard marker
         as uncertainty evidence. The guarded run observes again. *)
      match%bind.Deferred prune ~remove:false with
      | Error error -> Deferred.Or_error.fail error
      | Ok _ ->
          Mutation_guard.with_mutation ~project ~target (fun () ->
              prune ~remove:true)
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
