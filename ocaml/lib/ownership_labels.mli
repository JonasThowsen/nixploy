val resource_key :
  (string * Yojson.Safe.t) list ->
  project:Project_name.t ->
  target:Target_name.t ->
  string option
(** Returns the non-empty resource key only when the managed, project, and
    target labels are all present in the modern namespace and match exactly. *)

val exact :
  (string * Yojson.Safe.t) list ->
  project:Project_name.t ->
  target:Target_name.t ->
  resource_key:Resource_key.t ->
  bool
(** Requires the complete modern ownership identity: [io.nixploy.managed=true],
    project, target, and resource key. *)

val repository_identity : (string * Yojson.Safe.t) list -> string option
(** Reads only the canonical modern repository identity label. *)
