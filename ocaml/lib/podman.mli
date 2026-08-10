open Async
open Core

type image
type candidate
type secret_mount
type runtime_container
type log_line = { timestamp : string option; text : string }
type log_snapshot = { lines : log_line list; truncated : bool }
type runtime_stats = { cpu_percent : float option; memory_used_bytes : int64 }

val select_resource_key :
  project:Project_name.t ->
  target:Configuration.Target.t ->
  canonical:Resource_key.t ->
  legacy:Resource_key.t ->
  Resource_key.t Deferred.Or_error.t

val ensure_connection :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  string Deferred.Or_error.t

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
  slot:Deployment_plan.slot ->
  unit Deferred.Or_error.t

val find_owned_slot :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
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
  port:int ->
  image:image ->
  secrets:Secrets.t list ->
  secret_mounts:secret_mount list ->
  unit Deferred.Or_error.t

val start_candidate :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  slot:Deployment_plan.slot ->
  port:int ->
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
  source:Source.t ->
  configuration_digest:string ->
  operation_id:string ->
  image:image ->
  candidate:candidate ->
  unit Deferred.Or_error.t

val remove_candidate :
  connection:string -> candidate:candidate -> unit Deferred.Or_error.t

val image_reference : image -> string
val image_id : image -> string
val candidate_name : candidate -> string
val candidate_id : candidate -> string
val runtime_container_name : runtime_container -> string
val runtime_container_id : runtime_container -> string
val runtime_container_revision : runtime_container -> string option
val runtime_container_operation_id : runtime_container -> string option
val runtime_container_started_at : runtime_container -> string option

val find_running_slot :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
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
  val loaded_reference : string -> string Or_error.t
  val resource_keys_of_containers : string -> string list Or_error.t
  val parse_stats : string -> runtime_stats Or_error.t
  val bound_logs : string -> log_snapshot
end
