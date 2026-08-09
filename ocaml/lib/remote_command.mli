open Async
open Core

val run :
  ?stdin:string ->
  target:Configuration.Target.t ->
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  string list ->
  Process_runner.t Deferred.Or_error.t
