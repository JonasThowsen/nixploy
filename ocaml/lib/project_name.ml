open Core

type t = string [@@deriving compare, equal, sexp]

let of_string value =
  let value = String.strip value in
  if String.is_empty value then
    Or_error.error_string "project name must not be empty"
  else Ok value

let to_string t = t
