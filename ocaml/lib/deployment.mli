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

val deploy :
  ?on_stage:(stage -> string -> unit Deferred.t) ->
  operation_id:string ->
  working_directory:string ->
  commit:Source.commit ->
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
