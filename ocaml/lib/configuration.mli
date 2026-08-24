open Core

module Read_only_bind : sig
  type t
  (** A read-only bind with non-root absolute normalized source and destination
      paths. Values can only be constructed by validated configuration parsing.
  *)

  val source : t -> string
  val destination : t -> string
end

module Run : sig
  type t

  val command : t -> string list option
  val environment : t -> (string * string) list

  (* None preserves the corresponding literal placeholder for explicit
     source-free inspection and tests. *)
  val rendered_environment :
    t -> port:int option -> revision:string option -> (string * string) list

  val pre_start : t -> string list list
  val network : t -> string option
  val ports : t -> string list
  val read_only_binds : t -> Read_only_bind.t list
end

module Web : sig
  type t

  val domain : t -> string
  val health_path : t -> string
  val blue_port : t -> int
  val green_port : t -> int
end

module Production : sig
  type t

  val coordination_scope : t -> string
end

module Non_production : sig
  type t

  val coordination_scope : t -> string
end

module Target : sig
  type t
  type kind = Non_web | Web of Web.t

  val name : t -> Target_name.t
  val image : t -> string
  val host : t -> string
  val user : t -> string
  val port : t -> int
  val identity_file : t -> string option
  val run : t -> Run.t
  val web : t -> Web.t option
  val secret_references : t -> (string * string) list
  val production : t -> Production.t option
  val non_production : t -> Non_production.t option
  val kind : t -> kind
  val require_web : t -> Web.t Or_error.t
end

type t

val of_json : string -> t Or_error.t
val project : t -> Project_name.t
val targets : t -> Target.t list
val find_target : t -> Target_name.t -> Target.t Or_error.t
