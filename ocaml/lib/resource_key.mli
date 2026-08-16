open Core

type t [@@deriving compare, equal, sexp]

val derive :
  project:Project_name.t ->
  target:Target_name.t ->
  repository_identity:string ->
  t Or_error.t
(** Canonical identity bound to the stable repository identity, project, and
    target. *)

val derive_current :
  project:Project_name.t -> target:Target_name.t -> t Or_error.t
(** Repository-agnostic identity used by already deployed OCaml releases. *)

val derive_legacy :
  project:Project_name.t ->
  target:Target_name.t ->
  repository:string ->
  t Or_error.t

val candidates :
  project:Project_name.t ->
  target:Target_name.t ->
  repository_identity:string ->
  t list Or_error.t
(** Canonical identity followed by the existing OCaml and legacy C# migration
    identities, with duplicates removed. *)

val to_string : t -> string
