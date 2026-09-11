open Core

val validate_configuration :
  Configuration.t -> target:Target_name.t -> unit Or_error.t
(** Requires a declared target and rejects obsolete controlPlane configuration
    with a migration error. No authority profile or registry is required. *)
