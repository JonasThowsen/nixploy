open Async
open Core

type t
type commit
type source
type deployment
type deployment_preview
type started_deployment
type prune_result
type status
type scope

type prune_route_state = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type deployment_state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

type cancellation_result = Cancellation_requested | Already_requested
[@@deriving compare, equal, sexp]

type shutdown_transition = Shutdown_started | Already_shutting_down
[@@deriving compare, equal, sexp]

type log_line = { timestamp : string option; text : string }
[@@deriving compare, equal, sexp]

type log_snapshot = {
  container_name : string;
  revision : string option;
  observed_at_ms : int64;
  lines : log_line list;
  truncated : bool;
}
[@@deriving compare, equal, sexp]

type health = Healthy | Unhealthy | Unavailable of string
[@@deriving compare, equal, sexp]

type application_metrics = {
  application : string;
  container_name : string option;
  health : health;
  error : string option;
  cpu_percent : float option;
  memory_used_bytes : int64 option;
  memory_host_percent : float option;
  uptime_seconds : int64 option;
}

type target_metrics = {
  target : string;
  host : string;
  observed_at_ms : int64;
  error : string option;
  cpu_percent : float option;
  memory_used_bytes : int64 option;
  memory_total_bytes : int64 option;
  filesystem_used_bytes : int64 option;
  filesystem_total_bytes : int64 option;
  load_1 : float option;
  load_5 : float option;
  load_15 : float option;
  uptime_seconds : int64 option;
  applications : application_metrics list;
}

val create : store:Store.t -> unit -> t
(** Loads the host authority file when present; a linked caller cannot replace
    it with an empty allowlist. *)

val open_ :
  ?managed_applications:Managed_application.t list ->
  state_path:string ->
  unit ->
  t Deferred.Or_error.t

val begin_shutdown : t -> shutdown_transition
(** Atomically rejects new deploy and prune mutations. *)

val mutations_drained : t -> unit Deferred.t
(** Becomes determined after shutdown begins and every admitted deploy or prune
    mutation has unwound. *)

val local_scope :
  working_directory:string -> target:Target_name.t -> scope Or_error.t

val managed_scope : Managed_application.t -> scope Or_error.t

val preview_main_commit :
  t -> working_directory:string -> commit Deferred.Or_error.t

val preview_managed_deployment :
  t -> Managed_application.t -> deployment_preview Deferred.Or_error.t
(** Materializes and evaluates the exact main commit, validates root-managed
    production intent, and returns a process-local opaque receipt. *)

val deployment_preview_commit : deployment_preview -> commit
val deployment_preview_receipt : deployment_preview -> string
val deployment_preview_prune_receipt : deployment_preview -> string

val start_managed_deployment :
  t -> Managed_application.t -> started_deployment Deferred.Or_error.t
(** Deploys the configured managed checkout directly.  The allowlist and the
    evaluated target destination remain checked; no preview receipt authorizes
    this mutation. *)

val deploy_managed_deployment :
  t -> Managed_application.t -> deployment Deferred.Or_error.t

val start_local_deployment :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  started_deployment Deferred.Or_error.t
(** Snapshots the local tracked source once and runs the shared deployment
    engine.  Non-ignored untracked files are rejected during preparation. *)

val deploy_local_deployment :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  deployment Deferred.Or_error.t

val start_managed_preview :
  t ->
  Managed_application.t ->
  receipt:string ->
  started_deployment Deferred.Or_error.t

val deploy_managed_preview :
  t -> Managed_application.t -> receipt:string -> deployment Deferred.Or_error.t
(** Consumes the server-held receipt and revalidates its exact evaluated intent
    inside deployment before any remote or secret mutation. *)

val prune_managed_preview :
  t ->
  Managed_application.t ->
  receipt:string ->
  prune_result Deferred.Or_error.t
(** Always fails closed in Production V1. Durable prune admission, binding, and
    terminal review are deferred rather than allowing destructive cleanup under
    deployment-only operation tracking. *)

val resolve_commit :
  t -> working_directory:string -> revision:string -> commit Deferred.Or_error.t

val local_source : t -> working_directory:string -> source Deferred.Or_error.t
val immutable_source : commit -> source
val source_revision : source -> string
val source_subject : source -> string
val source_is_local : source -> bool
val started_deployment : started_deployment -> deployment
val started_deployment_id : started_deployment -> string

val await_started_deployment :
  started_deployment -> deployment Deferred.Or_error.t

val cancel_started_deployment :
  t -> started_deployment -> cancellation_result Deferred.Or_error.t

val start_non_production :
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  t ->
  working_directory:string ->
  source:source ->
  target:Target_name.t ->
  unit ->
  started_deployment Deferred.Or_error.t

val deploy_non_production :
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  t ->
  working_directory:string ->
  source:source ->
  target:Target_name.t ->
  unit ->
  deployment Deferred.Or_error.t
(** Explicit non-production mutation. The lower boundary claims a consumed
    operation capability, production-profile targets are rejected, and any
    installed host authority is loaded rather than caller-supplied. *)

val prune_non_production :
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  ?repository_identity:string ->
  t ->
  working_directory:string ->
  target:Target_name.t ->
  prune_result Deferred.Or_error.t
(** Always fails closed in Production V1, including library-only local calls. *)

val live_status : t -> scope:scope -> status Deferred.Or_error.t
val status_project : status -> Project_name.t
val status_target : status -> Configuration.Target.t
val status_resource_key : status -> Resource_key.t
val status_workloads : status -> Workload.t list

val deployment_history :
  t -> scope:scope -> limit:int -> deployment list Deferred.Or_error.t

val cancel_deployment :
  t ->
  scope:scope ->
  operation_id:string ->
  cancellation_result Deferred.Or_error.t
(** Cancellation is process-local. Persisted requested/running operations that
    are not registered in this process remain visible in history but cannot be
    signalled. Ownership is checked against both the scope and operation id
    before either the cancellation token or store is mutated. *)

val deployment_can_cancel : t -> scope:scope -> deployment -> bool

val application_logs :
  t -> Managed_application.t -> log_snapshot Deferred.Or_error.t

val application_metrics :
  t -> Managed_application.t -> target_metrics Deferred.t

val resource_state :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_state Deferred.Or_error.t

val resource_state_for_scope :
  t -> scope:scope -> resource_state Deferred.Or_error.t

val live_resource_state_for_scope : t -> scope:scope -> resource_state Deferred.t
(** Queries the remote Podman resource for this scope. Failed inspection is
    reported as [Unknown] and never overwrites the durable deployment state. *)

val prune_project : prune_result -> Project_name.t
val prune_target : prune_result -> Target_name.t
val prune_resource_key : prune_result -> Resource_key.t
val prune_containers_removed : prune_result -> int
val prune_secrets_removed : prune_result -> int
val prune_route_state : prune_result -> prune_route_state
val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64
val deployment_id : deployment -> string
val deployment_application_key : deployment -> string option
val deployment_state : deployment -> deployment_state
val deployment_stage : deployment -> string
val deployment_message : deployment -> string
val deployment_revision : deployment -> string option
val deployment_commit_subject : deployment -> string option
val deployment_commit_timestamp_ms : deployment -> int64 option
val deployment_container_name : deployment -> string option
val deployment_error : deployment -> string option
val deployment_requested_at_ms : deployment -> int64
val deployment_started_at_ms : deployment -> int64 option
val deployment_finished_at_ms : deployment -> int64 option
val deployment_cancel_requested_at_ms : deployment -> int64 option
val deployment_updated_at_ms : deployment -> int64
val deployment_state_name : deployment_state -> string

module For_testing : sig
  val create :
    ?status:(scope:scope -> status Deferred.Or_error.t) ->
    ?logs:(Managed_application.t -> log_snapshot Deferred.Or_error.t) ->
    ?metrics:(Managed_application.t -> target_metrics Deferred.t) ->
    ?deployment_history:
      (scope:scope -> limit:int -> deployment list Deferred.Or_error.t) ->
    ?managed_applications:Managed_application.t list ->
    store:Store.t ->
    preview_main:(working_directory:string -> commit Deferred.Or_error.t) ->
    find_commit:
      (working_directory:string ->
      revision:string ->
      commit Deferred.Or_error.t) ->
    deploy:
      (authorization:Operation_receipt.deploy ->
      prepared:Deployment.prepared option ->
      (deployment * deployment Deferred.Or_error.t) Deferred.Or_error.t) ->
    prune:
      (authorization:Operation_receipt.prune ->
      prepared:Prune.prepared option ->
      prune_result Deferred.Or_error.t) ->
    unit ->
    t

  val prune_result :
    project:Project_name.t ->
    target:Target_name.t ->
    resource_key:Resource_key.t ->
    containers_removed:int ->
    secrets_removed:int ->
    route:prune_route_state ->
    prune_result

  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t

  val local_source : working_directory:string -> commit -> source

  val deployment :
    ?application_key:string ->
    ?working_directory:string ->
    ?target:Target_name.t ->
    ?stage:string ->
    ?message:string ->
    ?revision:string ->
    ?commit_subject:string ->
    ?commit_timestamp_ms:int64 ->
    ?container_name:string ->
    ?error:string ->
    ?requested_at_ms:int64 ->
    ?started_at_ms:int64 ->
    ?finished_at_ms:int64 ->
    ?cancel_requested_at_ms:int64 ->
    ?updated_at_ms:int64 ->
    id:string ->
    state:deployment_state ->
    unit ->
    deployment
end
