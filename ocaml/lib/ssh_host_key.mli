open Core

type t
(** A canonical SHA-256 SSH host-key fingerprint. *)

val of_fingerprint : string -> t Or_error.t
val fingerprint : t -> string
