open Core

type t = {
  managed_application_key : string;
  requested_target : Target_name.t;
  provenance : string;
  revision : string;
}

let invalid format =
  Printf.ksprintf
    (fun message ->
      Or_error.errorf "NIXPLOY_MANAGED_DEPLOY_REQUEST_INVALID: %s" message)
    format

let valid_application_key key =
  let valid_character = function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length key in
  length > 0 && length <= 63
  && (Char.is_lowercase key.[0] || Char.is_digit key.[0])
  && String.for_all key ~f:valid_character

let valid_provenance provenance =
  let length = String.length provenance in
  length > 0 && length <= 1024
  && String.for_all provenance ~f:(fun character ->
      Int.(Char.to_int character >= 0x20 && Char.to_int character <> 0x7f))

let valid_revision revision =
  String.length revision = 40
  && String.for_all revision ~f:(function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false)

let create ~managed_application_key ~requested_target ~provenance ~revision =
  if not (valid_application_key managed_application_key) then
    invalid
      "managed application key must use lowercase letters, digits, dashes, or \
       underscores"
  else if not (valid_provenance provenance) then
    invalid "provenance must be 1-1024 printable bytes"
  else if not (valid_revision revision) then
    invalid "revision must be exactly 40 lowercase hexadecimal characters"
  else
    match Target_name.of_string requested_target with
    | Error _ -> invalid "requested target is invalid"
    | Ok requested_target ->
        Ok { managed_application_key; requested_target; provenance; revision }

let managed_application_key t = t.managed_application_key
let requested_target t = t.requested_target
let provenance t = t.provenance
let revision t = t.revision
