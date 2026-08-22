open Core

(** Bounded values and wire messages for the target-lease tracer. The broker
    owns authorization and durable state; these values deliberately contain no
    paths, usernames, timestamps, or commands. *)

type uuid
type request = { authority : uuid; scope : uuid; operation : uuid }
type release = { operation : uuid; receipt : uuid }
type client_message = Acquire of request | Release of release
type response = Ready of uuid | Busy | Dirty | Denied | Released | Malformed

val uuid_of_string : string -> uuid Or_error.t
val uuid_to_string : uuid -> string

val request_of_strings :
  authority:string -> scope:string -> operation:string -> request Or_error.t

val parse_client_line : string -> client_message Or_error.t
val render_client_message : client_message -> string
val render_response : response -> string
val max_line_bytes : int
