open Async

val handle :
  applications:Nixploy.Managed_application.t list ->
  Protocol.Admit_managed_deployment.Query.t ->
  Protocol.Admit_managed_deployment.Response.t Deferred.Or_error.t
(** Validates immutable request syntax and its configured managed authority,
    then fails closed before source, store, deployment, or target-lease effects.
*)
