open Async
open Core

type commit = Source.commit
type source = Source.selection
type prune_result = Prune.t
type status = Status.t

type prune_route_state = Not_configured | Missing | Removed
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

type health = Healthy | Unhealthy | Unavailable of string
[@@deriving compare, equal, sexp]

type metrics_freshness = Fresh | Stale | Unavailable
[@@deriving compare, equal, sexp]

type application_metrics = {
  application : string;
  container_name : string option;
  health : health;
  error : string option;
  cpu_percent : float option;
  memory_used_bytes : int64 option;
  memory_host_percent : float option;
  uptime_seconds : int64 option;
}

type target_metrics = {
  target : string;
  host : string;
  observed_at_ms : int64;
  freshness : metrics_freshness;
  error : string option;
  cpu_percent : float option;
  memory_used_bytes : int64 option;
  memory_total_bytes : int64 option;
  filesystem_used_bytes : int64 option;
  filesystem_total_bytes : int64 option;
  load_1 : float option;
  load_5 : float option;
  load_15 : float option;
  uptime_seconds : int64 option;
  applications : application_metrics list;
}

type deployment_preview = {
  commit : commit;
  receipt : string;
  prune_receipt : string;
}

type deployment = {
  id : string;
  application_key : string option;
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

type scope = {
  application_key : string option;
  working_directory : string;
  target : Target_name.t;
}

type started_deployment = {
  deployment : deployment;
  scope : scope;
  cancellation : Cancellation.t;
  completion : deployment Deferred.Or_error.t;
}

type active_operation = started_deployment

type mutation_lifecycle = {
  mutable accepting : bool;
  mutable active_count : int;
  drained : unit Ivar.t;
}

type cached_runtime = {
  working_directory : string;
  target : Target_name.t;
  resolution_id : string;
  mutation_id : string option;
  mutable expires_at : Time_ns.t;
  value : Runtime_application.t Or_error.t Deferred.t;
}

type cached_live_resource_state = {
  working_directory : string;
  target : Target_name.t;
  mutable expires_at : Time_ns.t;
  value : resource_state Deferred.t;
}

type t = {
  store : Store.t;
  preview_main : working_directory:string -> commit Deferred.Or_error.t;
  local_source : working_directory:string -> source Deferred.Or_error.t;
  find_commit :
    working_directory:string -> revision:string -> commit Deferred.Or_error.t;
  prepare_deploy :
    (authorization:Operation_receipt.deploy ->
    Deployment.prepared Deferred.Or_error.t)
    option;
  prepare_prune :
    (authorization:Operation_receipt.prune ->
    Prune.prepared Deferred.Or_error.t)
    option;
  deploy_operation :
    authorization:Operation_receipt.deploy ->
    prepared:Deployment.prepared option ->
    (deployment * deployment Deferred.Or_error.t) Deferred.Or_error.t;
  prune_operation :
    authorization:Operation_receipt.prune ->
    prepared:Prune.prepared option ->
    prune_result Deferred.Or_error.t;
  load_status : scope:scope -> status Deferred.Or_error.t;
  logs_override :
    (Managed_application.t -> log_snapshot Deferred.Or_error.t) option;
  metrics_override :
    (Managed_application.t -> target_metrics Deferred.t) option;
  verify_managed_source :
    Managed_application.t -> revision:string -> Source_authority.t Deferred.Or_error.t;
  deployment_history_override :
    (scope:scope -> limit:int -> deployment list Deferred.Or_error.t) option;
  active : active_operation String.Table.t;
  cancellations : Cancellation.t list ref;
  runtime_cache : cached_runtime String.Table.t;
  live_resource_state_cache : cached_live_resource_state String.Table.t;
  managed_applications : Managed_application.t list;
  mutations : mutation_lifecycle;
}

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let canonical_working_directory working_directory =
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)

let local_scope ~working_directory ~target =
  let%map.Or_error working_directory =
    canonical_working_directory working_directory
  in
  { application_key = None; working_directory; target }

let managed_scope application =
  let%map.Or_error working_directory =
    canonical_working_directory
      (Managed_application.working_directory application)
  in
  {
    application_key = Some (Managed_application.key application);
    working_directory;
    target = Managed_application.target application;
  }

let deployment_of_store deployment =
  {
    id = Store.id deployment;
    application_key = Store.application_key deployment;
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
  &&
  match (scope.application_key, deployment.application_key) with
  | Some expected, Some actual -> String.equal expected actual
  | Some _, None -> true
  | None, None -> true
  | None, Some _ -> false

let create_with_managed_applications ~managed_applications ~store () =
  let deploy_operation ~authorization ~prepared =
    let prepared = Option.value_exn prepared in
    let open Deferred.Or_error.Let_syntax in
    let%bind started =
      Tracked_deployment.start ~authorization ~prepared ~store ()
    in
    let deployment =
      Tracked_deployment.deployment started |> deployment_of_store
    in
    let completion =
      let%map.Deferred result = Tracked_deployment.completion started in
      Result.map result ~f:deployment_of_store
    in
    Deferred.Or_error.return (deployment, completion)
  in
  {
    store;
    preview_main = Source.preview_main;
    local_source = Source.local;
    find_commit = Source.find_commit;
    prepare_deploy = Some Deployment.prepare;
    prepare_prune = Some Prune.prepare;
    deploy_operation;
    prune_operation =
      (fun ~authorization ~prepared ->
        let prepared = Option.value_exn prepared in
        Monitor.protect
          ~finally:(fun () -> Prune.cleanup_prepared prepared)
          (fun () -> Prune.execute ~authorization prepared));
    load_status =
      (fun ~scope ->
        Status.load ~working_directory:scope.working_directory
          ~target:scope.target);
    logs_override = None;
    metrics_override = None;
    verify_managed_source = (fun application ~revision ->
      Source_authority.verify ~expected_revision:revision application);
    deployment_history_override = None;
    active = String.Table.create ();
    cancellations = ref [];
    runtime_cache = String.Table.create ();
    live_resource_state_cache = String.Table.create ();
    managed_applications;
    mutations = { accepting = true; active_count = 0; drained = Ivar.create () };
  }

let create ~store () =
  create_with_managed_applications ~managed_applications:[] ~store ()

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
    t.mutations.active_count <- t.mutations.active_count + 1;
    Ok ())

let finish_mutation t =
  t.mutations.active_count <- t.mutations.active_count - 1;
  if t.mutations.active_count < 0 then
    raise_s [%message "application mutation accounting underflow"];
  if (not t.mutations.accepting) && Int.equal t.mutations.active_count 0 then
    Ivar.fill_if_empty t.mutations.drained ()

let open_ ?(managed_applications = []) ~state_path () =
  let open Deferred.Or_error.Let_syntax in
  let%map store = Store.open_ ~path:state_path in
  create_with_managed_applications ~managed_applications ~store ()

let preview_main_commit t ~working_directory = t.preview_main ~working_directory

let managed_deployment_unavailable () =
  Or_error.error_string
    "NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE: immutable revision admission, \
     root-owned source custody, and authoritative target-lease broker \
     integration are required before managed deployment"

let preview_managed_deployment _t _requested_application =
  Deferred.return (managed_deployment_unavailable ())

let deployment_preview_commit (preview : deployment_preview) = preview.commit
let deployment_preview_receipt (preview : deployment_preview) = preview.receipt

let deployment_preview_prune_receipt (preview : deployment_preview) =
  preview.prune_receipt

let resolve_commit t ~working_directory ~revision =
  t.find_commit ~working_directory ~revision

let local_source t ~working_directory = t.local_source ~working_directory
let immutable_source commit = Source.immutable commit

let source_revision source =
  Source.selection_commit source |> Source.commit_revision

let source_subject source =
  Source.selection_commit source |> Source.commit_subject

let source_is_local = Source.selection_is_local

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

let invalidate_runtime_scope t ~working_directory ~target =
  Hashtbl.keys t.runtime_cache
  |> List.iter ~f:(fun key ->
      match Hashtbl.find t.runtime_cache key with
      | Some cached
        when String.equal cached.working_directory working_directory
             && Target_name.equal cached.target target ->
          Hashtbl.remove t.runtime_cache key
      | Some _ | None -> ())

let invalidate_live_resource_state_scope t ~working_directory ~target =
  Hashtbl.keys t.live_resource_state_cache
  |> List.iter ~f:(fun key ->
      match Hashtbl.find t.live_resource_state_cache key with
      | Some cached
        when String.equal cached.working_directory working_directory
             && Target_name.equal cached.target target ->
          Hashtbl.remove t.live_resource_state_cache key
      | Some _ | None -> ())

let invalidate_runtime_observations t ~working_directory ~target =
  invalidate_runtime_scope t ~working_directory ~target;
  invalidate_live_resource_state_scope t ~working_directory ~target

let launch_deploy t ~authorization ~prepared =
  let application_key =
    Operation_receipt.deploy_application_key authorization
  in
  let working_directory =
    Operation_receipt.deploy_working_directory authorization
  in
  let target = Operation_receipt.deploy_target authorization in
  match begin_mutation t with
  | Error error -> Deferred.return (Error error)
  | Ok () -> (
      match canonical_working_directory working_directory with
      | Error error ->
          finish_mutation t;
          Deferred.return (Error error)
      | Ok working_directory -> (
          invalidate_runtime_observations t ~working_directory ~target;
          let scope = { application_key; working_directory; target } in
          let cancellation = Cancellation.create () in
          add_cancellation t cancellation;
          let started =
            Cancellation.within cancellation (fun () ->
                t.deploy_operation ~authorization ~prepared)
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
                  invalidate_runtime_observations t ~working_directory ~target;
                  finish_mutation t);
              Ok started))

let start_authorization t ~authorization =
  match t.prepare_deploy with
  | None -> launch_deploy t ~authorization ~prepared:None
  | Some prepare ->
      let open Deferred.Or_error.Let_syntax in
      let%bind prepared = prepare ~authorization in
      launch_deploy t ~authorization ~prepared:(Some prepared)

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
        "deployment is not active in this control-plane process"

let direct_mode_fence t ~application_key ~working_directory ~target =
  let open Or_error.Let_syntax in
  let%bind managed_scopes =
    Or_error.all (List.map t.managed_applications ~f:managed_scope)
  in
  if
    Option.exists application_key ~f:(fun key ->
        List.exists t.managed_applications ~f:(fun application ->
            String.equal key (Managed_application.key application)))
  then
    Or_error.error_string
      "NIXPLOY_DIRECT_MODE_FORBIDDEN: direct mode cannot use a managed \
       application key"
  else if
    List.exists managed_scopes ~f:(fun managed ->
        String.equal managed.working_directory working_directory
        && Target_name.equal managed.target target)
  then
    Or_error.error_string
      "NIXPLOY_DIRECT_MODE_FORBIDDEN: direct mode overlaps a managed \
       application scope"
  else Ok ()

let start_direct_deployment ?application_key ?expected_project t ~working_directory
    ~source ~target () =
  match canonical_working_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory -> (
      match direct_mode_fence t ~application_key ~working_directory ~target with
      | Error error -> Deferred.return (Error error)
      | Ok () -> (
          match
            Operation_receipt.direct_deploy ~application_key ~expected_project
              ~intent:None ~application:None
              ~managed_applications:t.managed_applications ~working_directory
              ~source ~target
          with
          | Error error -> Deferred.return (Error error)
          | Ok authorization -> start_authorization t ~authorization))

let start_local_deployment t ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind source = local_source t ~working_directory in
  start_direct_deployment t ~working_directory ~source ~target ()

let deploy_local_deployment t ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let%bind started = start_local_deployment t ~working_directory ~target in
  await_started_deployment started

let admit_managed_deployment t requested_application ~revision =
  let open Deferred.Or_error.Let_syntax in
  let%bind _source_authority =
    t.verify_managed_source requested_application ~revision
  in
  Deferred.Or_error.error_string
    "NIXPLOY_MANAGED_DEPLOY_BROKER_UNCONFIGURED: the requested revision passed \
     root-owned source custody verification, but authoritative target-lease \
     broker admission is not configured"

let start_managed_deployment t requested_application =
  let working_directory = Managed_application.working_directory requested_application in
  let target = Managed_application.target requested_application in
  let open Deferred.Or_error.Let_syntax in
  let%bind source = local_source t ~working_directory in
  let%bind _source_authority =
    t.verify_managed_source requested_application
      ~revision:(source_revision source)
  in
  match
    Operation_receipt.direct_deploy
      ~application_key:(Some (Managed_application.key requested_application))
      ~expected_project:(Some (Managed_application.project requested_application))
      ~intent:None ~application:(Some requested_application)
      ~managed_applications:t.managed_applications ~working_directory ~source ~target
  with
  | Error error -> Deferred.return (Error error)
  | Ok authorization -> start_authorization t ~authorization

let deploy_managed_deployment t application =
  let open Deferred.Or_error.Let_syntax in
  let%bind started = start_managed_deployment t application in
  await_started_deployment started

let deploy_direct_deployment ?application_key ?expected_project t
    ~working_directory ~source ~target () =
  let open Deferred.Or_error.Let_syntax in
  let%bind started =
    start_direct_deployment ?application_key ?expected_project t ~working_directory
      ~source ~target ()
  in
  await_started_deployment started

let start_managed_preview _t _requested_application ~receipt:_ =
  Deferred.return (managed_deployment_unavailable ())

let deploy_managed_preview _t _requested_application ~receipt:_ =
  Deferred.return (managed_deployment_unavailable ())

let prune_disabled t =
  ignore t.prepare_prune;
  ignore t.prune_operation;
  Deferred.Or_error.error_string
    "prune is disabled in Production V1: durable prune operation lifecycle is \
     not implemented"

let prune_managed_preview t _requested_application ~receipt:_ = prune_disabled t

let prune_non_production ?application_key:_ ?expected_project:_
    ?repository_identity:_ t ~working_directory:_ ~target:_ =
  prune_disabled t

let live_status t ~scope = t.load_status ~scope
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
            match scope.application_key with
            | Some application_key ->
                Store.list_for_application t.store ~application_key
                  ~working_directory:scope.working_directory
                  ~target:scope.target ~limit
            | None ->
                Store.list_for_scope t.store
                  ~working_directory:scope.working_directory
                  ~target:scope.target ~limit
          in
          Or_error.map deployments ~f:(fun deployments ->
              List.map deployments ~f:deployment_of_store
              |> List.filter ~f:(same_scope scope)))

let equal_scope (left : scope) (right : scope) =
  String.equal left.working_directory right.working_directory
  && Target_name.equal left.target right.target
  && Option.equal String.equal left.application_key right.application_key

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
          "deployment is not active in this control-plane process"
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

let live_resource_state_cache_key (scope : scope) =
  String.concat
    [
      scope.working_directory;
      "\000";
      Target_name.to_string scope.target;
      "\000";
      Option.value scope.application_key ~default:"";
    ]

let live_resource_state_for_scope t ~(scope : scope) =
  let now = Time_ns.now () in
  let key = live_resource_state_cache_key scope in
  match Hashtbl.find t.live_resource_state_cache key with
  | Some cached
    when (not (Deferred.is_determined cached.value))
         || Time_ns.compare now cached.expires_at < 0 ->
      cached.value
  | Some _ | None ->
      let value =
        let%map inspected = live_status t ~scope in
        match inspected with
        | Error _ -> Unknown
        | Ok status ->
            if List.is_empty (Status.workloads status) then Absent else Present
      in
      let cached =
        {
          working_directory = scope.working_directory;
          target = scope.target;
          expires_at = Time_ns.add now (Time_ns.Span.of_sec 10.);
          value;
        }
      in
      Hashtbl.set t.live_resource_state_cache ~key ~data:cached;
      don't_wait_for
        (Deferred.map value ~f:(fun _ ->
             cached.expires_at <-
               Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 10.)));
      value

let resource_state t ~working_directory ~target =
  match local_scope ~working_directory ~target with
  | Error error -> Deferred.return (Error error)
  | Ok scope -> resource_state_for_scope t ~scope

let persisted_runtime_identity t application =
  let open Deferred.Or_error.Let_syntax in
  let%bind scope = Deferred.return (managed_scope application) in
  let application_key = Managed_application.key application in
  let%map deployment =
    Store.latest_successful_for_application t.store ~application_key
      ~working_directory:scope.working_directory ~target:scope.target
  in
  let identity =
    Option.bind deployment ~f:(fun deployment ->
        Option.map (Store.revision deployment) ~f:(fun revision ->
            (revision, Store.id deployment)))
  in
  (scope, identity)

let runtime_cache_key application (scope : scope) =
  String.concat
    [
      scope.working_directory;
      "\000";
      Target_name.to_string scope.target;
      "\000";
      Managed_application.repository_identity application;
    ]

let discover_runtime ?before_connection t application ~bootstrap_commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind identity =
    Runtime_application.discover_identity ?before_connection ~commit:bootstrap_commit
      application
  in
  let revision = Runtime_application.deployed_revision identity in
  let operation_id = Runtime_application.deployed_operation_id identity in
  let%bind commit =
    t.find_commit
      ~working_directory:(Managed_application.working_directory application)
      ~revision
  in
  Runtime_application.resolve ?before_connection ~commit ~operation_id application

let cached_runtime t ~(scope : scope) ~key ~resolution_id ~mutation_id ~resolve
    =
  let now = Time_ns.now () in
  match Hashtbl.find t.runtime_cache key with
  | Some cached
    when String.equal cached.resolution_id resolution_id
         && Option.equal String.equal cached.mutation_id mutation_id
         && Time_ns.compare now cached.expires_at < 0 ->
      cached.value
  | Some _ | None ->
      let value = resolve () in
      let cached =
        {
          working_directory = scope.working_directory;
          target = scope.target;
          resolution_id;
          mutation_id;
          expires_at = Time_ns.add now (Time_ns.Span.of_min 5.);
          value;
        }
      in
      Hashtbl.set t.runtime_cache ~key ~data:cached;
      don't_wait_for
        (Deferred.map value ~f:(fun result ->
             cached.expires_at <-
               Time_ns.add (Time_ns.now ())
                 (Time_ns.Span.of_sec (if Result.is_ok result then 10. else 3.))));
      value

let resolve_runtime ?before_connection t application =
  let open Deferred.Or_error.Let_syntax in
  let%bind scope, persisted_identity =
    persisted_runtime_identity t application
  in
  let%bind latest_scope =
    Store.list_for_scope t.store ~working_directory:scope.working_directory
      ~target:scope.target ~limit:1
  in
  let mutation_id = List.hd latest_scope |> Option.map ~f:Store.id in
  let key = runtime_cache_key application scope in
  let preview_main () =
    t.preview_main
      ~working_directory:(Managed_application.working_directory application)
  in
  match persisted_identity with
  | None ->
      let%bind bootstrap_commit = preview_main () in
      let resolution_id =
        "bootstrap:" ^ Source.commit_revision bootstrap_commit
      in
      cached_runtime t ~scope ~key ~resolution_id ~mutation_id
        ~resolve:(fun () ->
          discover_runtime ?before_connection t application ~bootstrap_commit)
  | Some (revision, deployment_id) ->
      let resolution_id =
        String.concat [ "persisted:"; deployment_id; ":"; revision ]
      in
      cached_runtime t ~scope ~key ~resolution_id ~mutation_id
        ~resolve:(fun () ->
          let exact =
            let open Deferred.Or_error.Let_syntax in
            let%bind commit =
              t.find_commit
                ~working_directory:
                  (Managed_application.working_directory application)
                ~revision
            in
            Runtime_application.resolve ?before_connection ~commit
              ~operation_id:deployment_id application
          in
          let%bind.Deferred exact = exact in
          match exact with
          | Ok _ -> Deferred.return exact
          | Error exact_error ->
              let%bind.Deferred bootstrap = preview_main () in
              let%bind.Deferred discovered =
                match bootstrap with
                | Error error -> Deferred.return (Error error)
                | Ok bootstrap_commit ->
                    discover_runtime ?before_connection t application
                      ~bootstrap_commit
              in
              Deferred.return
                (Result.map_error discovered ~f:(fun discovery_error ->
                     Error.create_s
                       [%message
                         "persisted and discovered runtime identity checks \
                          failed"
                           (exact_error : Error.t)
                           (discovery_error : Error.t)])))

let application_logs t application =
  match t.logs_override with
  | Some logs -> logs application
  | None -> (
      let key = Managed_application.key application in
      let open Deferred.Or_error.Let_syntax in
      let%bind runtime = resolve_runtime t application in
      let container = Runtime_application.container runtime in
      let%bind.Deferred snapshot =
        Podman.read_logs
          ~connection:(Runtime_application.connection runtime)
          ~container
      in
      match snapshot with
      | Error error ->
          Hashtbl.remove t.runtime_cache key;
          Deferred.return (Error error)
      | Ok snapshot ->
          Deferred.Or_error.return
            {
              container_name = Podman.runtime_container_name container;
              revision = Podman.runtime_container_revision container;
              observed_at_ms = now_ms ();
              lines =
                List.map snapshot.lines ~f:(fun line ->
                    { timestamp = line.timestamp; text = line.text });
              truncated = snapshot.truncated;
            })

let container_uptime container =
  Podman.runtime_container_started_at container
  |> Option.bind ~f:(fun started_at ->
      Or_error.try_with (fun () -> Time_ns.of_string_with_utc_offset started_at)
      |> Result.ok
      |> Option.map ~f:(fun started ->
          Time_ns.diff (Time_ns.now ()) started
          |> Time_ns.Span.to_sec |> Float.max 0. |> Float.iround_down_exn
          |> Int64.of_int))

let unavailable_metrics application error =
  let error = Error.to_string_hum error in
  {
    target = Managed_application.target application |> Target_name.to_string;
    host = "unavailable";
    observed_at_ms = now_ms ();
    freshness = Unavailable;
    error = Some error;
    cpu_percent = None;
    memory_used_bytes = None;
    memory_total_bytes = None;
    filesystem_used_bytes = None;
    filesystem_total_bytes = None;
    load_1 = None;
    load_5 = None;
    load_15 = None;
    uptime_seconds = None;
    applications =
      [
        {
          application = Managed_application.key application;
          container_name = None;
          health = Unavailable error;
          error = Some error;
          cpu_percent = None;
          memory_used_bytes = None;
          memory_host_percent = None;
          uptime_seconds = None;
        };
      ];
  }

let validate_metrics_target target =
  Host_metrics.cache_key target |> Result.map ~f:ignore |> Deferred.return

let observe_application_metrics t application =
  let%bind runtime =
    resolve_runtime ~before_connection:validate_metrics_target t application
  in
  match runtime with
  | Error error -> Deferred.return (unavailable_metrics application error)
  | Ok runtime ->
      let target = Runtime_application.target runtime in
      let container = Runtime_application.container runtime in
      let%map host_observation = Host_metrics.observe target
      and stats =
        Podman.read_stats
          ~connection:(Runtime_application.connection runtime)
          ~container
      and health =
        match
          ( Runtime_application.caddy runtime,
            Runtime_application.active_port runtime )
        with
        | Some caddy, Some port -> Caddy.observe_health caddy ~port
        | None, None ->
            Deferred.Or_error.error_string
              "health check is not configured for a non-web target"
        | Some _, None | None, Some _ ->
            Deferred.Or_error.error_string
              "runtime health configuration is inconsistent"
      in
      let host_error, host_value, host_observed_at_ms, freshness =
        match host_observation with
        | Host_metrics.Fresh sample ->
            ( None,
              Some (Host_metrics.sample_value sample),
              Host_metrics.sample_observed_at_ms sample,
              Fresh )
        | Host_metrics.Stale (sample, error) ->
            ( Some ("stale host metrics: " ^ Error.to_string_hum error),
              Some (Host_metrics.sample_value sample),
              Host_metrics.sample_observed_at_ms sample,
              Stale )
        | Host_metrics.Unavailable error ->
            (Some (Error.to_string_hum error), None, now_ms (), Unavailable)
      in
      let stats_value = Result.ok stats in
      let health =
        match health with
        | Ok true -> Healthy
        | Ok false -> Unhealthy
        | Error error -> Unavailable (Error.to_string_hum error)
      in
      let memory_host_percent =
        let open Option.Let_syntax in
        let%bind stats = stats_value in
        let%map host = host_value in
        Int64.to_float stats.memory_used_bytes
        /. Int64.to_float (Host_metrics.memory_total_bytes host)
        *. 100.
      in
      {
        target = Configuration.Target.name target |> Target_name.to_string;
        host =
          sprintf "%s@%s:%d"
            (Configuration.Target.user target)
            (Configuration.Target.host target)
            (Configuration.Target.port target);
        observed_at_ms = host_observed_at_ms;
        freshness;
        error = host_error;
        cpu_percent = Option.map host_value ~f:Host_metrics.cpu_percent;
        memory_used_bytes =
          Option.map host_value ~f:Host_metrics.memory_used_bytes;
        memory_total_bytes =
          Option.map host_value ~f:Host_metrics.memory_total_bytes;
        filesystem_used_bytes =
          Option.map host_value ~f:Host_metrics.filesystem_used_bytes;
        filesystem_total_bytes =
          Option.map host_value ~f:Host_metrics.filesystem_total_bytes;
        load_1 = Option.map host_value ~f:Host_metrics.load_1;
        load_5 = Option.map host_value ~f:Host_metrics.load_5;
        load_15 = Option.map host_value ~f:Host_metrics.load_15;
        uptime_seconds = Option.map host_value ~f:Host_metrics.uptime_seconds;
        applications =
          [
            {
              application = Managed_application.key application;
              container_name = Some (Podman.runtime_container_name container);
              health;
              error = Result.error stats |> Option.map ~f:Error.to_string_hum;
              cpu_percent =
                Option.bind stats_value ~f:(fun stats -> stats.cpu_percent);
              memory_used_bytes =
                Option.map stats_value ~f:(fun stats -> stats.memory_used_bytes);
              memory_host_percent;
              uptime_seconds = container_uptime container;
            };
          ];
      }

let application_metrics t application =
  match t.metrics_override with
  | Some metrics -> metrics application
  | None -> observe_application_metrics t application

let prune_project = Prune.project
let prune_target = Prune.target
let prune_resource_key = Prune.resource_key
let prune_containers_removed = Prune.containers_removed
let prune_secrets_removed = Prune.secrets_removed

let prune_route_state result =
  match Prune.route result with
  | Not_configured -> Not_configured
  | Missing -> Missing
  | Removed -> Removed

let commit_revision = Source.commit_revision
let commit_subject = Source.commit_subject
let commit_timestamp_ms = Source.commit_timestamp_ms
let deployment_id (deployment : deployment) = deployment.id

let deployment_application_key (deployment : deployment) =
  deployment.application_key

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
  let create ?status ?logs ?metrics ?verify_managed_source ?deployment_history
      ?local_source ?(managed_applications = []) ~store ~preview_main
      ~find_commit ~deploy ~prune () =
    {
      store;
      preview_main;
      local_source = Option.value local_source ~default:Source.local;
      find_commit;
      prepare_deploy = None;
      prepare_prune = None;
      deploy_operation = deploy;
      prune_operation = prune;
      load_status =
        Option.value status ~default:(fun ~(scope : scope) ->
            Status.load ~working_directory:scope.working_directory
              ~target:scope.target);
      logs_override = logs;
      metrics_override = metrics;
      verify_managed_source =
        Option.value verify_managed_source
          ~default:(fun _application ~revision:_ ->
            Deferred.Or_error.error_string "managed source verification must not run");
      deployment_history_override = deployment_history;
      active = String.Table.create ();
      cancellations = ref [];
      runtime_cache = String.Table.create ();
      live_resource_state_cache = String.Table.create ();
      managed_applications;
      mutations =
        { accepting = true; active_count = 0; drained = Ivar.create () };
    }

  let prune_result ~project ~target ~resource_key ~containers_removed
      ~secrets_removed ~(route : prune_route_state) =
    let route : Prune.route =
      match route with
      | Not_configured -> Not_configured
      | Missing -> Missing
      | Removed -> Removed
    in
    Prune.For_testing.result ~project ~target ~resource_key ~containers_removed
      ~secrets_removed ~route

  let commit = Source.For_testing.commit

  let local_source ~working_directory commit =
    Source.For_testing.local ~working_directory commit

  let deployment ?application_key ?(working_directory = "")
      ?(target = Target_name.of_string "test" |> Or_error.ok_exn)
      ?(stage = "requested") ?(message = "Deployment requested") ?revision
      ?commit_subject ?commit_timestamp_ms ?container_name ?error
      ?(requested_at_ms = 0L) ?started_at_ms ?finished_at_ms
      ?cancel_requested_at_ms ?(updated_at_ms = requested_at_ms) ~id ~state () =
    {
      id;
      application_key;
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
