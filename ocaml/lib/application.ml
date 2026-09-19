open Async
open Core

type commit = Source.commit
type source = Source.selection
type prune_result = Prune.t
type status = Status.t

type prune_route_state = Not_configured | Missing | Kept
[@@deriving compare, equal, sexp]

type prune_mode = Prune.mode = Everything | Stale of { keep : int }
[@@deriving compare, equal, sexp]

type deployment_state = Store.state =
  | Requested
  | Running
  | Succeeded
  | Failed
  | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Store.resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

type cancellation_result = Cancellation_requested | Already_requested
[@@deriving compare, equal, sexp]

type shutdown_transition = Shutdown_started | Already_shutting_down
[@@deriving compare, equal, sexp]

type log_line = { timestamp : string option; text : string }
[@@deriving compare, equal, sexp]

type log_snapshot = {
  container_name : string;
  revision : string option;
  observed_at_ms : int64;
  lines : log_line list;
  truncated : bool;
}
[@@deriving compare, equal, sexp]

type deployment = {
  id : string;
  legacy_application_key : string option;
  working_directory : string;
  target : Target_name.t;
  state : deployment_state;
  stage : string;
  message : string;
  revision : string option;
  commit_subject : string option;
  commit_timestamp_ms : int64 option;
  container_name : string option;
  error : string option;
  requested_at_ms : int64;
  started_at_ms : int64 option;
  finished_at_ms : int64 option;
  cancel_requested_at_ms : int64 option;
  updated_at_ms : int64;
}

type scope = { working_directory : string; target : Target_name.t }

type started_deployment = {
  deployment : deployment;
  scope : scope;
  cancellation : Cancellation.t;
  completion : deployment Deferred.Or_error.t;
}

type mutation_lifecycle = {
  mutable accepting : bool;
  mutable active_count : int;
  mutable drained : unit Ivar.t;
}

type t = {
  store : Store.t;
  local_source : working_directory:string -> source Deferred.Or_error.t;
  prepare_deploy :
    (request:Deployment_request.t -> Deployment.prepared Deferred.Or_error.t)
    option;
  deploy_operation :
    request:Deployment_request.t ->
    prepared:Deployment.prepared option ->
    (deployment * deployment Deferred.Or_error.t) Deferred.Or_error.t;
  deployment_history_override :
    (scope:scope -> limit:int -> deployment list Deferred.Or_error.t) option;
  active : started_deployment String.Table.t;
  cancellations : Cancellation.t list ref;
  mutations : mutation_lifecycle;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let canonical_working_directory working_directory =
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)

let local_scope ~working_directory ~target =
  let%map.Or_error working_directory =
    canonical_working_directory working_directory
  in
  { working_directory; target }

let deployment_of_store deployment =
  {
    id = Store.id deployment;
    legacy_application_key = Store.legacy_application_key deployment;
    working_directory = Store.working_directory deployment;
    target = Store.target deployment;
    state = Store.state deployment;
    stage = Store.stage deployment;
    message = Store.message deployment;
    revision = Store.revision deployment;
    commit_subject = Store.commit_subject deployment;
    commit_timestamp_ms = Store.commit_timestamp_ms deployment;
    container_name = Store.container_name deployment;
    error = Store.error deployment;
    requested_at_ms = Store.requested_at_ms deployment;
    started_at_ms = Store.started_at_ms deployment;
    finished_at_ms = Store.finished_at_ms deployment;
    cancel_requested_at_ms = Store.cancel_requested_at_ms deployment;
    updated_at_ms = Store.updated_at_ms deployment;
  }

let same_scope (scope : scope) (deployment : deployment) =
  String.equal scope.working_directory deployment.working_directory
  && Target_name.equal scope.target deployment.target
  && Option.is_none deployment.legacy_application_key

let create_with_runtime ?deployment_history ?(local_source = Source.local)
    ~store ~prepare_deploy ~deploy_operation () =
  {
    store;
    local_source;
    prepare_deploy;
    deploy_operation;
    deployment_history_override = deployment_history;
    active = String.Table.create ();
    cancellations = ref [];
    mutations = { accepting = true; active_count = 0; drained = Ivar.create () };
  }

let create ~store () =
  let deploy_operation ~request ~prepared =
    let open Deferred.Or_error.Let_syntax in
    let%bind started =
      Tracked_deployment.start ~request
        ~prepared:(Option.value_exn prepared)
        ~store ()
    in
    let deployment =
      Tracked_deployment.deployment started |> deployment_of_store
    in
    let completion =
      Deferred.map
        (Tracked_deployment.completion started)
        ~f:(Result.map ~f:deployment_of_store)
    in
    Deferred.Or_error.return (deployment, completion)
  in
  create_with_runtime ~store ~prepare_deploy:(Some Deployment.prepare)
    ~deploy_operation ()

let open_ ~state_path () =
  let%map.Deferred.Or_error store = Store.open_ ~path:state_path in
  create ~store ()

let begin_shutdown t =
  if not t.mutations.accepting then Already_shutting_down
  else (
    t.mutations.accepting <- false;
    let active = Hashtbl.data t.active in
    List.iter active ~f:(fun started ->
        upon (Store.request_cancellation t.store ~id:started.deployment.id)
          (fun _ ->
            ignore
              (Cancellation.request started.cancellation : Cancellation.request)));
    List.iter !(t.cancellations) ~f:(fun cancellation ->
        if
          not
            (List.exists active ~f:(fun started ->
                 phys_equal started.cancellation cancellation))
        then ignore (Cancellation.request cancellation : Cancellation.request));
    if Int.equal t.mutations.active_count 0 then
      Ivar.fill_if_empty t.mutations.drained ();
    Shutdown_started)

let mutations_drained t =
  if Int.equal t.mutations.active_count 0 then Deferred.unit
  else Ivar.read t.mutations.drained

let begin_mutation t =
  if not t.mutations.accepting then
    Or_error.error_string
      "application is shutting down; deploy and prune are unavailable"
  else (
    if Int.equal t.mutations.active_count 0 then
      t.mutations.drained <- Ivar.create ();
    t.mutations.active_count <- t.mutations.active_count + 1;
    Ok ())

let finish_mutation t =
  t.mutations.active_count <- t.mutations.active_count - 1;
  if t.mutations.active_count < 0 then
    raise_s [%message "application mutation accounting underflow"];
  if Int.equal t.mutations.active_count 0 then
    Ivar.fill_if_empty t.mutations.drained ()

let add_cancellation t cancellation =
  t.cancellations := cancellation :: !(t.cancellations)

let remove_cancellation t cancellation =
  t.cancellations :=
    List.filter !(t.cancellations) ~f:(fun active ->
        not (phys_equal active cancellation))

let remove_active t operation_id cancellation =
  (match Hashtbl.find t.active operation_id with
  | Some active when phys_equal active.cancellation cancellation ->
      Hashtbl.remove t.active operation_id
  | Some _ | None -> ());
  remove_cancellation t cancellation

let launch_deploy t ~request ~prepared =
  let working_directory = Deployment_request.working_directory request in
  let target = Deployment_request.target request in
  match begin_mutation t with
  | Error error -> Deferred.return (Error error)
  | Ok () -> (
      match canonical_working_directory working_directory with
      | Error error ->
          finish_mutation t;
          Deferred.return (Error error)
      | Ok working_directory -> (
          let scope = { working_directory; target } in
          let cancellation = Cancellation.create () in
          add_cancellation t cancellation;
          let started =
            Cancellation.within cancellation (fun () ->
                t.deploy_operation ~request ~prepared)
          in
          let%map result = started in
          match result with
          | Error error ->
              remove_cancellation t cancellation;
              finish_mutation t;
              Error error
          | Ok (deployment, operation_completion) ->
              let completion =
                let%bind.Deferred terminal = operation_completion in
                match terminal with
                | Ok { state = Succeeded; _ } ->
                    let%map _ =
                      Store.set_resource_state t.store ~working_directory
                        ~target Present
                    in
                    terminal
                | Ok { state = Requested | Running | Failed | Cancelled; _ }
                | Error _ ->
                    Deferred.return terminal
              in
              let started = { deployment; scope; cancellation; completion } in
              Hashtbl.set t.active ~key:deployment.id ~data:started;
              upon completion (fun _ ->
                  remove_active t deployment.id cancellation;
                  finish_mutation t);
              Ok started))

let start_request t ~request =
  match t.prepare_deploy with
  | None -> launch_deploy t ~request ~prepared:None
  | Some prepare ->
      let open Deferred.Or_error.Let_syntax in
      let%bind prepared = prepare ~request in
      launch_deploy t ~request ~prepared:(Some prepared)

let await_started_deployment started = started.completion
let started_deployment started = started.deployment
let started_deployment_id started = started.deployment.id

let request_cancellation t started =
  let%bind marker =
    Store.request_cancellation t.store ~id:started.deployment.id
  in
  let request = Cancellation.request started.cancellation in
  match (marker, request) with
  | Ok (), Accepted -> Deferred.Or_error.return Cancellation_requested
  | Ok (), Already_requested -> Deferred.Or_error.return Already_requested
  | Ok (), Too_late ->
      Deferred.Or_error.error_string "deployment is already finalizing"
  | Error error, (Accepted | Already_requested | Too_late) ->
      Deferred.return (Error error)

let cancel_started_deployment t started =
  match Hashtbl.find t.active started.deployment.id with
  | Some active when phys_equal active.cancellation started.cancellation ->
      request_cancellation t started
  | Some _ | None ->
      Deferred.Or_error.error_string
        "deployment is not active in this CLI process"

let immutable_source = Source.immutable

let start_direct_deployment ?expected_project t ~working_directory ~source
    ~target () =
  let open Deferred.Or_error.Let_syntax in
  let%bind request =
    Deferred.return
      (Deployment_request.create ?expected_project ~working_directory ~source
         ~target ())
  in
  start_request t ~request

let start_local_deployment t ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind source = t.local_source ~working_directory in
  start_direct_deployment t ~working_directory ~source ~target ()

let deploy_local_deployment t ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind started = start_local_deployment t ~working_directory ~target in
  await_started_deployment started

let deploy_direct_deployment ?expected_project t ~working_directory ~source
    ~target () =
  let open Deferred.Or_error.Let_syntax in
  let%bind started =
    start_direct_deployment ?expected_project t ~working_directory ~source
      ~target ()
  in
  await_started_deployment started

let live_status _t ~(scope : scope) =
  Status.load ~working_directory:scope.working_directory ~target:scope.target

let load_target ~working_directory ~target:target_name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind () =
    Deferred.return
      (Direct_mode.validate_configuration configuration ~target:target_name)
  in
  Deferred.return (Configuration.find_target configuration target_name)

let host_readiness ~working_directory ~target =
  let%bind.Deferred.Or_error target = load_target ~working_directory ~target in
  Host_readiness.inspect ~target |> Deferred.ok

let prune_local ?(mode = Everything) ?(dry_run = false) t ~working_directory
    ~target ~confirmed =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_working_directory working_directory)
  in
  let%bind () = Deferred.return (begin_mutation t) in
  Monitor.protect
    ~finally:(fun () ->
      finish_mutation t;
      Deferred.unit)
    (fun () ->
      Prune.prune_local ~store:t.store ~working_directory ~target ~confirmed
        ~mode ~dry_run)

let status_project = Status.project
let status_target = Status.target
let status_resource_key = Status.resource_key
let status_workloads = Status.workloads

let bounded_limit limit =
  if limit < 1 || limit > 100 then
    Or_error.error_string "history limit must be between 1 and 100"
  else Ok limit

let deployment_history t ~scope ~limit =
  match bounded_limit limit with
  | Error error -> Deferred.return (Error error)
  | Ok limit -> (
      match t.deployment_history_override with
      | Some history -> history ~scope ~limit
      | None ->
          let%map deployments =
            Store.list_for_scope t.store
              ~working_directory:scope.working_directory ~target:scope.target
              ~limit
          in
          Or_error.map deployments ~f:(fun deployments ->
              List.map deployments ~f:deployment_of_store
              |> List.filter ~f:(same_scope scope)))

let local_history t ~working_directory ~target ~limit =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind () =
    Deferred.return (Direct_mode.validate_configuration configuration ~target)
  in
  let%bind scope = Deferred.return (local_scope ~working_directory ~target) in
  deployment_history t ~scope ~limit

let equal_scope (left : scope) (right : scope) =
  String.equal left.working_directory right.working_directory
  && Target_name.equal left.target right.target

let deployment_can_cancel t ~scope deployment =
  same_scope scope deployment
  &&
  match Hashtbl.find t.active deployment.id with
  | Some active -> equal_scope scope active.scope
  | None -> false

let cancel_deployment t ~scope ~operation_id =
  let open Deferred.Or_error.Let_syntax in
  let%bind found = Store.find t.store ~id:operation_id in
  let%bind deployment =
    match Option.map found ~f:deployment_of_store with
    | None -> Deferred.Or_error.error_string "deployment does not exist"
    | Some deployment when same_scope scope deployment ->
        Deferred.Or_error.return deployment
    | Some _ ->
        Deferred.Or_error.error_string
          "deployment does not belong to the selected application"
  in
  let%bind active =
    match Hashtbl.find t.active operation_id with
    | Some active
      when same_scope scope deployment && same_scope active.scope deployment ->
        Deferred.Or_error.return active
    | Some _ ->
        Deferred.Or_error.error_string
          "deployment does not belong to the selected application"
    | None ->
        Deferred.Or_error.error_string
          "deployment is not active in this CLI process"
  in
  let%bind.Deferred marker =
    Store.request_cancellation t.store ~id:operation_id
  in
  match marker with
  | Error _ when Cancellation.was_requested active.cancellation ->
      Deferred.Or_error.return Already_requested
  | Error error -> Deferred.return (Error error)
  | Ok () -> (
      match Cancellation.request active.cancellation with
      | Too_late ->
          Deferred.Or_error.error_string "deployment is already finalizing"
      | Accepted -> Deferred.Or_error.return Cancellation_requested
      | Already_requested -> Deferred.Or_error.return Already_requested)

let resource_state_for_scope t ~(scope : scope) =
  Store.resource_state t.store ~working_directory:scope.working_directory
    ~target:scope.target

let local_logs _t ~working_directory ~target:target_name =
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
  let%bind runtime =
    Runbook_runtime.resolve_running ~project ~target ~resource_key
      ~repository_identity
  in
  let connection = Runbook_runtime.connection runtime in
  let container = Runbook_runtime.container runtime in
  let%map logs = Podman.read_logs ~connection ~container in
  {
    container_name = Podman.runtime_container_name container;
    revision = Podman.runtime_container_revision container;
    observed_at_ms = now_ms ();
    lines =
      List.map logs.lines ~f:(fun (line : Podman.log_line) ->
          { timestamp = line.timestamp; text = line.text });
    truncated = logs.truncated;
  }

let runbook ~working_directory ~target = Runbook.list ~working_directory ~target

let run ~on_selection ~working_directory ~target ~name =
  Runbook.run ~working_directory ~target ~name ~on_selection
    ~with_guard:(fun prepared action ->
      Mutation_guard.with_mutation
        ~certainty:(fun (outcome : Runbook.outcome) -> outcome.uncertainty)
        ~project:(Runbook.project prepared) ~target:(Runbook.target prepared)
        action)

let tracked_mutation t action =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (begin_mutation t) in
  Monitor.protect
    ~finally:(fun () ->
      finish_mutation t;
      Deferred.unit)
    action

let stop_local t ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_working_directory working_directory)
  in
  tracked_mutation t (fun () ->
      Stop.stop_local ~store:t.store ~working_directory ~target)

let stop_orphan t ~working_directory ~target ~resource_key =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_working_directory working_directory)
  in
  tracked_mutation t (fun () ->
      Orphan_prune.stop ~store:t.store ~working_directory ~target ~resource_key)

let resources ~working_directory ~target =
  Inventory.load ~working_directory ~target

let prune_orphan ?(dry_run = false) t ~working_directory ~target ~resource_key
    ~confirmed =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return (canonical_working_directory working_directory)
  in
  if dry_run then
    Orphan_prune.prune ~store:t.store ~working_directory ~target ~resource_key
      ~confirmed ~dry_run
  else
    let%bind () = Deferred.return (begin_mutation t) in
    Monitor.protect
      ~finally:(fun () ->
        finish_mutation t;
        Deferred.unit)
      (fun () ->
        Orphan_prune.prune ~store:t.store ~working_directory ~target
          ~resource_key ~confirmed ~dry_run)

let prune_project = Prune.project
let prune_target = Prune.target
let prune_resource_key = Prune.resource_key
let prune_containers_removed = Prune.containers_removed
let prune_secrets_removed = Prune.secrets_removed
let prune_secrets_retained = Prune.secrets_retained
let prune_mode = Prune.mode
let prune_dry_run = Prune.dry_run
let prune_containers = Prune.containers
let prune_secrets = Prune.secrets
let prune_image_references = Prune.image_references
let prune_image_bytes = Prune.image_bytes
let prune_notes = Prune.notes

let prune_route_state result =
  match Prune.route result with
  | Not_configured -> Not_configured
  | Missing -> Missing
  | Kept -> Kept

let commit_revision = Source.commit_revision
let commit_subject = Source.commit_subject
let commit_timestamp_ms = Source.commit_timestamp_ms
let deployment_id (deployment : deployment) = deployment.id
let deployment_state (deployment : deployment) = deployment.state
let deployment_stage (deployment : deployment) = deployment.stage
let deployment_message (deployment : deployment) = deployment.message
let deployment_revision (deployment : deployment) = deployment.revision

let deployment_commit_subject (deployment : deployment) =
  deployment.commit_subject

let deployment_commit_timestamp_ms (deployment : deployment) =
  deployment.commit_timestamp_ms

let deployment_container_name (deployment : deployment) =
  deployment.container_name

let deployment_error (deployment : deployment) = deployment.error

let deployment_requested_at_ms (deployment : deployment) =
  deployment.requested_at_ms

let deployment_started_at_ms (deployment : deployment) =
  deployment.started_at_ms

let deployment_finished_at_ms (deployment : deployment) =
  deployment.finished_at_ms

let deployment_cancel_requested_at_ms (deployment : deployment) =
  deployment.cancel_requested_at_ms

let deployment_updated_at_ms (deployment : deployment) =
  deployment.updated_at_ms

let deployment_state_name = Store.state_name

module For_testing = struct
  let create ?deployment_history ?local_source ~store ~deploy () =
    create_with_runtime ?deployment_history ?local_source ~store
      ~prepare_deploy:None ~deploy_operation:deploy ()

  let commit = Source.For_testing.commit

  let local_source ~working_directory commit =
    Source.For_testing.local ~working_directory commit

  let deployment ?legacy_application_key ?(working_directory = "")
      ?(target = Target_name.of_string "test" |> Or_error.ok_exn)
      ?(stage = "requested") ?(message = "Deployment requested") ?revision
      ?commit_subject ?commit_timestamp_ms ?container_name ?error
      ?(requested_at_ms = 0L) ?started_at_ms ?finished_at_ms
      ?cancel_requested_at_ms ?(updated_at_ms = requested_at_ms) ~id ~state () =
    {
      id;
      legacy_application_key;
      working_directory;
      target;
      state;
      stage;
      message;
      revision;
      commit_subject;
      commit_timestamp_ms;
      container_name;
      error;
      requested_at_ms;
      started_at_ms;
      finished_at_ms;
      cancel_requested_at_ms;
      updated_at_ms;
    }
end
