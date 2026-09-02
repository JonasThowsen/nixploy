open Core

type identity = Tailscale_login of string [@@deriving compare, equal, sexp]
type t

type factory = {
  now_ms : unit -> int64;
  random_bytes : int -> string Or_error.t;
  ttl_ms : int64;
}

val create : factory -> identity:identity -> capabilities:string list -> package_revision:string -> protocol_major:int -> protocol_minor:int -> t Or_error.t
val system_factory : unit -> factory
val token : t -> string
val issued_at_ms : t -> int64
val expires_at_ms : t -> int64
val validate : t -> token:string -> identity:identity -> package_revision:string -> protocol_major:int -> protocol_minor:int -> capability:string -> now_ms:int64 -> unit Or_error.t
