open Async

val deployment :
  now_ms:int64 ->
  can_cancel:bool ->
  Nixploy.Application.deployment ->
  Protocol.Deployment.t

val application :
  Nixploy.Managed_application.t ->
  resource_state:Nixploy.Application.resource_state ->
  deployment:Protocol.Deployment.t option ->
  Protocol.Application.t

val recent_deployment :
  application:Nixploy.Managed_application.t ->
  deployment:Protocol.Deployment.t ->
  Protocol.Recent_deployment.t

val cancellation : Nixploy.Application.cancellation_result -> unit

val log_snapshot :
  application:string ->
  Nixploy.Application.log_snapshot ->
  Protocol.Log_snapshot.t

val target_metrics :
  Nixploy.Application.target_metrics -> Protocol.Target_metrics.t

val max_concurrent_metrics : int

val collect_metrics :
  Nixploy.Managed_application.t list ->
  observe:
    (Nixploy.Managed_application.t ->
    Nixploy.Application.target_metrics Deferred.t) ->
  Protocol.Target_metrics.t list Deferred.t
