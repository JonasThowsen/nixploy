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
    kills owned children and waits for registered terminal cleanup before
    forcing process shutdown (including in-flight streaming spawns). *)

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

val terminal_attached : unit -> bool Deferred.t
(** Checks real stdin/stdout terminals off the Async scheduler. *)

val run_streaming :
  interactive:bool ->
  prog:string ->
  args:string list ->
  unit ->
  Core_unix.Exit_or_signal.t Deferred.Or_error.t
(** Inherits stdout/stderr separately without retaining any output.
    Noninteractive stdin is /dev/null; interactive stdin is the attached
    foreground terminal, temporarily handed to an owned child process group.
    Both normal and forced shutdown restore terminal ownership/settings.
    Cancellation interrupts output flushing before spawn, and takes precedence
    over a simultaneous wait result. No timeout or retry. Interrupt errors mean
    the remote command may still be running. *)

module For_testing : sig
  val should_force_termination : already_delivered:bool -> bool

  val streaming_completed :
    interrupted:bool ->
    Core_unix.Exit_or_signal.t ->
    Core_unix.Exit_or_signal.t Or_error.t
end
