open Core

type t

val all_of_json : string -> t list Or_error.t
val find_for_target : t list -> Configuration.Target.t -> t Or_error.t
val find_by_name : t list -> string -> t option
val matches_target : t -> Configuration.Target.t -> bool
val matches_identity : t -> string option -> bool
val name : t -> string
val identity : t -> string option
