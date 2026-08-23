open Core

type t

type identity_policy = Canonical_only | Migration_candidates
[@@deriving compare, equal, sexp]

val create :
  application:Managed_application.t ->
  repository_origin:string option ->
  revision:string ->
  configuration:Configuration.t ->
  configuration_json:string ->
  t Or_error.t
(** Validates the root-managed application, exact Git provenance, evaluated
    project/target, and production destination as one immutable deployment
    intent. *)

val validate_evaluated :
  t ->
  repository_origin:string option ->
  revision:string ->
  configuration:Configuration.t ->
  configuration_json:string ->
  unit Or_error.t
(** Recomputes authoritative intent and requires exact equality before any
    remote or secret mutation. *)

val resource_key : t -> Resource_key.t
val identity_policy : t -> identity_policy
