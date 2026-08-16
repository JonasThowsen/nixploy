type t = Idle | Previewing of string | Submitting of string
[@@deriving equal, sexp]

val start_preview : t -> key:string -> t
val finish_preview : t -> key:string -> t
val start_submission : t -> key:string -> t
val finish_submission : t -> key:string -> t
val is_busy : t -> bool
val is_previewing : t -> key:string -> bool
val is_pending : t -> bool
val is_pending_for : t -> key:string -> bool
