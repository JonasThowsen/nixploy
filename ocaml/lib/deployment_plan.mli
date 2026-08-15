open Core

type slot = Blue | Green [@@deriving compare, equal, sexp]

type placement = Single_container | Web_slot of { slot : slot; port : int }
[@@deriving compare, equal, sexp]

type t

val create :
  target_kind:Configuration.Target.kind ->
  active_port:int option ->
  t Or_error.t

val target_kind : t -> Configuration.Target.kind
val placement : t -> placement
val active_slot : t -> slot option
val previous_port : t -> int option
val container_name : resource_key:Resource_key.t -> placement -> string
val web_container_name : resource_key:Resource_key.t -> slot -> string
val slot_name : slot -> string
