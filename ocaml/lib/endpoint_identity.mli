open Core

val host : string -> string Or_error.t
(** Canonicalizes IPv4 and IPv6 text without DNS resolution. DNS names are
    lowercased and one optional trailing root dot is removed. Surrounding
    whitespace, malformed numeric addresses, scoped IPv6, and multiple trailing
    dots fail closed. *)

val domain : string -> string Or_error.t
(** Canonicalizes a DNS web domain using the same case and root-dot contract. *)

val coordination_scope : string -> string Or_error.t
(** Lowercases a coordination scope without accepting surrounding whitespace. *)
