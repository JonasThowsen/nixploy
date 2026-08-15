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
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  prog:string ->
  args:string list ->
  unit ->
  t Deferred.Or_error.t

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
end
