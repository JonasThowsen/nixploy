type t =
  | Idle
  | Previewing of string
  | Submitting of string
  | Awaiting_observation of { key : string; operation_id : string }
[@@deriving equal, sexp]

val start_preview : t -> key:string -> t
val finish_preview : t -> key:string -> t
val start_submission : t -> key:string -> t
val accept_submission : t -> key:string -> operation_id:string -> t
val finish_submission : t -> key:string -> t
val observe_operation : t -> key:string -> operation_id:string -> t
val reset_for_route_change : t -> t
val awaiting_operation : t -> (string * string) option
val is_busy : t -> bool
val is_previewing : t -> key:string -> bool
val is_pending : t -> bool
val is_pending_for : t -> key:string -> bool
