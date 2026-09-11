open Async

type t

val resolve_running :
  project:Project_name.t ->
  target:Configuration.Target.t ->
  resource_key:Resource_key.t ->
  repository_identity:string ->
  t Deferred.Or_error.t
(** Resolves only the exact owned running non-web placement or the owned Caddy
    active slot. Hold the target guard through resolution and subsequent exec.
*)

val connection : t -> string
(** Strict existing Podman SSH connection for the selected target. *)

val container : t -> Podman.runtime_container
(** Positively verified immutable container identity. *)
