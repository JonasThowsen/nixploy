open Async
open Core

type t
type commit
type deployment
type prune_result

type prune_route_state = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type deployment_state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

val create : store:Store.t -> unit -> t

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

val prune :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  prune_result Deferred.Or_error.t

val resource_state :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_state Deferred.Or_error.t

val prune_project : prune_result -> Project_name.t
val prune_target : prune_result -> Target_name.t
val prune_resource_key : prune_result -> Resource_key.t
val prune_containers_removed : prune_result -> int
val prune_secrets_removed : prune_result -> int
val prune_route_state : prune_result -> prune_route_state
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
    store:Store.t ->
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
    prune:
      (working_directory:string ->
      target:Target_name.t ->
      prune_result Deferred.Or_error.t) ->
    t

  val prune_result :
    project:Project_name.t ->
    target:Target_name.t ->
    resource_key:Resource_key.t ->
    containers_removed:int ->
    secrets_removed:int ->
    route:prune_route_state ->
    prune_result

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
