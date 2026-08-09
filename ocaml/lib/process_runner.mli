open Async
open Core

type t = {
  stdout : string;
  stderr : string;
  exit_status : Core_unix.Exit_or_signal.t;
}

val run :
  ?working_directory:string ->
  ?stdin:string ->
  ?env:Core_unix.env ->
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
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  prog:string ->
  args:string list ->
  unit ->
  string Deferred.Or_error.t
