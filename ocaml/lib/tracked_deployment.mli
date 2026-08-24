open Async
open Core

type started

val start :
  authorization:Operation_receipt.deploy ->
  prepared:Deployment.prepared ->
  store:Store.t ->
  unit ->
  started Deferred.Or_error.t
(** Receives a claimed, validated capability before creating an opaque handle.
    [Store.with_reconciled_lease] owns flock, reconciliation, request,
    mutation, and release for that handle. *)

val deployment : started -> Store.deployment
val completion : started -> Store.deployment Deferred.Or_error.t

val deploy :
  authorization:Operation_receipt.deploy ->
  store:Store.t ->
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
