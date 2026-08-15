open Async
open Core

type t

val load :
  source_root:string ->
  target:Configuration.Target.t ->
  t list Deferred.Or_error.t

val name : t -> string
val value : t -> string
val redact : t list -> string -> string

module For_testing : sig
  val parse_dotenv : string -> t list Or_error.t
  val resolve_reference : source_root:string -> string -> string Or_error.t
  val validate_private_identity_file : string -> unit Or_error.t
end
