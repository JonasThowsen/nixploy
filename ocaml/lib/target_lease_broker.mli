open Core

(** Linux Unix-socket broker for the bounded target-lease tracer. *)

type configuration

val create_configuration :
  socket_path:string ->
  state_directory:string ->
  authority:string ->
  scopes:string list ->
  allowed_users:string list ->
  configuration Or_error.t

val run : configuration -> unit Or_error.t
