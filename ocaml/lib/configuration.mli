open Core

module Run : sig
  type t

  val command : t -> string list option
  val environment : t -> (string * string) list
  val rendered_environment : t -> port:int -> (string * string) list
  val pre_start : t -> string list list
  val network : t -> string option
  val ports : t -> string list
end

module Web : sig
  type t

  val domain : t -> string
  val health_path : t -> string
  val blue_port : t -> int
  val green_port : t -> int
end

module Target : sig
  type t

  val name : t -> Target_name.t
  val image : t -> string
  val host : t -> string
  val user : t -> string
  val port : t -> int
  val identity_file : t -> string option
  val run : t -> Run.t
  val web : t -> Web.t option
  val secret_references : t -> (string * string) list
  val require_web : t -> Web.t Or_error.t
end

type t

val of_json : string -> t Or_error.t
val project : t -> Project_name.t
val targets : t -> Target.t list
val find_target : t -> Target_name.t -> Target.t Or_error.t
