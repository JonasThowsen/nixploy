open Async
open Core

type t

val observe : Configuration.Target.t -> t Deferred.Or_error.t
val cpu_percent : t -> float
val memory_used_bytes : t -> int64
val memory_total_bytes : t -> int64
val filesystem_used_bytes : t -> int64
val filesystem_total_bytes : t -> int64
val load_1 : t -> float
val load_5 : t -> float
val load_15 : t -> float
val uptime_seconds : t -> int64

module For_testing : sig
  val parse : string -> t Or_error.t
end
