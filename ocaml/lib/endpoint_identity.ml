open Core

let drop_trailing_dots value = String.rstrip value ~drop:(Char.equal '.')

let has_unsafe_character value =
  String.exists value ~f:(fun character ->
      Char.is_whitespace character
      || Char.to_int character < 0x20
      || Char.to_int character = 0x7f
      || Char.equal character '/' || Char.equal character '@')

let normalized ~field ~dns ~valid_character value =
  let value = String.strip value |> String.lowercase in
  let value = if dns then drop_trailing_dots value else value in
  if String.is_empty value then Or_error.errorf "%s must not be empty" field
  else if
    has_unsafe_character value || not (String.for_all value ~f:valid_character)
  then Or_error.errorf "%s contains an unsafe character" field
  else Ok value

let host_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '-' | ':' | '[' | ']' | '%' -> true
  | _ -> false

let domain_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '-' -> true
  | _ -> false

let scope_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '-' | '_' | ':' -> true
  | _ -> false

let host =
  normalized ~field:"SSH host" ~dns:true ~valid_character:host_character

let domain =
  normalized ~field:"web domain" ~dns:true ~valid_character:domain_character

let coordination_scope =
  normalized ~field:"coordination scope" ~dns:false
    ~valid_character:scope_character
