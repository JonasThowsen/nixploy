open Core

type t

val all_of_json : string -> t list Or_error.t
val load_environment : unit -> t list Or_error.t
val key : t -> string
val project : t -> Project_name.t
val target : t -> Target_name.t
val repository : t -> string
val working_directory : t -> string
val find : t list -> string -> t Or_error.t
