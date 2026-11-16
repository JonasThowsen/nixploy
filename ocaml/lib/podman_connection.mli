open Core

type t

val all_of_json : string -> t list Or_error.t
val find_by_name : t list -> string -> t option
val name : t -> string

val serves_socket : t -> string -> bool
(** The connection is [unix://] to exactly this local socket path. *)
