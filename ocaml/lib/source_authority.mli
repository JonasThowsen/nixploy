open Async
open Core

type t

val verify :
  ?expected_revision:string -> Managed_application.t -> t Deferred.Or_error.t
(** Verifies a root-protected Git custody repository, fresh root-owned evidence
    manifest, configured ref, and exact commit object. No remote is contacted.
*)

val commit : t -> Source.commit
val revision : t -> string
val provenance : t -> string
val reference : t -> string
val evidence_digest : t -> string
val repository_root : t -> string

module For_testing : sig
  val create :
    commit:Source.commit ->
    provenance:string ->
    reference:string ->
    evidence_digest:string ->
    repository_root:string ->
    t

  val validate_manifest :
    now_seconds:float ->
    max_age_seconds:int ->
    expected_provenance:string ->
    expected_reference:string ->
    string ->
    unit Or_error.t
end
