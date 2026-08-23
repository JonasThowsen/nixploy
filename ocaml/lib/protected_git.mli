open Async

type t

val admit :
  repository_root:string -> working_directory:string -> t Deferred.Or_error.t
(** Constructs one protected Git authority after verifying the custody root,
    common directory, object directory, local configuration, and alternate or
    replacement mechanisms. The process environment is fully replaced and no
    remote is contacted. *)

val stdout :
  ?max_output_bytes:int -> t -> string list -> string Deferred.Or_error.t
(** Runs Git against the admitted common directory and work tree with
    replacement objects disabled, the same fully replaced environment, and the
    admitted absolute executable. *)

val repository_root : t -> string
val common_directory : t -> string
