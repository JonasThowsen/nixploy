open Async
open Core

type t
type commit = Source.commit
type source = Source.selection
type deployment
type started_deployment
type prune_result
type status = Status.t
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

val create : store:Store.t -> unit -> t
val open_ : state_path:string -> unit -> t Deferred.Or_error.t

val begin_shutdown : t -> shutdown_transition
(** Cancels process-owned deployments and rejects new tracked mutations. *)

val mutations_drained : t -> unit Deferred.t
(** Waits for current process-owned mutations to unwind, without requiring
    shutdown. *)

val local_scope :
  working_directory:string -> target:Target_name.t -> scope Or_error.t

val start_local_deployment :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  started_deployment Deferred.Or_error.t
(** Prepares one tracked source snapshot for evaluation, build, and secrets. *)

val deploy_local_deployment :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  deployment Deferred.Or_error.t

val immutable_source : commit -> source

val start_direct_deployment :
  ?expected_project:Project_name.t ->
  t ->
  working_directory:string ->
  source:source ->
  target:Target_name.t ->
  unit ->
  started_deployment Deferred.Or_error.t

val deploy_direct_deployment :
  ?expected_project:Project_name.t ->
  t ->
  working_directory:string ->
  source:source ->
  target:Target_name.t ->
  unit ->
  deployment Deferred.Or_error.t

val started_deployment : started_deployment -> deployment
val started_deployment_id : started_deployment -> string

val await_started_deployment :
  started_deployment -> deployment Deferred.Or_error.t

val cancel_started_deployment :
  t -> started_deployment -> cancellation_result Deferred.Or_error.t
(** Cancels only the opaque handle registered in this CLI process. *)

val cancel_deployment :
  t ->
  scope:scope ->
  operation_id:string ->
  cancellation_result Deferred.Or_error.t

val deployment_can_cancel : t -> scope:scope -> deployment -> bool

val prune_local :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  confirmed:bool ->
  prune_result Deferred.Or_error.t
(** Explicit scoped cleanup using the same durable remote guard as deploy/run.
*)

val live_status : t -> scope:scope -> status Deferred.Or_error.t

val host_readiness :
  working_directory:string ->
  target:Target_name.t ->
  Host_readiness.t Deferred.Or_error.t
(** Read-only checks that owned workloads and routes survive a host reboot. *)

val status_project : status -> Project_name.t
val status_target : status -> Configuration.Target.t
val status_resource_key : status -> Resource_key.t
val status_workloads : status -> Workload.t list

val deployment_history :
  t -> scope:scope -> limit:int -> deployment list Deferred.Or_error.t
(** Process observer reads local history without re-evaluating the flake. *)

val local_history :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  limit:int ->
  deployment list Deferred.Or_error.t

val local_logs :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  log_snapshot Deferred.Or_error.t

val resource_state_for_scope :
  t -> scope:scope -> resource_state Deferred.Or_error.t

val runbook :
  working_directory:string ->
  target:Target_name.t ->
  Configuration.Runbook_command.t list Deferred.Or_error.t
(** Stateless local listing; never opens history or contacts the target. *)

val run :
  on_selection:(Runbook.selection -> unit Deferred.t) ->
  working_directory:string ->
  target:Target_name.t ->
  name:string ->
  Runbook.outcome Deferred.Or_error.t
(** Holds the remote guard across selection and exec, without replay or output
    retention. Uncertain outcomes retain the marker and preserve child exit
    code. *)

val prune_project : prune_result -> Project_name.t
val prune_target : prune_result -> Target_name.t
val prune_resource_key : prune_result -> Resource_key.t
val prune_containers_removed : prune_result -> int
val prune_secrets_removed : prune_result -> int
val prune_secrets_retained : prune_result -> int
val prune_route_state : prune_result -> prune_route_state
val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64
val deployment_id : deployment -> string
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
    ?deployment_history:
      (scope:scope -> limit:int -> deployment list Deferred.Or_error.t) ->
    ?local_source:(working_directory:string -> source Deferred.Or_error.t) ->
    store:Store.t ->
    deploy:
      (request:Deployment_request.t ->
      prepared:Deployment.prepared option ->
      (deployment * deployment Deferred.Or_error.t) Deferred.Or_error.t) ->
    unit ->
    t

  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t

  val local_source : working_directory:string -> commit -> source

  val deployment :
    ?legacy_application_key:string ->
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
