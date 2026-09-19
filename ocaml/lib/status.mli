open Async
open Core

type role =
  | Single  (** the non-web target's application container *)
  | Active  (** the web slot the owned Caddy route serves *)
  | Unrouted  (** an owned web container that no owned route serves *)
[@@deriving compare, equal, sexp]

type container = {
  workload : Workload.t;
  role : role;
  restart_policy : string option;
  stats : Podman.runtime_stats option;
}

type route =
  | Not_web
  | Missing
  | Routed of {
      domain : string;
      port : int;
      slot : Deployment_plan.slot option;
          (** [None] when the port is not a declared slot port. *)
    }

type disk = { total_bytes : int64; available_bytes : int64; path : string }
type t

val load :
  working_directory:string -> target:Target_name.t -> t Deferred.Or_error.t
(** Ownership-verified container listing plus best-effort runtime details.
    Failure to verify container ownership fails the whole status; failure of a
    supplementary query (stats, route, secrets, storage, guard, readiness) is
    reported in that section instead. Read-only: never takes the mutation guard.
*)

val project : t -> Project_name.t
val target : t -> Configuration.Target.t
val resource_key : t -> Resource_key.t
val workloads : t -> Workload.t list
val containers : t -> container list
val route : t -> route Or_error.t
val secrets : t -> Podman.Secret_status.t list Or_error.t

val images : t -> Podman.owned_image list Or_error.t
(** Images in this target's owned repository. *)

val storage : t -> Podman.storage_usage Or_error.t
val host : t -> Podman.host_info Or_error.t
val disk : t -> disk Or_error.t
val guard : t -> Mutation_guard.marker Or_error.t
val readiness : t -> Host_readiness.t

val runtime_error : t -> Error.t option
(** Set when per-container runtime details (restart policy or stats) could not
    be read. *)

val human_bytes : int64 -> string
(** Binary units, e.g. ["1.5 GiB"]. *)

val issues : t -> string list
(** Operator-facing problems derived from the observed state, most severe first.
    Empty means nothing needs attention. *)

module For_testing : sig
  val create :
    project:Project_name.t ->
    target:Configuration.Target.t ->
    resource_key:Resource_key.t ->
    containers:container list ->
    route:route Or_error.t ->
    secrets:Podman.Secret_status.t list Or_error.t ->
    disk:disk Or_error.t ->
    guard:Mutation_guard.marker Or_error.t ->
    readiness:Host_readiness.t ->
    t

  val parse_disk : path:string -> string -> disk Or_error.t
end
