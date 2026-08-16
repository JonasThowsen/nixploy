open Core

module Application_key : sig
  type t [@@deriving compare, equal, sexp]

  val of_string : string -> t Or_error.t
  val to_string : t -> string
end

type t =
  | Home
  | Apps
  | Application of Application_key.t
  | Telemetry
  | Not_found of string
[@@deriving compare, equal, sexp]

type parsed = { route : t; canonical_path : string option }
[@@deriving equal, sexp]

val parse_path : string -> parsed
val to_path : t -> string
val page_title : t -> string
val application_key : t -> Application_key.t option
val is_apps_section : t -> bool
