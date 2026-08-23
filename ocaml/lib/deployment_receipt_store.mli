open Core

type 'a t

val create :
  ?capacity:int ->
  ?ttl_seconds:float ->
  ?now:(unit -> float) ->
  ?random_bytes:(int -> string Or_error.t) ->
  unit ->
  'a t Or_error.t
(** Creates a process-local, bounded receipt store. Expiry uses a monotonic
    clock; process restart deliberately discards every receipt. *)

val issue : 'a t -> application_key:string -> 'a -> string Or_error.t
(** Returns an opaque 256-bit receipt generated from the operating system
    CSPRNG. *)

val consume : 'a t -> application_key:string -> receipt:string -> 'a Or_error.t
(** Atomically removes a receipt before returning its payload. Unknown, expired,
    evicted, replayed, and application-mismatched receipts share one fail-closed
    error. Token comparison is constant-time. *)
