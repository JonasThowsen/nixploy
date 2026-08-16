type t =
  | Idle
  | Confirming of { key : string; error : string option }
  | Pending of string
[@@deriving equal, sexp]

val confirm : t -> key:string -> t
val start : t -> key:string -> t
val fail : t -> key:string -> error:string -> t
val succeed : t -> key:string -> t
val keep : t -> key:string -> t
val is_pending : t -> bool
val is_busy : t -> bool
val confirmation : t -> (string * string option) option
