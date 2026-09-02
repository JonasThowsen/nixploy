open Async

val preview :
  applications:Nixploy.Managed_application.t list ->
  application:Nixploy.Application.t ->
  Protocol.Preview_deployment.Query.t ->
  Protocol.Deployment_preview.t Deferred.Or_error.t

val start :
  applications:Nixploy.Managed_application.t list ->
  application:Nixploy.Application.t ->
  Protocol.Deploy.Query.t ->
  string Deferred.Or_error.t
