open Async

val handle :
  applications:Nixploy.Managed_application.t list ->
  application:Nixploy.Application.t ->
  Protocol.Admit_managed_deployment.Query.t ->
  Protocol.Admit_managed_deployment.Response.t Deferred.Or_error.t
(** Validates immutable request syntax and configured authority, then delegates
    exact-revision custody verification to the VPS Application boundary. It
    fails closed before a deployment effect until broker-backed admission is
    configured. *)
