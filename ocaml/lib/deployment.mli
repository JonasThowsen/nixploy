open Async

type stage =
  | Preparing_source
  | Evaluating
  | Connecting
  | Building
  | Planning
  | Preparing_candidate
  | Running_pre_start
  | Starting
  | Health_checking
  | Switching
  | Verifying
  | Retiring_previous
  | Succeeded
[@@deriving compare, equal, sexp]

type t
type prepared

val prepare :
  ?expected_project:Project_name.t ->
  ?expected_intent:Deployment_intent.t ->
  ?managed_application:Managed_application.t ->
  ?managed_applications:Managed_application.t list ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  unit ->
  prepared Deferred.Or_error.t
(** Materializes, evaluates, and authorizes the exact deployment without remote,
    resource-state, or deployment-history mutation. *)

val cleanup_prepared : prepared -> unit Deferred.t

val execute :
  ?record_stage:(stage -> string -> unit Deferred.Or_error.t) ->
  operation_id:string ->
  prepared ->
  t Deferred.Or_error.t

val deploy :
  ?record_stage:(stage -> string -> unit Deferred.Or_error.t) ->
  ?expected_project:Project_name.t ->
  ?expected_intent:Deployment_intent.t ->
  ?managed_application:Managed_application.t ->
  ?managed_applications:Managed_application.t list ->
  operation_id:string ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  unit ->
  t Deferred.Or_error.t

val operation_id : t -> string
val project : t -> Project_name.t
val target : t -> Target_name.t
val revision : t -> string
val image_id : t -> string
val container_name : t -> string
val container_id : t -> string
val placement : t -> Deployment_plan.placement
val warning : t -> string option
val stage_name : stage -> string
