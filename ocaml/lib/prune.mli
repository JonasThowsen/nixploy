open Async

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t

val prune :
  working_directory:string -> target:Target_name.t -> t Deferred.Or_error.t
(** Prune is cooperatively cancellable between and during bounded subprocesses.
    Resources already removed before cancellation are not recreated. *)

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
