open Core

type t

val all_of_json : string -> t list Or_error.t

val all_owned_of_json :
  project:Project_name.t ->
  target:Target_name.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  expected_names:string list ->
  string ->
  t list Or_error.t
(** Parses status readback only when every returned container has an exact
    derived name, the complete matching modern ownership identity, and the
    canonical modern repository identity label. *)

val name : t -> string
val image : t -> string option
val state : t -> string option
val status : t -> string option
val revision : t -> string option
