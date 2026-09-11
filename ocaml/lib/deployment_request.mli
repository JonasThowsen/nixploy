open Core

type t

val create :
  ?expected_project:Project_name.t ->
  working_directory:string ->
  source:Source.selection ->
  target:Target_name.t ->
  unit ->
  t Or_error.t
(** Selects one local source and target; no registry, receipt, or admission
    authority. *)

val working_directory : t -> string
val source : t -> Source.selection
val target : t -> Target_name.t
val expected_project : t -> Project_name.t option

val claim : t -> unit Or_error.t
(** A request can prepare a source only once. *)

val bind_operation : t -> operation_id:string -> unit Or_error.t

val validate_operation : t -> operation_id:string -> unit Or_error.t
(** Prevents executing a prepared source under a different history operation. *)
