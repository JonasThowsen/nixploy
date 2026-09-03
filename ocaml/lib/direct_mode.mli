open Core

val validate_configuration :
  Configuration.t -> target:Target_name.t -> unit Or_error.t
(** Rejects every direct operation from a flake that declares control-plane
    identity and requires an explicitly declared production or non-production
    target profile. *)
