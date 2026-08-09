open Async
open Core

type t
type route = Missing | Existing of { active_port : int }

val create :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  web:Configuration.Web.t ->
  t

val inspect : t -> route Deferred.Or_error.t

val switch :
  t -> previous:route -> candidate_port:int -> unit Deferred.Or_error.t

val restore : t -> previous:route -> unit Deferred.Or_error.t
val health_check : t -> port:int -> unit Deferred.Or_error.t

module For_testing : sig
  val upstream_port_of_json : string -> int Or_error.t
end
