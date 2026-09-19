open Core

(** Image references that nixploy owns.

    Deploy tags every loaded image into a repository derived from the resource
    key and removes the archive's own tag, so images reachable only through that
    repository belong to the target. Tags sort chronologically. *)

val repository : Resource_key.t -> string
(** [localhost/nixploy/<resource key>], normalized to a valid repository path.
*)

val reference :
  Resource_key.t -> loaded_at:Time_float.t -> revision:string -> string
(** [<repository>:<UTC yyyymmddThhmmssZ>-<revision prefix>]. *)

val tag : repository:string -> string -> string option
(** The tag of a reference in exactly [repository], or [None] for any other
    repository (including ones that merely share its prefix). *)
