open Core

type t [@@deriving compare, equal, sexp]

val of_string : string -> t Or_error.t
val to_string : t -> string
