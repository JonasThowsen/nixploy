open Core

type t [@@deriving compare, equal, sexp]

val derive : project:Project_name.t -> target:Target_name.t -> t Or_error.t

val derive_legacy :
  project:Project_name.t ->
  target:Target_name.t ->
  repository:string ->
  t Or_error.t

val to_string : t -> string
