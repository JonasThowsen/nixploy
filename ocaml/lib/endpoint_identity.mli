open Core

val host : string -> string Or_error.t
(** Canonicalizes a DNS/IP-style SSH endpoint for equality: surrounding space,
    ASCII case, and trailing DNS dots do not create distinct authority. *)

val domain : string -> string Or_error.t
(** Canonicalizes a web domain using the same DNS equivalence. *)

val coordination_scope : string -> string Or_error.t
(** Canonicalizes a coordination scope before authority intersection checks. *)
