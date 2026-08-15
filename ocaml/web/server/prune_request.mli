open Async

val handle :
  applications:Nixploy.Managed_application.t list ->
  prune:
    (application:Nixploy.Managed_application.t ->
    Nixploy.Application.prune_result Deferred.Or_error.t) ->
  Protocol.Prune.Query.t ->
  Protocol.Prune_result.t Deferred.Or_error.t
