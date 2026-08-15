open Core

type t = Unrestricted | Tailscale of string

val of_values :
  mode:string option -> operator_email:string option -> t Or_error.t

val load_environment : unit -> t Or_error.t
val authorized : t -> Cohttp.Header.t -> bool
