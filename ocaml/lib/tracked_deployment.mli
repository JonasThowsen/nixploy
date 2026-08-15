open Async

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  store:Store.t ->
  working_directory:string ->
  commit:Source.commit ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t

val deploy_within_lease :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?application_key:string ->
  ?expected_project:Project_name.t ->
  store:Store.t ->
  working_directory:string ->
  commit:Source.commit ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t
(** Advanced entry point for application orchestration that already holds the
    target lease. [working_directory] must be canonical. *)
