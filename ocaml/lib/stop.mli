open Async

(** Takes a declared target offline so that it can be pruned: removes its owned
    Caddy route, then disables the restart policy of and stops each owned
    container. Nothing is deleted; [nixploy deploy] brings the target back. *)

type t

val stop_local :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  t Deferred.Or_error.t
(** Holds the target's mutation guard. The route is removed before any container
    stops, so traffic is never routed to a stopped slot. Progress is appended to
    the local prune_events table. *)

val project : t -> Project_name.t
val target : t -> Target_name.t
val resource_key : t -> Resource_key.t

val route_removed : t -> bool
(** Whether an owned route existed and was removed. *)

val containers : t -> string list
(** Owned containers now stopped with restart policy [no]. *)
