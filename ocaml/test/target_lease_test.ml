open Core
open Nixploy.Target_lease

let uuid = "11111111-2222-3333-4444-555555555555"
let scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let operation = "99999999-8888-7777-6666-555555555555"
let receipt = "01234567-89ab-4cde-8fab-0123456789ab"
let identity = "12345678-1234-4234-9234-123456789abc"

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let () =
  let request = Nixploy.Target_lease.request_of_strings ~authority:uuid ~scope ~operation |> assert_ok in
  assert (String.equal ("V1 ACQUIRE " ^ uuid ^ " " ^ scope ^ " " ^ operation) (render_client_message (Acquire request)));
  assert (Result.is_error (uuid_of_string (String.uppercase scope)));
  assert (Result.is_error (uuid_of_string "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeeg"));
  assert (Result.is_error (uuid_of_string "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeeZ"));
  assert (Result.is_error (uuid_of_string ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee" ^ String.of_char (Char.of_int_exn 0x80))));
  assert (Result.is_error (uuid_of_string "not-a-uuid"));
  assert (Result.is_error (parse_client_line "V1 ACQUIRE x y z extra"));
  assert (Result.is_error (parse_client_line "V1\000 ACQUIRE"));
  assert (Result.is_error (parse_client_line (String.make (max_line_bytes + 1) 'x')));
  let ready =
    Ready
      { authority = assert_ok (uuid_of_string uuid); scope = assert_ok (uuid_of_string scope); operation = assert_ok (uuid_of_string operation); receipt = assert_ok (uuid_of_string receipt); identity = assert_ok (uuid_of_string identity) }
  in
  let rendered = render_response ready in
  assert (String.is_substring rendered ~substring:receipt);
  assert (not (String.equal receipt operation));
  assert (Poly.equal (parse_response_line rendered) (Ok ready));
  assert (Result.is_error (parse_response_line (rendered ^ " extra")));
  assert (Result.is_error (parse_response_line "V1 READY 11111111-2222-3333-4444-555555555555"));
  assert (String.equal "V1 DIRTY" (render_response Dirty));
  assert (String.equal "V1 RELEASED" (render_response Released))
