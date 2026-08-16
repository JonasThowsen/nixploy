open Core

module Application_key = struct
  type t = string [@@deriving compare, equal, sexp]

  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false

  let valid value =
    let length = String.length value in
    length >= 1 && length <= 63
    && (match value.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
    && String.for_all value ~f:valid_character

  let of_string value =
    if valid value then Ok value
    else
      Or_error.errorf
        "application route key must match [a-z0-9][a-z0-9_-]{0,62}: %s" value

  let to_string value = value
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

let without_trailing_slashes path =
  if String.equal path "/" then path
  else String.rstrip path ~drop:(Char.equal '/')

let parse_canonical path =
  match String.split path ~on:'/' with
  | [ "" ] | [ ""; "" ] -> Home
  | [ ""; "apps" ] -> Apps
  | [ ""; "telemetry" ] -> Telemetry
  | [ ""; "apps"; key ] -> (
      match Application_key.of_string key with
      | Ok key -> Application key
      | Error _ -> Not_found path)
  | _ -> Not_found path

let parse_path path =
  let path = if String.is_empty path then "/" else path in
  let canonical = without_trailing_slashes path in
  if String.equal canonical "/index.html" then
    { route = Home; canonical_path = Some "/" }
  else
    let route = parse_canonical canonical in
    let canonical_path =
      match route with
      | Not_found _ -> None
      | Home | Apps | Application _ | Telemetry ->
          if String.equal path canonical then None else Some canonical
    in
    { route; canonical_path }

let to_path = function
  | Home -> "/"
  | Apps -> "/apps"
  | Application key -> "/apps/" ^ Application_key.to_string key
  | Telemetry -> "/telemetry"
  | Not_found path -> path

let page_title = function
  | Home -> "Home"
  | Apps -> "Applications"
  | Application key -> Application_key.to_string key
  | Telemetry -> "Telemetry"
  | Not_found _ -> "Not found"

let application_key = function
  | Application key -> Some key
  | Home | Apps | Telemetry | Not_found _ -> None

let is_apps_section = function
  | Apps | Application _ -> true
  | Home | Telemetry | Not_found _ -> false
