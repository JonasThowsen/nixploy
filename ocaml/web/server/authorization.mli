open Core

type t = Unrestricted | Tailscale of string
type origin_policy

val of_values :
  mode:string option -> operator_email:string option -> t Or_error.t

val load_environment : unit -> t Or_error.t
val origin_policy_of_value : string option -> origin_policy Or_error.t
val load_origin_policy : unit -> origin_policy Or_error.t
val authorized : t -> Cohttp.Header.t -> bool

val authorize_websocket :
  t -> origin_policy -> Cohttp.Header.t -> unit Or_error.t
