open Async

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t

val prune_local :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  confirmed:bool ->
  t Deferred.Or_error.t
(** Removes only exactly owned containers and the configured owned Caddy route.
    Secrets, images, volumes, and host data are retained. All ownership checks
    precede removal; partial/unknown results retain the remote mutation guard
    and append durable progress in the local prune_events table. *)

val project : t -> Project_name.t
val target : t -> Target_name.t
val resource_key : t -> Resource_key.t
val containers_removed : t -> int
val secrets_removed : t -> int
val route : t -> route
