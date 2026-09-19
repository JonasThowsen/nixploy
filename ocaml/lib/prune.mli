open Async

(** [Kept] means the mode never touches the route (stale cleanup). A dry run
    reports [Removed] for a route it would delete. *)
type route = Not_configured | Missing | Removed | Kept
[@@deriving compare, equal, sexp]

type mode =
  | Everything
      (** Owned containers, owned secrets, owned image references and the
          configured route. *)
  | Stale of { keep : int }
      (** Only resources the live deployment does not use; see {!Stale_plan}. *)
[@@deriving compare, equal, sexp]

type t

val prune_local :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  confirmed:bool ->
  mode:mode ->
  dry_run:bool ->
  t Deferred.Or_error.t
(** Removes exactly owned resources chosen by [mode]. Unlabelled secrets, images
    outside the owned repository, volumes, and host data are retained. All
    ownership checks precede removal; partial/unknown results retain the remote
    mutation guard and append durable progress in the local prune_events table.
    A dry run performs the same read-only observation and planning without
    taking the guard, recording events, or requiring confirmation. *)

val project : t -> Project_name.t
val target : t -> Target_name.t
val resource_key : t -> Resource_key.t
val mode : t -> mode
val dry_run : t -> bool

val containers : t -> string list
(** Container names removed (or, in a dry run, that would be removed). *)

val secrets : t -> string list
val image_references : t -> string list

val image_bytes : t -> int64
(** Size of images whose every owned reference is removed. Shared images survive
    under another reference, so this bounds the space freed. *)

val containers_removed : t -> int
val secrets_removed : t -> int
val secrets_retained : t -> int
val route : t -> route

val notes : t -> string list
(** Why resources that might look removable were kept. *)
