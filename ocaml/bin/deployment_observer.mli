open Async
open Core

type outcome =
  | Completed of Nixploy.Application.deployment
  | Interrupted of Signal.t

val observe_and_drain :
  ?termination:Signal.t Deferred.t ->
  render_stage:(string -> string -> unit) ->
  Nixploy.Application.t ->
  scope:Nixploy.Application.scope ->
  Nixploy.Application.started_deployment ->
  outcome Deferred.Or_error.t
(** Observes durable history for display only. If observation fails, a signal is
    received, or rendering raises, it cancels and awaits the exact opaque
    started operation before returning. *)
