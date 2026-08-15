open Async
open Core

type commit = Source.commit

type deployment_state = Store.state =
  | Requested
  | Running
  | Succeeded
  | Failed
  | Cancelled
[@@deriving compare, equal, sexp]

type deployment = {
  id : string;
  state : deployment_state;
  revision : string option;
  container_name : string option;
  error : string option;
}

type t = {
  preview_main : working_directory:string -> commit Deferred.Or_error.t;
  find_commit :
    working_directory:string -> revision:string -> commit Deferred.Or_error.t;
  deploy :
    on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
    on_requested:(deployment -> unit) ->
    application_key:string option ->
    working_directory:string ->
    commit:commit ->
    target:Target_name.t ->
    unit ->
    deployment Deferred.Or_error.t;
  prune :
    working_directory:string ->
    target:Target_name.t ->
    Prune.t Deferred.Or_error.t;
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

let create ?store () =
  let default_store = lazy (Store.open_ ~path:(State_path.default ())) in
  let get_store () =
    match store with
    | Some store -> Deferred.Or_error.return store
    | None -> Lazy.force default_store
  in
  let deploy ~on_stage ~on_requested ~application_key ~working_directory ~commit
      ~target () =
    let open Deferred.Or_error.Let_syntax in
    let%bind store = get_store () in
    Tracked_deployment.deploy ~on_stage
      ~on_requested:(fun deployment ->
        on_requested (deployment_of_store deployment))
      ?application_key ~store ~working_directory ~commit ~target ()
    >>| deployment_of_store
  in
  {
    preview_main = Source.preview_main;
    find_commit = Source.find_commit;
    deploy;
    prune = Prune.prune;
  }

let preview_main_commit t ~working_directory = t.preview_main ~working_directory

let resolve_commit t ~working_directory ~revision =
  t.find_commit ~working_directory ~revision

let deploy ?(on_stage = no_stage) ?(on_requested = Fn.ignore) ?application_key t
    ~working_directory ~commit ~target () =
  t.deploy ~on_stage ~on_requested ~application_key ~working_directory ~commit
    ~target ()

let prune t ~working_directory ~target = t.prune ~working_directory ~target
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
  let create ~preview_main ~find_commit ~deploy ~prune =
    { preview_main; find_commit; deploy; prune }

  let commit = Source.For_testing.commit

  let deployment ?revision ?container_name ?error ~id ~state () =
    { id; state; revision; container_name; error }
end
