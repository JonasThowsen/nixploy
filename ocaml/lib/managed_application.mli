open Core

type t
type production_destination
type destination_kind = Non_web | Web [@@deriving compare, equal, sexp]

val maximum_count : int
(** Host allowlists are bounded to keep polling and RPC response cardinality
    predictable. *)

val all_of_json : string -> t list Or_error.t
val load_environment : unit -> t list Or_error.t
val key : t -> string
val project : t -> Project_name.t
val target : t -> Target_name.t
val repository : t -> string
val repository_identity : t -> string
val repository_provenance : t -> string option
val production_destination : t -> production_destination option
val destination_host : production_destination -> string
val destination_user : production_destination -> string
val destination_port : production_destination -> int
val destination_kind : production_destination -> destination_kind
val destination_domain : production_destination -> string option
val coordination_scope : production_destination -> string
val working_directory : t -> string
val find : t list -> string -> t Or_error.t
