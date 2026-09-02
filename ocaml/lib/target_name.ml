open Core

type t = string [@@deriving compare, equal, sexp]

let maximum_length = 255

let of_string value =
  let value = String.strip value in
  if String.is_empty value then
    Or_error.error_string "target name must not be empty"
  else if String.length value > maximum_length then
    Or_error.errorf "target name must be at most %d bytes" maximum_length
  else Ok value

let to_string t = t
