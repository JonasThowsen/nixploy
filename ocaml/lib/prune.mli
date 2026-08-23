open Async

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t
type prepared

val prepare :
  authorization:Operation_receipt.prune -> prepared Deferred.Or_error.t
(** Claims one synchronously consumed prune capability and revalidates its exact
    managed or non-production source, destination, and resource identity before
    mutation. *)

val cleanup_prepared : prepared -> unit Deferred.t

val execute :
  authorization:Operation_receipt.prune -> prepared -> t Deferred.Or_error.t

val prune :
  ?on_authorized:(unit -> unit Deferred.Or_error.t) ->
  authorization:Operation_receipt.prune ->
  unit ->
  t Deferred.Or_error.t

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
