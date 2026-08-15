open Async

val handle :
  applications:Nixploy.Managed_application.t list ->
  prune:
    (expected_project:Nixploy.Project_name.t ->
    working_directory:string ->
    target:Nixploy.Target_name.t ->
    Nixploy.Application.prune_result Deferred.Or_error.t) ->
  on_started:(application_key:string -> unit) ->
  Protocol.Prune.Query.t ->
  Protocol.Prune_result.t Deferred.Or_error.t
