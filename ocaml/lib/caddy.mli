open Async
open Core

type t
type deletion
type route = Missing | Existing of { active_port : int; domain : string }

val create :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  web:Configuration.Web.t ->
  t

val inspect : ?ignore_termination:bool -> t -> route Deferred.Or_error.t

val switch :
  t -> previous:route -> candidate_port:int -> unit Deferred.Or_error.t

val restore : t -> previous:route -> unit Deferred.Or_error.t

val preflight_delete : t -> deletion Deferred.Or_error.t
(** Verifies that the exact managed route is absent or has the expected route,
    proxy, domain, and upstream structure without mutating Caddy. *)

val deletion_route : deletion -> route
(** The route observed by {!preflight_delete}. *)

val execute_delete : deletion -> bool Deferred.Or_error.t
val health_check : t -> port:int -> unit Deferred.Or_error.t
val observe_health : t -> port:int -> bool Deferred.Or_error.t

(** {2 Key-addressed access}

    For routes whose target is no longer declared, identified only by the
    resource key embedded in the route and proxy IDs. The route structure is
    still validated before deletion. *)

val inspect_key :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  route Deferred.Or_error.t
(** [target] supplies only the SSH host. *)

val delete_key :
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  bool Deferred.Or_error.t

val list_route_keys :
  target:Configuration.Target.t -> string list Deferred.Or_error.t
(** Resource keys of every nixploy route in Caddy's [nixploy] server. *)

module For_testing : sig
  val upstream_port_of_json : string -> int Or_error.t
end
