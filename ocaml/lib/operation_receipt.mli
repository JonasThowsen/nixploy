open Core

type deploy_store
type prune_store
type deploy
type prune

val create_deploy_store :
  ?capacity:int ->
  ?ttl_seconds:float ->
  ?now:(unit -> float) ->
  ?random_bytes:(int -> string Or_error.t) ->
  unit ->
  deploy_store Or_error.t

val create_prune_store :
  ?capacity:int ->
  ?ttl_seconds:float ->
  ?now:(unit -> float) ->
  ?random_bytes:(int -> string Or_error.t) ->
  unit ->
  prune_store Or_error.t

val issue_deploy :
  deploy_store ->
  application_key:string option ->
  expected_project:Project_name.t option ->
  intent:Deployment_intent.t option ->
  application:Managed_application.t option ->
  managed_applications:Managed_application.t list ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  string Or_error.t

val issue_prune :
  prune_store ->
  application_key:string option ->
  expected_project:Project_name.t option ->
  repository_identity:string option ->
  intent:Deployment_intent.t option ->
  application:Managed_application.t option ->
  commit:Source.commit option ->
  working_directory:string ->
  target:Target_name.t ->
  string Or_error.t

val consume_deploy :
  deploy_store -> application_key:string -> receipt:string -> deploy Or_error.t

val consume_prune :
  prune_store -> application_key:string -> receipt:string -> prune Or_error.t

val deploy_application_key : deploy -> string option
val deploy_expected_project : deploy -> Project_name.t option
val deploy_intent : deploy -> Deployment_intent.t option
val deploy_application : deploy -> Managed_application.t option
val deploy_managed_applications : deploy -> Managed_application.t list
val deploy_working_directory : deploy -> string
val deploy_source : deploy -> Source.selection
val deploy_target : deploy -> Target_name.t
val claim_deploy : deploy -> unit Or_error.t
val bind_deploy_operation : deploy -> operation_id:string -> unit Or_error.t
val validate_deploy_operation : deploy -> operation_id:string -> unit Or_error.t
val prune_application_key : prune -> string option
val prune_expected_project : prune -> Project_name.t option
val prune_repository_identity : prune -> string option
val prune_intent : prune -> Deployment_intent.t option
val prune_application : prune -> Managed_application.t option
val prune_commit : prune -> Source.commit option
val prune_working_directory : prune -> string
val prune_target : prune -> Target_name.t
val claim_prune : prune -> unit Or_error.t
