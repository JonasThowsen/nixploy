open Core

(** Linux Unix-socket broker for the bounded target-lease tracer. *)

type configuration

val create_configuration :
  socket_path:string ->
  state_directory:string ->
  authority:string ->
  identity:string ->
  scope_users:(string * string list) list ->
  configuration Or_error.t

(** Runs until an operational or durable-state failure.  In particular, a
    failed post-unlink directory fsync is fatal: no further leases are served. *)
val run : configuration -> unit Or_error.t
