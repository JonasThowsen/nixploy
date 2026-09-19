open Core

(** Pure decision of what [prune --stale] removes.

    Stale means owned but no longer needed by the live deployment: containers in
    placements the route does not serve, owned secrets no retained container
    mounts, and owned image references beyond the images in use and the newest
    [keep]. When the live placement cannot be identified, containers are kept
    and the reason is reported. *)

type route =
  | Non_web
  | Missing
  | Routed of Deployment_plan.slot option
      (** [None] when the route targets an undeclared port. *)

type container = {
  name : string;
  placement : Deployment_plan.placement;
  running : bool;
  secret_names : string list option;
  image_id : string option;
}

type image = {
  image_id : string;
  references : string list;
  size_bytes : int64 option;
  containers : int;
}

type t = {
  remove_containers : container list;
  retain_containers : container list;
  remove_secrets : string list;
  remove_images : image list;
  retain_images : image list;
  notes : string list;  (** Why something that might look stale was kept. *)
}

val create :
  route:route ->
  containers:container list ->
  owned_secrets:string list ->
  images:image list ->
  keep:int ->
  t Or_error.t
(** [keep] must be at least 1. Images are ordered by their newest owned tag,
    which encodes the load time. *)

val image_tag_key : image -> string
(** The newest tag across the image's owned references (for ordering). *)
