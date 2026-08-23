open Async
open Core

type t = {
  stdout : string;
  stderr : string;
  exit_status : Core_unix.Exit_or_signal.t;
}

val handle_termination_signals : unit -> unit
val termination_signal : unit -> Signal.t option

val termination_requested : unit -> Signal.t Deferred.t
(** Resolves on the first handled SIGINT or SIGTERM. A second handled signal
    forces immediate process shutdown. *)

val run :
  ?working_directory:string ->
  ?stdin:string ->
  ?env:Core_unix.env ->
  ?ignore_termination:bool ->
  ?on_progress:(Time_ns.Span.t -> unit Deferred.t) ->
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  prog:string ->
  args:string list ->
  unit ->
  t Deferred.Or_error.t

(** When [on_progress] is provided, it receives elapsed-time heartbeats every 30
    seconds while the child is active, capped at 119 callbacks. Buffered stdout
    and stderr are never passed to the callback. *)

val run_stdout :
  ?working_directory:string ->
  ?stdin:string ->
  ?env:Core_unix.env ->
  ?ignore_termination:bool ->
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  prog:string ->
  args:string list ->
  unit ->
  string Deferred.Or_error.t

module For_testing : sig
  val should_force_termination : already_delivered:bool -> bool

  val with_progress_heartbeats :
    interval:Time_ns.Span.t ->
    max_heartbeats:int ->
    on_heartbeat:(Time_ns.Span.t -> unit Deferred.t) ->
    (unit -> 'a Deferred.t) ->
    'a Deferred.t
end
