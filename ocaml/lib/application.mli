open Async
open Core

type t
type commit
type deployment

type deployment_state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

val create : store:Store.t -> t

val preview_main_commit :
  t -> working_directory:string -> commit Deferred.Or_error.t

val resolve_commit :
  t -> working_directory:string -> revision:string -> commit Deferred.Or_error.t

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(deployment -> unit) ->
  ?application_key:string ->
  t ->
  working_directory:string ->
  commit:commit ->
  target:Target_name.t ->
  unit ->
  deployment Deferred.Or_error.t

val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64
val deployment_id : deployment -> string
val deployment_state : deployment -> deployment_state
val deployment_revision : deployment -> string option
val deployment_container_name : deployment -> string option
val deployment_error : deployment -> string option
val deployment_state_name : deployment_state -> string

module For_testing : sig
  val create :
    preview_main:(working_directory:string -> commit Deferred.Or_error.t) ->
    find_commit:
      (working_directory:string ->
      revision:string ->
      commit Deferred.Or_error.t) ->
    deploy:
      (on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
      on_requested:(deployment -> unit) ->
      application_key:string option ->
      working_directory:string ->
      commit:commit ->
      target:Target_name.t ->
      unit ->
      deployment Deferred.Or_error.t) ->
    t

  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t

  val deployment :
    ?revision:string ->
    ?container_name:string ->
    ?error:string ->
    id:string ->
    state:deployment_state ->
    unit ->
    deployment
end
