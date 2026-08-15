open Async
open Core

type t
type commit

val create : store:Store.t -> t
val preview_commit : t -> working_directory:string -> commit Deferred.Or_error.t

val resolve_commit :
  t -> working_directory:string -> revision:string -> commit Deferred.Or_error.t

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?application_key:string ->
  t ->
  working_directory:string ->
  commit:commit ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t

val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64

module For_testing : sig
  val create :
    preview_main:(working_directory:string -> commit Deferred.Or_error.t) ->
    find_commit:
      (working_directory:string ->
      revision:string ->
      commit Deferred.Or_error.t) ->
    deploy:
      (on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
      on_requested:(Store.deployment -> unit) ->
      application_key:string option ->
      working_directory:string ->
      commit:commit ->
      target:Target_name.t ->
      unit ->
      Store.deployment Deferred.Or_error.t) ->
    t

  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t
end
