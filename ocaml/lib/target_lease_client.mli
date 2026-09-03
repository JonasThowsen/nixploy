open Core

module Configuration : sig
  type t

  val create :
    authority:string -> scope:string -> identity:string -> t Or_error.t
  (** Builds the fixed broker contract selected by root-owned managed
      application authority. Socket selection is not caller-configurable. *)
end

type lease

val acquire :
  Configuration.t -> operation:string -> lease Or_error.t
(** Connects to the fixed broker socket, acquires exactly one configured scope,
    and retains that authenticated socket until [release]. *)

val release : lease -> unit Or_error.t
(** Releases only the exact operation/receipt returned by [acquire]. *)

module For_testing : sig
  val configuration :
    socket_path:string -> authority:string -> scope:string -> identity:string ->
    Configuration.t Or_error.t

  val release_with_receipt : lease -> receipt:string -> unit Or_error.t
end
