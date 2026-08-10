open Async

type t

val resolve :
  ?commit:Source.commit ->
  ?operation_id:string ->
  Managed_application.t ->
  t Deferred.Or_error.t

val application : t -> Managed_application.t
val target : t -> Configuration.Target.t
val connection : t -> string
val container : t -> Podman.runtime_container
val caddy : t -> Caddy.t
val active_port : t -> int
