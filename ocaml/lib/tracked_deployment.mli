open Async
open Core

type started

val start :
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  store:Store.t ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  unit ->
  started Deferred.Or_error.t
(** Starts a lease-held deployment after its durable requested event exists. No
    observer callback runs on the mutation path. *)

val deployment : started -> Store.deployment
val completion : started -> Store.deployment Deferred.Or_error.t

val deploy :
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  store:Store.t ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t

module For_testing : sig
  val terminalize_cancelled :
    request_marker:(unit -> unit Deferred.Or_error.t) ->
    cancel:(unit -> unit Deferred.Or_error.t) ->
    fail:(Error.t -> unit Deferred.Or_error.t) ->
    find_state:(unit -> Store.state option Deferred.Or_error.t) ->
    execution_error:Error.t ->
    unit Deferred.Or_error.t
end
