open Core

type slot = Blue | Green [@@deriving compare, equal, sexp]
type t

val create : web:Configuration.Web.t -> active_port:int option -> t Or_error.t
val active_slot : t -> slot option
val candidate_slot : t -> slot
val candidate_port : t -> int
val previous_port : t -> int option
val container_name : resource_key:Resource_key.t -> slot -> string
val slot_name : slot -> string
