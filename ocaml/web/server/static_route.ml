open Core

let valid_application_key value =
  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length value in
  length >= 1 && length <= 63
  && (match value.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && String.for_all value ~f:valid_character

let without_trailing_slashes path =
  if String.equal path "/" then path
  else String.rstrip path ~drop:(Char.equal '/')

let serves_spa_shell path =
  match String.split (without_trailing_slashes path) ~on:'/' with
  | [ "" ]
  | [ ""; "" ]
  | [ ""; "index.html" ]
  | [ ""; "apps" ]
  | [ ""; "telemetry" ] ->
      true
  | [ ""; "apps"; key ] -> valid_application_key key
  | _ -> false
