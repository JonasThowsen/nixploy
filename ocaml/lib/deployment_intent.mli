open Core

type t

type identity_policy = Canonical_only | Migration_candidates
[@@deriving compare, equal, sexp]

val create :
  application:Managed_application.t ->
  source_authority:Source_authority.t option ->
  revision:string ->
  configuration:Configuration.t ->
  configuration_json:string ->
  t Or_error.t
(** Builds immutable intent from one managed application contract and the
    evaluated deployment configuration.  Source custody is a selection policy,
    not mutation authority. *)

val validate_application : t -> Managed_application.t -> unit Or_error.t
(** Rejects pairing an intent with any application other than the exact
    root-managed contract from which it was created. *)

val validate_evaluated :
  t ->
  source_authority:Source_authority.t option ->
  revision:string ->
  configuration:Configuration.t ->
  configuration_json:string ->
  unit Or_error.t
(** Requires exact source, configuration, destination, scope, and digest
    equality before deployment state may be written. *)

val authorize_local :
  applications:Managed_application.t list ->
  working_directory:string ->
  configuration:Configuration.t ->
  target:Configuration.Target.t ->
  identity_policy Or_error.t
(** Permits only an explicitly non-production direct checkout whose evaluated
    coordination scope differs from every managed destination scope. *)

val resource_key : t -> Resource_key.t
val identity_policy : t -> identity_policy
val repository_identity : t -> string
val revision : t -> string
