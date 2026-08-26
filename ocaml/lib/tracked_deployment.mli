open Async
open Core

type started

val start :
  authorization:Operation_receipt.deploy ->
  prepared:Deployment.prepared ->
  store:Store.t ->
  unit ->
  started Deferred.Or_error.t
(** Receives one validated deployment request before creating an opaque handle.
    [Store.with_reconciled_lease] owns flock, predecessor reconciliation,
    request-to-operation binding, current resource-state mutation, execution,
    terminalization, and release. The durable [requested] row is admission
    history, not evidence of a resource mutation.

    Exact order: prepare and validate the selected source; acquire the target
    lease; reconcile a dead predecessor; create the admission row; bind the
    request to that row; mark current resource state [Unknown]; then write
    stages or run any remote process. *)

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
