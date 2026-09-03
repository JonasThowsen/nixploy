open Core
module U = Caml_unix
module Lease = Target_lease
module Socket = Target_lease_socket

let default_socket_path = "/run/nixploy-target-lease/target-lease.sock"
let timeout_seconds = 2.

type configuration = {
  socket_path : string;
  authority : Lease.uuid;
  scope : Lease.uuid;
  identity : Lease.uuid;
}

type lease = {
  fd : U.file_descr;
  request : Lease.request;
  receipt : Lease.uuid;
  mutable closed : bool;
}

module Configuration = struct
  type t = configuration

  let create_with_socket ~socket_path ~authority ~scope ~identity =
    let open Or_error.Let_syntax in
    let%bind authority = Lease.uuid_of_string authority in
    let%bind scope = Lease.uuid_of_string scope in
    let%map identity = Lease.uuid_of_string identity in
    { socket_path; authority; scope; identity }

  let create ~authority ~scope ~identity =
    create_with_socket ~socket_path:default_socket_path ~authority ~scope ~identity
end

let same_uuid left right =
  String.equal (Lease.uuid_to_string left) (Lease.uuid_to_string right)

let close lease =
  if not lease.closed then (
    lease.closed <- true;
    try U.close lease.fd with U.Unix_error _ -> ())

let error response =
  Or_error.errorf "NIXPLOY_TARGET_LEASE_%s"
    (Lease.render_response response)

let exchange fd message ~deadline =
  let open Or_error.Let_syntax in
  let%bind () =
    Socket.send_all fd ~data:(Lease.render_client_message message ^ "\n") ~deadline
  in
  let%bind line =
    Socket.recv_line fd ~limit:(Lease.max_line_bytes + 1) ~deadline
  in
  Lease.parse_response_line line

let acquire configuration ~operation =
  let open Or_error.Let_syntax in
  let%bind request =
    Lease.request_of_strings
      ~authority:(Lease.uuid_to_string configuration.authority)
      ~scope:(Lease.uuid_to_string configuration.scope) ~operation
  in
  let fd = ref None in
  Exn.protect
    ~f:(fun () ->
      let opened = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
      fd := Some opened;
      let deadline = Socket.now () +. timeout_seconds in
      let%bind () =
        Socket.connect opened (U.ADDR_UNIX configuration.socket_path) ~deadline
      in
      let%bind response = exchange opened (Lease.Acquire request) ~deadline in
      match response with
      | Lease.Ready ready
        when same_uuid ready.authority request.authority
             && same_uuid ready.scope request.scope
             && same_uuid ready.operation request.operation
             && same_uuid ready.identity configuration.identity
             && not (same_uuid ready.receipt request.operation) ->
          fd := None;
          Ok { fd = opened; request; receipt = ready.receipt; closed = false }
      | Lease.Ready _ ->
          Or_error.error_string
            "NIXPLOY_TARGET_LEASE_READY_MISMATCH: broker READY did not exactly bind request and identity"
      | response -> error response)
    ~finally:(fun () ->
      Option.iter !fd ~f:(fun opened ->
          try U.close opened with U.Unix_error _ -> ()))

let release_with_receipt lease receipt =
  if lease.closed then
    Or_error.error_string "NIXPLOY_TARGET_LEASE_ALREADY_CLOSED"
  else
    Exn.protect
      ~f:(fun () ->
        let deadline = Socket.now () +. timeout_seconds in
        let result =
          exchange lease.fd
            (Lease.Release { operation = lease.request.operation; receipt })
            ~deadline
        in
        match result with
        | Ok Lease.Released -> Ok ()
        | Ok response -> error response
        | Error error -> Error error)
      ~finally:(fun () -> close lease)

let release lease = release_with_receipt lease lease.receipt

module For_testing = struct
  let configuration ~socket_path ~authority ~scope ~identity =
    Configuration.create_with_socket ~socket_path ~authority ~scope ~identity

  let release_with_receipt lease ~receipt =
    let open Or_error.Let_syntax in
    let%bind receipt = Lease.uuid_of_string receipt in
    release_with_receipt lease receipt
end
