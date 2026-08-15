type terminal_state =
  | Succeeded
  | Failed of string option
  | Cancelled
  | Incomplete
[@@deriving equal, sexp]

type t

val of_deployment : Nixploy.Application.deployment -> t
val id : t -> string
val state_name : t -> string
val revision : t -> string option
val container_name : t -> string option
val terminal_state : t -> terminal_state
