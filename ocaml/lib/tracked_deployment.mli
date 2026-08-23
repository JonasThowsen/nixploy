open Async
open Core

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?on_authorized:(unit -> unit Deferred.Or_error.t) ->
  authorization:Operation_receipt.deploy ->
  store:Store.t ->
  unit ->
  Store.deployment Deferred.Or_error.t

val deploy_within_lease :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?on_authorized:(unit -> unit Deferred.Or_error.t) ->
  authorization:Operation_receipt.deploy ->
  store:Store.t ->
  unit ->
  Store.deployment Deferred.Or_error.t
(** Advanced entry point for application orchestration that already holds the
    target lease. [working_directory] must be canonical. *)

module For_testing : sig
  val terminalize_cancelled :
    request_marker:(unit -> unit Deferred.Or_error.t) ->
    cancel:(unit -> unit Deferred.Or_error.t) ->
    fail:(Error.t -> unit Deferred.Or_error.t) ->
    find_state:(unit -> Store.state option Deferred.Or_error.t) ->
    execution_error:Error.t ->
    unit Deferred.Or_error.t
end
