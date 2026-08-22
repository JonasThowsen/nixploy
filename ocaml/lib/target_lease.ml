open Core

type uuid = string
type request = { authority : uuid; scope : uuid; operation : uuid }
type release = { operation : uuid; receipt : uuid }
type client_message = Acquire of request | Release of release

type ready = {
  authority : uuid;
  scope : uuid;
  operation : uuid;
  receipt : uuid;
  identity : uuid;
}

type response = Ready of ready | Busy | Dirty | Denied | Released | Malformed

let max_line_bytes = 256

let uuid_of_string value =
  let valid_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  if String.length value <> 36 then
    Or_error.error_string "UUID must be 36 bytes"
  else if
    String.existsi value ~f:(fun index character ->
        if List.mem [ 8; 13; 18; 23 ] index ~equal:Int.equal then
          not (Char.equal character '-')
        else not (valid_hex character))
  then Or_error.error_string "UUID must be lowercase hexadecimal"
  else Or_error.return value

let uuid_to_string value = value

let request_of_strings ~authority ~scope ~operation =
  let open Or_error.Let_syntax in
  let%bind authority = uuid_of_string authority in
  let%bind scope = uuid_of_string scope in
  let%map operation = uuid_of_string operation in
  { authority; scope; operation }

let words line =
  if String.is_empty line || String.exists line ~f:(Char.equal '\000') then []
  else String.split line ~on:' '

let parse_client_line line =
  if String.length line > max_line_bytes then
    Or_error.error_string "line is too long"
  else
    match words line with
    | [ "V1"; "ACQUIRE"; authority; scope; operation ] ->
        request_of_strings ~authority ~scope ~operation
        |> Result.map ~f:(fun request -> Acquire request)
    | [ "V1"; "RELEASE"; operation; receipt ] ->
        let open Or_error.Let_syntax in
        let%bind operation = uuid_of_string operation in
        let%map receipt = uuid_of_string receipt in
        Release { operation; receipt }
    | _ -> Or_error.error_string "malformed target-lease message"

let parse_response_line line =
  if String.length line > max_line_bytes then
    Or_error.error_string "response is too long"
  else
    match words line with
    | [ "V1"; "READY"; authority; scope; operation; receipt; identity ] ->
        let open Or_error.Let_syntax in
        let%bind authority = uuid_of_string authority in
        let%bind scope = uuid_of_string scope in
        let%bind operation = uuid_of_string operation in
        let%bind receipt = uuid_of_string receipt in
        let%map identity = uuid_of_string identity in
        Ready { authority; scope; operation; receipt; identity }
    | [ "V1"; "BUSY" ] -> Ok Busy
    | [ "V1"; "DIRTY" ] -> Ok Dirty
    | [ "V1"; "DENIED" ] -> Ok Denied
    | [ "V1"; "RELEASED" ] -> Ok Released
    | [ "V1"; "MALFORMED" ] -> Ok Malformed
    | _ -> Or_error.error_string "malformed target-lease response"

let render_client_message = function
  | Acquire { authority; scope; operation } ->
      String.concat ~sep:" " [ "V1"; "ACQUIRE"; authority; scope; operation ]
  | Release { operation; receipt } ->
      String.concat ~sep:" " [ "V1"; "RELEASE"; operation; receipt ]

let render_response = function
  | Ready { authority; scope; operation; receipt; identity } ->
      String.concat ~sep:" "
        [ "V1"; "READY"; authority; scope; operation; receipt; identity ]
  | Busy -> "V1 BUSY"
  | Dirty -> "V1 DIRTY"
  | Denied -> "V1 DENIED"
  | Released -> "V1 RELEASED"
  | Malformed -> "V1 MALFORMED"
