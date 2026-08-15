open Async
open Core

type commit = Source.commit
type source = Source.selection
type prune_result = Prune.t

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

type deployment = {
  id : string;
  state : deployment_state;
  revision : string option;
  container_name : string option;
  error : string option;
}

type t = {
  store : Store.t;
  preview_main : working_directory:string -> commit Deferred.Or_error.t;
  find_commit :
    working_directory:string -> revision:string -> commit Deferred.Or_error.t;
  deploy :
    on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
    on_requested:(deployment -> unit) ->
    application_key:string option ->
    expected_project:Project_name.t option ->
    working_directory:string ->
    source:source ->
    target:Target_name.t ->
    unit ->
    deployment Deferred.Or_error.t;
  prune :
    expected_project:Project_name.t option ->
    repository_identity:string option ->
    working_directory:string ->
    target:Target_name.t ->
    prune_result Deferred.Or_error.t;
}

let no_stage _ _ = Deferred.unit

let deployment_of_store deployment =
  {
    id = Store.id deployment;
    state = Store.state deployment;
    revision = Store.revision deployment;
    container_name = Store.container_name deployment;
    error = Store.error deployment;
  }

let create ~store () =
  let deploy ~on_stage ~on_requested ~application_key ~expected_project
      ~working_directory ~source ~target () =
    let open Deferred.Or_error.Let_syntax in
    Tracked_deployment.deploy_within_lease ~on_stage
      ~on_requested:(fun deployment ->
        on_requested (deployment_of_store deployment))
      ?application_key ?expected_project ~store ~working_directory ~source
      ~target ()
    >>| deployment_of_store
  in
  {
    store;
    preview_main = Source.preview_main;
    find_commit = Source.find_commit;
    deploy;
    prune =
      (fun ~expected_project ~repository_identity ~working_directory ~target ->
        Prune.prune ?expected_project ?repository_identity ~working_directory
          ~target ());
  }

let preview_main_commit t ~working_directory = t.preview_main ~working_directory

let resolve_commit t ~working_directory ~revision =
  t.find_commit ~working_directory ~revision

let local_source _t ~working_directory = Source.local ~working_directory
let immutable_source = Source.immutable

let source_revision source =
  Source.selection_commit source |> Source.commit_revision

let source_subject source =
  Source.selection_commit source |> Source.commit_subject

let source_is_local = Source.selection_is_local

let canonical_working_directory working_directory =
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)

let deploy ?(on_stage = no_stage) ?(on_requested = Fn.ignore) ?application_key
    ?expected_project t ~working_directory ~source ~target () =
  match canonical_working_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      Store.with_lease t.store ~working_directory ~target (fun () ->
          let open Deferred.Or_error.Let_syntax in
          let%bind () =
            Store.set_resource_state t.store ~working_directory ~target Unknown
          in
          let%bind deployment =
            t.deploy ~on_stage ~on_requested ~application_key ~expected_project
              ~working_directory ~source ~target ()
          in
          let%map () =
            match deployment.state with
            | Succeeded ->
                Store.set_resource_state t.store ~working_directory ~target
                  Present
            | Requested | Running | Failed | Cancelled ->
                Deferred.Or_error.return ()
          in
          deployment)

let prune ?expected_project ?repository_identity t ~working_directory ~target =
  match canonical_working_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      Store.with_lease t.store ~working_directory ~target (fun () ->
          let open Deferred.Or_error.Let_syntax in
          let%bind () =
            Store.set_resource_state t.store ~working_directory ~target Unknown
          in
          let%bind result =
            t.prune ~expected_project ~repository_identity ~working_directory
              ~target
          in
          let%map () =
            Store.set_resource_state t.store ~working_directory ~target Absent
          in
          result)

let resource_state t ~working_directory ~target =
  match canonical_working_directory working_directory with
  | Error error -> Deferred.return (Error error)
  | Ok working_directory ->
      Store.resource_state t.store ~working_directory ~target

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
let deployment_id deployment = deployment.id
let deployment_state deployment = deployment.state
let deployment_revision deployment = deployment.revision
let deployment_container_name deployment = deployment.container_name
let deployment_error deployment = deployment.error
let deployment_state_name = Store.state_name

module For_testing = struct
  let create ~store ~preview_main ~find_commit ~deploy ~prune =
    { store; preview_main; find_commit; deploy; prune }

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

  let deployment ?revision ?container_name ?error ~id ~state () =
    { id; state; revision; container_name; error }
end
