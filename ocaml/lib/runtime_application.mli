open Async

type t
type deployed_identity

val resolve :
  ?before_connection:(Configuration.Target.t -> unit Deferred.Or_error.t) ->
  ?commit:Source.commit ->
  ?operation_id:string ->
  Managed_application.t ->
  t Deferred.Or_error.t

val discover_identity :
  ?before_connection:(Configuration.Target.t -> unit Deferred.Or_error.t) ->
  commit:Source.commit ->
  Managed_application.t ->
  deployed_identity Deferred.Or_error.t
(** Uses current configuration only to locate a positively owned running
    resource. The returned identity must be resolved again with [resolve] before
    logs or metrics are read. *)

val deployed_revision : deployed_identity -> string
val deployed_operation_id : deployed_identity -> string
val application : t -> Managed_application.t
val target : t -> Configuration.Target.t
val connection : t -> string
val container : t -> Podman.runtime_container
val caddy : t -> Caddy.t option
val active_port : t -> int option
