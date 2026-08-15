open Async
open Core

type commit = Source.commit

type t = {
  preview_main : working_directory:string -> commit Deferred.Or_error.t;
  find_commit :
    working_directory:string -> revision:string -> commit Deferred.Or_error.t;
  deploy :
    on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
    on_requested:(Store.deployment -> unit) ->
    application_key:string option ->
    working_directory:string ->
    commit:commit ->
    target:Target_name.t ->
    unit ->
    Store.deployment Deferred.Or_error.t;
}

let no_stage _ _ = Deferred.unit

let create ~store =
  let deploy ~on_stage ~on_requested ~application_key ~working_directory ~commit
      ~target () =
    Tracked_deployment.deploy ~on_stage ~on_requested ?application_key ~store
      ~working_directory ~commit ~target ()
  in
  {
    preview_main = Source.preview_main;
    find_commit = Source.find_commit;
    deploy;
  }

let preview_commit t ~working_directory = t.preview_main ~working_directory

let resolve_commit t ~working_directory ~revision =
  t.find_commit ~working_directory ~revision

let deploy ?(on_stage = no_stage) ?(on_requested = Fn.ignore) ?application_key t
    ~working_directory ~commit ~target () =
  t.deploy ~on_stage ~on_requested ~application_key ~working_directory ~commit
    ~target ()

let commit_revision = Source.commit_revision
let commit_subject = Source.commit_subject
let commit_timestamp_ms = Source.commit_timestamp_ms

module For_testing = struct
  let create ~preview_main ~find_commit ~deploy =
    { preview_main; find_commit; deploy }

  let commit = Source.For_testing.commit
end
