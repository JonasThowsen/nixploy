open Async

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t
type prepared

val prepare_managed :
  application:Managed_application.t ->
  intent:Deployment_intent.t ->
  commit:Source.commit ->
  prepared Deferred.Or_error.t
(** Revalidates the exact managed application, protected source evidence,
    immutable configuration, destination, and canonical resource key without
    remote or local state mutation. *)

val cleanup_prepared : prepared -> unit Deferred.t
val execute : prepared -> t Deferred.Or_error.t

val prune :
  ?expected_project:Project_name.t ->
  ?repository_identity:string ->
  working_directory:string ->
  target:Target_name.t ->
  unit ->
  t Deferred.Or_error.t
(** Compatibility entry point for non-managed tests and library consumers. The
    packaged CLI does not expose local mutation. Managed RPC prune uses
    [prepare_managed] and [execute]. *)

val project : t -> Project_name.t
val target : t -> Target_name.t
val resource_key : t -> Resource_key.t
val containers_removed : t -> int
val secrets_removed : t -> int
val route : t -> route

module For_testing : sig
  val result :
    project:Project_name.t ->
    target:Target_name.t ->
    resource_key:Resource_key.t ->
    containers_removed:int ->
    secrets_removed:int ->
    route:route ->
    t
end
