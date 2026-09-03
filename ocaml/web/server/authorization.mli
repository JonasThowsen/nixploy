open Core

type t

type authenticated_identity = Tailscale_login of string
[@@deriving compare, equal, sexp]

type origin_policy

val of_values :
  mode:string option ->
  operator_email:string option ->
  trusted_tailscale_loopback_proxy:bool ->
  t Or_error.t

val load_environment :
  trusted_tailscale_loopback_proxy:bool -> unit -> t Or_error.t
val origin_policy_of_value : string option -> origin_policy Or_error.t
val load_origin_policy : unit -> origin_policy Or_error.t
val authorized : t -> Cohttp.Header.t -> bool

val authenticated_identity :
  t -> Cohttp.Header.t -> authenticated_identity Or_error.t

val authorize_websocket :
  t -> origin_policy -> Cohttp.Header.t -> unit Or_error.t
