open Async

type stage =
  | Preparing_source
  | Evaluating
  | Connecting
  | Building
  | Planning
  | Preparing_candidate
  | Running_pre_start
  | Starting
  | Health_checking
  | Switching
  | Verifying
  | Retiring_previous
  | Succeeded
[@@deriving compare, equal, sexp]

type t
type prepared

val prepare : request:Deployment_request.t -> prepared Deferred.Or_error.t
(** Materializes one selected source snapshot, evaluates its explicit target,
    and validates its project and repository-bound resource identity. *)

val cleanup_prepared : prepared -> unit Deferred.t

val execute :
  store:Store.t ->
  request:Deployment_request.t ->
  operation_id:string ->
  prepared ->
  t Deferred.Or_error.t

val deploy :
  store:Store.t ->
  request:Deployment_request.t ->
  operation_id:string ->
  unit ->
  t Deferred.Or_error.t

type dry_run_route = {
  domain : string;
  active_port : int option;
  candidate_slot : string;
  candidate_port : int;
  candidate_port_listener : bool option;
      (** Something already listens on the candidate port; [None] if unknown. *)
}

type dry_run = {
  project : Project_name.t;
  target : Target_name.t;
  resource_key : Resource_key.t;
  revision : string;
  image : string;
  route : dry_run_route option;
  replaced : string list;
  secrets : (string * [ `Create | `Replace ]) list;
  pre_start : string list list;
  guard : Mutation_guard.marker;
  blockers : string list;
  notes : string list;
}

val dry_run : request:Deployment_request.t -> dry_run Deferred.Or_error.t
(** A full dry run that changes nothing on the remote host: prepares the same
    source snapshot, evaluates the target, builds the image and decrypts secrets
    locally, then read-only checks SSH, Podman, read-only bind sources, secret
    ownership, the Caddy route and candidate slot, the mutation marker and
    reboot readiness. Takes no mutation guard and records no history. [blockers]
    are conditions under which a real deploy would fail now. *)

val operation_id : t -> string
val project : t -> Project_name.t
val target : t -> Target_name.t
val revision : t -> string
val image_id : t -> string
val container_name : t -> string
val container_id : t -> string
val placement : t -> Deployment_plan.placement
val warning : t -> string option
val stage_name : stage -> string
