open Async
open Core

(** Every nixploy resource on one target's host, grouped by resource key and
    classified against the local flake. Read-only. *)

type classification =
  | Current  (** the selected target's live resource identity *)
  | Declared
      (** this project and a target the flake declares (possibly an older
          identity of it) *)
  | Orphaned  (** this project, but the flake no longer declares the target *)
  | Other_project
  | Unattributed  (** no ownership labels identify the project or target *)
[@@deriving compare, equal, sexp]

type container = {
  id : string;
  name : string;
  state : string option;
  status : string option;
}

type secret = { id : string; name : string }

type group = {
  resource_key : string;
  project : string option;
  target : string option;
  repository : string option;
  classification : classification;
  containers : container list;
  secrets : secret list;
  images : Podman.owned_image list;
  route : bool;
  marker : string option;
  problems : string list;
      (** Contradictory labels; orphan cleanup refuses such groups. *)
}

type t

val load :
  working_directory:string -> target:Target_name.t -> t Deferred.Or_error.t

val host : t -> Configuration.Target.t

val connection : t -> string
(** The Podman connection used for the observation (same host and account). *)

val project : t -> Project_name.t
val groups : t -> group list

val unattributed_images : t -> Podman.owned_image list
(** [localhost/nixploy/] images whose repository matches no known key. *)

val legacy_secrets : t -> string list
(** [nixploy-*] secrets without nixploy labels; never removed automatically. *)

val unattributed_markers : t -> string list

val errors : t -> (string * Error.t) list
(** Sections that could not be read (for example the Caddy route listing). *)

val find_group : t -> string -> group option

module For_testing : sig
  val build :
    project:Project_name.t ->
    declared:Target_name.t list ->
    current_key:Resource_key.t ->
    containers:Podman.Labelled.t list ->
    secrets:Podman.Labelled.t list ->
    images:Podman.owned_image list ->
    route_keys:string list ->
    markers:string list ->
    group list * Podman.owned_image list * string list * string list
  (** Returns groups, unattributed images, legacy secrets and unattributed
      markers. *)
end
