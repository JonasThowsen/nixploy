open Async

(** Removes the resources of one resource key whose target the local flake no
    longer declares (a renamed or deleted target, or another project's leftovers
    on the same host). *)

type t

val prune :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_key:string ->
  confirmed:bool ->
  dry_run:bool ->
  t Deferred.Or_error.t
(** [target] selects the host (its SSH account and Podman connection) only.
    Refuses keys that are current or declared by the local flake, that lack
    project/target labels, or whose labels conflict. A real run takes the
    mutation guard of the orphan's own project/target, re-observes the host, and
    removes by immutable ID only resources whose complete ownership labels still
    match: containers, owned secrets, owned image references, and the key's
    Caddy route. *)

val resource_key : t -> string
val project : t -> string
val target : t -> string
val dry_run : t -> bool
val containers : t -> string list
val secrets : t -> string list
val image_references : t -> string list
val image_bytes : t -> int64

type stopped

val stop :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_key:string ->
  stopped Deferred.Or_error.t
(** Takes an orphaned key offline under its own guard: removes its Caddy route,
    then disables the restart policy of and stops each container whose ownership
    labels still match. Same refusals as {!prune}. *)

val stopped_key : stopped -> string
val stopped_project : stopped -> string
val stopped_target : stopped -> string
val stopped_route_removed : stopped -> bool
val stopped_containers : stopped -> string list
