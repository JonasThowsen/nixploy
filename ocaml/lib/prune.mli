open Async
open Core

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t
type prepared

val prepare :
  authorization:Operation_receipt.prune -> prepared Deferred.Or_error.t
(** Always fails before source preparation, Nix evaluation, or process effects.
    Production V1 does not implement the durable prune lifecycle. *)

val cleanup_prepared : prepared -> unit Deferred.t

val validate_bound :
  authorization:Operation_receipt.prune -> prepared -> unit Or_error.t
(** Always fails closed in Production V1. *)

val execute :
  authorization:Operation_receipt.prune -> prepared -> t Deferred.Or_error.t
(** Always fails before any remote effect in Production V1. *)

val prune :
  authorization:Operation_receipt.prune -> unit -> t Deferred.Or_error.t
(** Always fails before any preparation or remote effect in Production V1. *)

val project : t -> Project_name.t
val target : t -> Target_name.t
val resource_key : t -> Resource_key.t
val containers_removed : t -> int
val secrets_removed : t -> int
val route : t -> route

module For_testing : sig
  val prepared : prepared

  val result :
    project:Project_name.t ->
    target:Target_name.t ->
    resource_key:Resource_key.t ->
    containers_removed:int ->
    secrets_removed:int ->
    route:route ->
    t
end
