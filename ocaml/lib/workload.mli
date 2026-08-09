open Core

type t

val all_of_json : string -> t list Or_error.t
val name : t -> string
val image : t -> string option
val state : t -> string option
val status : t -> string option
val revision : t -> string option
