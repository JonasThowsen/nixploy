open Core

type t
(** An immutable, syntactically valid request to admit one managed deployment.
    Construction does not establish source custody, target authority, or a
    lease. *)

val create :
  managed_application_key:string ->
  requested_target:string ->
  provenance:string ->
  revision:string ->
  t Or_error.t

val managed_application_key : t -> string
val requested_target : t -> Target_name.t
val provenance : t -> string
val revision : t -> string
