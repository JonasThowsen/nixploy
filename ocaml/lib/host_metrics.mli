open Async
open Core

type t

type sample
(** One host metric value bound to the monotonic instant at which it was read. *)

type observation = Fresh of sample | Stale of sample * Error.t | Unavailable of Error.t
(** [Stale] retains the last bounded-good observation when its replacement
    attempt fails. [Unavailable] never causes an SSH connection when the target
    has no valid SSH host-key fingerprint. *)

val sample_value : sample -> t
val sample_observed_at_ms : sample -> int64

type cache

val cache_key : Configuration.Target.t -> string Or_error.t
(** The canonical endpoint key contains normalized host, port, and the exact
    validated SSH host-key fingerprint. *)

val observe : Configuration.Target.t -> observation Deferred.t
val cpu_percent : t -> float
val memory_used_bytes : t -> int64
val memory_total_bytes : t -> int64
val filesystem_used_bytes : t -> int64
val filesystem_total_bytes : t -> int64
val load_1 : t -> float
val load_5 : t -> float
val load_15 : t -> float
val uptime_seconds : t -> int64

module For_testing : sig
  val parse : string -> t Or_error.t

  val create_cache :
    now:(unit -> Time_ns.t) ->
    fresh_for:Time_ns.Span.t ->
    stale_for:Time_ns.Span.t ->
    observe:(Configuration.Target.t -> t Deferred.Or_error.t) ->
    unit ->
    cache

  val observe_cached : cache -> Configuration.Target.t -> observation Deferred.t
end
