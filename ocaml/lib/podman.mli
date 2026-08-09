open Async
open Core

type image
type candidate

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

val run_pre_start :
  connection:string ->
  target:Configuration.Target.t ->
  port:int ->
  image:image ->
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

module For_testing : sig
  val loaded_reference : string -> string Or_error.t
end
