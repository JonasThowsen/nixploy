open Core
open Nixploy.Target_lease

let uuid = "11111111-2222-3333-4444-555555555555"
let scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
let operation = "99999999-8888-7777-6666-555555555555"

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let () =
  let request =
    Nixploy.Target_lease.request_of_strings ~authority:uuid ~scope ~operation
    |> assert_ok
  in
  assert (
    String.equal
      ("V1 ACQUIRE " ^ uuid ^ " " ^ scope ^ " " ^ operation)
      (Nixploy.Target_lease.render_client_message (Acquire request)));
  assert (
    Result.is_error
      (Nixploy.Target_lease.uuid_of_string (String.uppercase scope)));
  assert (Result.is_error (Nixploy.Target_lease.uuid_of_string "not-a-uuid"));
  assert (
    Result.is_error
      (Nixploy.Target_lease.parse_client_line "V1 ACQUIRE x y z extra"));
  assert (
    Result.is_error (Nixploy.Target_lease.parse_client_line "V1\000 ACQUIRE"));
  assert (
    Result.is_error
      (Nixploy.Target_lease.parse_client_line
         (String.make (Nixploy.Target_lease.max_line_bytes + 1) 'x')));
  assert (String.equal "V1 DIRTY" (Nixploy.Target_lease.render_response Dirty));
  assert (
    String.equal "V1 RELEASED" (Nixploy.Target_lease.render_response Released))
