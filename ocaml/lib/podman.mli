open Async
open Core

type image
type candidate
type secret_mount
type runtime_container
type prepared_secret_prune

val preflight_prune_owned_secrets :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  prepared_secret_prune Deferred.Or_error.t
(** Read-only, bounded discovery of the exact resource prefix. Contradictory,
    partial, foreign, duplicate or malformed metadata fails closed. Secrets with
    no Nixploy labels are retained, never inferred to be owned by their names.
*)

val prepared_secret_prune_counts : prepared_secret_prune -> int * int
(** Eligible and retained legacy secret counts, respectively. *)

val restrict_prepared_secret_prune :
  prepared_secret_prune -> remove:(string -> bool) -> prepared_secret_prune
(** Keeps only eligible owned secrets whose name satisfies [remove]. Retained
    and legacy secrets are still revalidated on execution. *)

val prepared_secret_prune_names : prepared_secret_prune -> string list
(** Names of the eligible owned secrets. *)

val execute_prepared_secret_prune :
  prepared_secret_prune -> (int * int) Deferred.Or_error.t
(** Revalidates the complete snapshot before deleting eligible immutable IDs.
    Returns removed and retained counts. Never requests secret data. The caller
    must hold the target mutation guard from preflight through execution. *)

type log_line = { timestamp : string option; text : string }
type log_snapshot = { lines : log_line list; truncated : bool }

type runtime_stats = {
  cpu_percent : float option;
  memory_used_bytes : int64;
  memory_limit_bytes : int64 option;
  pids : int option;
}

type storage_usage = {
  images_bytes : int64;
  images_reclaimable_bytes : int64;
  containers_bytes : int64;
  volumes_bytes : int64;
}

type host_info = {
  cpus : int option;
  memory_total_bytes : int64 option;
  memory_free_bytes : int64 option;
  graph_root : string option;
}

module Secret_status : sig
  type t = { name : string; owned : bool }
end

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
  resource_key:Resource_key.t ->
  source:Source.t ->
  image_output:string ->
  unit ->
  image Deferred.Or_error.t
(** Loads the image and tags it with an {!Owned_image.reference}, which the
    returned image uses. The archive's own tag is removed afterwards. *)

val prepare_candidate :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  unit Deferred.Or_error.t

type placement_state = {
  container : candidate;
  running : bool;
  secret_names : string list option;
      (** Remote secret names from the container's [io.nixploy.secrets] label;
          [None] for containers deployed before the label existed. *)
  image_id : string option;
}

val observe_owned_placement :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  placement:Deployment_plan.placement ->
  placement_state option Deferred.Or_error.t
(** Like {!find_owned_placement}, with the state needed to plan cleanup. *)

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
  project:Project_name.t ->
  target:Configuration.Target.t ->
  repository_identity:string ->
  resource_key:Resource_key.t ->
  secrets:Secrets.t list ->
  secret_mount list Deferred.Or_error.t
(** Creates fully ownership-labelled secrets using stdin. All replacements are
    preflighted before mutation; unlabelled legacy secrets require explicit
    operator migration. Owned replacements are removed by immutable ID, and a
    removal failure stops creation. The caller must hold the target guard. *)

val run_pre_start :
  connection:string ->
  target:Configuration.Target.t ->
  placement:Deployment_plan.placement ->
  source:Source.t ->
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

val exec_runbook :
  connection:string ->
  container:runtime_container ->
  command:Configuration.Runbook_command.t ->
  Core_unix.Exit_or_signal.t Deferred.Or_error.t
(** Executes literal argv once by inspected immutable ID. The caller must hold
    the daemonless target guard continuously from resolution until completion.
*)

val read_stats :
  connection:string ->
  container:runtime_container ->
  runtime_stats Deferred.Or_error.t

type owned_image = {
  image_id : string;
  references : string list;  (** only references in the owned repository *)
  size_bytes : int64 option;
  containers : int;  (** containers of any owner using the image *)
}

val list_owned_images :
  connection:string ->
  resource_key:Resource_key.t ->
  owned_image list Deferred.Or_error.t
(** Images with at least one reference in exactly this resource's
    {!Owned_image.repository}. *)

val remove_owned_image_reference :
  connection:string ->
  resource_key:Resource_key.t ->
  string ->
  unit Deferred.Or_error.t
(** Removes one owned reference. Podman deletes the image only when no other
    reference remains, so an image shared with another target survives. Refuses
    references outside the owned repository. *)

(** {2 Host-wide inventory}

    Every nixploy resource reachable through one connection, regardless of
    project or target. Used to find resources whose target is no longer
    declared. *)

module Labelled : sig
  type t = {
    id : string;
    name : string;
    state : string option;
    status : string option;
    labels : (string * string) list;
  }
end

val list_managed_containers :
  connection:string -> Labelled.t list Deferred.Or_error.t
(** Containers labelled [io.nixploy.managed=true], in any state. *)

val list_nixploy_secrets :
  connection:string -> Labelled.t list Deferred.Or_error.t
(** Secrets named [nixploy-*] with their labels (possibly none). Never requests
    secret data. *)

val list_nixploy_images :
  connection:string -> owned_image list Deferred.Or_error.t
(** Images with at least one [localhost/nixploy/] reference; [references] holds
    only those. *)

val stop_candidate :
  connection:string -> candidate:candidate -> unit Deferred.Or_error.t
(** Sets the restart policy to [no], then stops the container by immutable ID.
    Idempotent for an already stopped container. The caller must hold the target
    guard. *)

val stop_labelled_container :
  connection:string ->
  id:string ->
  expected:(string * string) list ->
  unit Deferred.Or_error.t
(** {!stop_candidate} for a listed ID, after re-verifying every expected label.
*)

val remove_labelled_container :
  connection:string ->
  id:string ->
  expected:(string * string) list ->
  unit Deferred.Or_error.t
(** Re-inspects the immutable ID and removes it only if every expected label
    still matches. *)

val remove_labelled_secret :
  connection:string ->
  id:string ->
  name:string ->
  ownership:(string * string) list ->
  unit Deferred.Or_error.t
(** Removes the secret only when it carries the complete [ownership] labels;
    partial or unlabelled secrets are refused. *)

(** {2 Read-only status queries}

    These never mutate resources and never request secret values. *)

val read_named_stats :
  connection:string ->
  names:string list ->
  (string * runtime_stats) list Deferred.Or_error.t

val read_restart_policies :
  connection:string ->
  names:string list ->
  (string * string option) list Deferred.Or_error.t

val read_storage_usage : connection:string -> storage_usage Deferred.Or_error.t
(** Host-wide Podman storage totals, not only this target's resources. *)

val read_host_info : connection:string -> host_info Deferred.Or_error.t

val read_secret_statuses :
  connection:string ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  Secret_status.t list Deferred.Or_error.t
(** Classifies the resource's secrets in one batched inspect. Partial or
    contradictory ownership fails like prune preflight. *)

module For_testing : sig
  val runbook_argv :
    connection:string ->
    container_id:string ->
    command:Configuration.Runbook_command.t ->
    string list

  val pre_start_argvs :
    connection:string ->
    run:Configuration.Run.t ->
    port:int option ->
    revision:string option ->
    secret_args:string list ->
    image_reference:string ->
    string list list

  val runtime_argv :
    connection:string ->
    name:string ->
    run:Configuration.Run.t ->
    port:int option ->
    revision:string option ->
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
  val parse_named_stats : string -> (string * runtime_stats) list Or_error.t

  val parse_restart_policies :
    string -> (string * string option) list Or_error.t

  val parse_storage_usage : string -> storage_usage Or_error.t
  val parse_host_info : string -> host_info Or_error.t

  val owned_images_of_listing :
    string -> repository:string -> owned_image list Or_error.t

  val managed_containers_of_json : string -> Labelled.t list Or_error.t
  val labelled_secrets_of_inspect : string -> Labelled.t list Or_error.t
  val nixploy_images_of_listing : string -> owned_image list Or_error.t
  val bound_logs : string -> log_snapshot
  val secret_names_of_output : string -> string list Or_error.t

  val owned_candidate_collision :
    string ->
    project:Project_name.t ->
    target:Configuration.Target.t ->
    resource_key:Resource_key.t ->
    bool Or_error.t
end
