open Async

val handle :
  applications:Nixploy.Managed_application.t list ->
  cancel:
    (application:Nixploy.Managed_application.t ->
    operation_id:string ->
    unit Deferred.Or_error.t) ->
  Protocol.Cancel_deployment_v1.Query.t ->
  unit Deferred.Or_error.t
