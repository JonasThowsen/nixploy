open Core

type t
type production_destination
type target_lease
type destination_kind = Non_web | Web [@@deriving compare, equal, sexp]

val maximum_count : int
(** Host allowlists are bounded to keep polling and RPC response cardinality
    predictable. *)

val all_of_json : string -> t list Or_error.t

val load_authority_file : unit -> t list Or_error.t
(** Loads the one root-owned machine authority shared by CLI and web. *)

val load_authority_file_if_present : unit -> t list Or_error.t
(** Loads the protected authority when installed. An absent authority means no
    managed scopes are installed on this host. *)

val key : t -> string
val project : t -> Project_name.t
val target : t -> Target_name.t
val repository : t -> string
val repository_identity : t -> string
val repository_provenance : t -> string option
val repository_reference : t -> string option
val repository_evidence_file : t -> string option
val repository_evidence_max_age_seconds : t -> int
val target_lease : t -> target_lease option
val target_lease_authority : target_lease -> string
val target_lease_scope : target_lease -> string
val target_lease_identity : target_lease -> string
val production_destination : t -> production_destination option
val non_production_destination : t -> production_destination option
val destination_host : production_destination -> string
val destination_user : production_destination -> string
val destination_port : production_destination -> int
val destination_kind : production_destination -> destination_kind
val destination_domain : production_destination -> string option
val coordination_scope : production_destination -> string
val working_directory : t -> string
val find : t list -> string -> t Or_error.t
