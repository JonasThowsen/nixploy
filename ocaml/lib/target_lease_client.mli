open Core
open Async

module Configuration : sig
  type t

  val create :
    authority:string -> scope:string -> identity:string -> t Or_error.t
  (** Builds the fixed broker contract selected by root-owned managed
      application authority. Socket selection is not caller-configurable. *)
end

type lease

val acquire :
  Configuration.t -> operation:string -> lease Deferred.Or_error.t
(** Connects to the fixed broker socket, acquires exactly one configured scope,
    and retains that authenticated socket until [release]. The bounded blocking
    socket protocol runs outside the Async scheduler. *)

val release : lease -> unit Deferred.Or_error.t
(** Releases only the exact operation/receipt returned by [acquire]. The lease
    descriptor is closed after every release outcome. *)

module For_testing : sig
  val configuration :
    socket_path:string -> authority:string -> scope:string -> identity:string ->
    Configuration.t Or_error.t

  val release_with_receipt :
    lease -> receipt:string -> unit Deferred.Or_error.t
end
