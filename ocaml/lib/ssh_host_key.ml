open Core

type t = string

let fingerprint t = t

let base64_index = function
  | 'A' .. 'Z' as character -> Char.to_int character - Char.to_int 'A'
  | 'a' .. 'z' as character -> 26 + Char.to_int character - Char.to_int 'a'
  | '0' .. '9' as character -> 52 + Char.to_int character - Char.to_int '0'
  | '+' -> 62
  | '/' -> 63
  | _ -> -1

let of_fingerprint value =
  let prefix = "SHA256:" in
  let encoded = Option.value (String.chop_prefix value ~prefix) ~default:"" in
  if not (String.is_prefix value ~prefix) then
    Or_error.error_string
      "SSH host key fingerprint must start with SHA256:"
  else if String.length encoded <> 43 then
    Or_error.error_string
      "SSH host key fingerprint must contain an unpadded base64 SHA-256 digest"
  else if String.exists encoded ~f:(fun character -> base64_index character < 0)
  then
    Or_error.error_string
      "SSH host key fingerprint contains invalid base64 characters"
  else if base64_index encoded.[42] mod 16 <> 0 then
    Or_error.error_string
      "SSH host key fingerprint does not encode a SHA-256 digest"
  else Ok value
