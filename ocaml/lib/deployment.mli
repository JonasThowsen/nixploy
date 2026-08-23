open Async

type stage =
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
  authorization:Operation_receipt.deploy -> prepared Deferred.Or_error.t
(** Claims one synchronously consumed deploy capability, then materializes,
    evaluates, and revalidates every bound application, source, target,
    destination, scope, and identity before mutation. *)

val cleanup_prepared : prepared -> unit Deferred.t

val execute :
  ?record_stage:(stage -> string -> unit Deferred.Or_error.t) ->
  authorization:Operation_receipt.deploy ->
  operation_id:string ->
  prepared ->
  t Deferred.Or_error.t

val deploy :
  ?record_stage:(stage -> string -> unit Deferred.Or_error.t) ->
  authorization:Operation_receipt.deploy ->
  operation_id:string ->
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
