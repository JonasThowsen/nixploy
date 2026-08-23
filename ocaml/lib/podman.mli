open Async
open Core

type image
type candidate
type secret_mount
type runtime_container
type prepared_prune
type log_line = { timestamp : string option; text : string }
type log_snapshot = { lines : log_line list; truncated : bool }
type runtime_stats = { cpu_percent : float option; memory_used_bytes : int64 }

val select_resource_key :
  project:Project_name.t ->
  target:Configuration.Target.t ->
  repository_identity:string ->
  candidates:Resource_key.t list ->
  Resource_key.t Deferred.Or_error.t
(** Selects the canonical key or safely adopts one recognized prior identity.
    Contradictory, foreign, and ambiguous ownership fails closed. *)

val ensure_connection :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  string Deferred.Or_error.t

val preflight_read_only_bind_sources :
  target:Configuration.Target.t -> unit Deferred.Or_error.t
(** Verifies every configured source exists on the remote host before any
    deployment container is run. Missing or inaccessible sources fail closed;
    nixploy never creates them. *)

val build_and_load :
  connection:string ->
  source:Source.t ->
  image_output:string ->
  image Deferred.Or_error.t

val prepare_candidate :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  unit Deferred.Or_error.t

val find_owned_placement :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  candidate option Deferred.Or_error.t
(** Inspects one exact placement without mutation and returns only a container
    with complete target and repository ownership. *)

val find_owned_slot :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  slot:Deployment_plan.slot ->
  candidate option Deferred.Or_error.t

val install_secrets :
  connection:string ->
  resource_key:Resource_key.t ->
  secrets:Secrets.t list ->
  secret_mount list Deferred.Or_error.t

val run_pre_start :
  connection:string ->
  target:Configuration.Target.t ->
  placement:Deployment_plan.placement ->
  image:image ->
  secrets:Secrets.t list ->
  secret_mounts:secret_mount list ->
  unit Deferred.Or_error.t

val start_candidate :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  source:Source.t ->
  configuration_digest:string ->
  operation_id:string ->
  deployed_at:string ->
  image:image ->
  secrets:Secrets.t list ->
  secret_mounts:secret_mount list ->
  candidate Deferred.Or_error.t

val verify_candidate :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  source:Source.t ->
  configuration_digest:string ->
  operation_id:string ->
  image:image ->
  candidate:candidate ->
  unit Deferred.Or_error.t

val remove_candidate :
  connection:string -> candidate:candidate -> unit Deferred.Or_error.t

val preflight_prune_owned_resources :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  prepared_prune Deferred.Or_error.t
(** Verifies every exact managed container name has complete target and
    repository ownership, then selects only scoped secrets without mutating
    remote resources. *)

val execute_prepared_prune : prepared_prune -> (int * int) Deferred.Or_error.t
(** Executes only the opaque, previously verified prune selection. *)

val image_reference : image -> string
val image_id : image -> string
val candidate_name : candidate -> string
val candidate_id : candidate -> string
val runtime_container_name : runtime_container -> string
val runtime_container_id : runtime_container -> string
val runtime_container_revision : runtime_container -> string option
val runtime_container_operation_id : runtime_container -> string option
val runtime_container_started_at : runtime_container -> string option

val find_running_placement :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  runtime_container Deferred.Or_error.t
(** Inspects the exact container name for the deployment placement and verifies
    its running state, name, and complete managed ownership labels. *)

val find_running_slot :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  slot:Deployment_plan.slot ->
  runtime_container Deferred.Or_error.t

val read_logs :
  connection:string ->
  container:runtime_container ->
  log_snapshot Deferred.Or_error.t

val read_stats :
  connection:string ->
  container:runtime_container ->
  runtime_stats Deferred.Or_error.t

module For_testing : sig
  val pre_start_argvs :
    connection:string ->
    run:Configuration.Run.t ->
    port:int option ->
    secret_args:string list ->
    image_reference:string ->
    string list list

  val runtime_argv :
    connection:string ->
    name:string ->
    run:Configuration.Run.t ->
    port:int option ->
    secret_args:string list ->
    labels:(string * string) list ->
    image_reference:string ->
    string list

  val loaded_reference : string -> string Or_error.t

  val resource_keys_of_containers :
    string ->
    project:Project_name.t ->
    target:Target_name.t ->
    string list Or_error.t

  val parse_stats : string -> runtime_stats Or_error.t
  val bound_logs : string -> log_snapshot
  val secret_names_of_output : string -> string list Or_error.t

  val owned_candidate_collision :
    string ->
    project:Project_name.t ->
    target:Configuration.Target.t ->
    resource_key:Resource_key.t ->
    bool Or_error.t
end
