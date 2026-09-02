open Core

type t
(** A trusted control-plane authority selected only from the root-owned operator
    record. The project-supplied alias cannot construct this value. *)

val alias : t -> string
val uri : t -> Uri.t
val pinned_server_spki_sha256 : t -> string
val trusted_proxy_authority : t -> Uri.t

val find : t list -> alias:string -> t Or_error.t
(** Finds one configured authority. Unknown aliases fail closed. *)

val load : unit -> t list Or_error.t
(** Loads [/etc/nixploy/control-plane-authorities.sexp]. The path and its parent
    directories must be root-owned, non-symlinked, and not writable by group or
    other users. *)

module For_testing : sig
  val parse : string -> t list Or_error.t

  val validate_file_metadata :
    uid:int -> perm:int -> regular:bool -> unit Or_error.t
end
