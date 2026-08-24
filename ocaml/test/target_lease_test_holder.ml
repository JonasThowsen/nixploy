open Core

(* VM-test-only lease holder.  It deliberately never sends RELEASE: after an
   exactly bound READY it waits for its transient systemd unit to terminate.
   SIGKILL therefore exercises the broker's unclean-disconnect path without
   extending the packaged client command surface. *)

let response_timeout_seconds = 2.
let connect_timeout_seconds = 2.

type session = { fd : Caml_unix.file_descr }

let exchange_deadline () =
  response_timeout_seconds +. Nixploy.Target_lease_socket.now ()

let same_uuid left right =
  String.equal
    (Nixploy.Target_lease.uuid_to_string left)
    (Nixploy.Target_lease.uuid_to_string right)

let exchange session message =
  let open Or_error.Let_syntax in
  let%bind () =
    Nixploy.Target_lease_socket.send_all session.fd
      ~data:(Nixploy.Target_lease.render_client_message message ^ "\n")
      ~deadline:(exchange_deadline ())
  in
  let%bind line =
    Nixploy.Target_lease_socket.recv_line session.fd
      ~limit:(Nixploy.Target_lease.max_line_bytes + 1)
      ~deadline:(exchange_deadline ())
  in
  Nixploy.Target_lease.parse_response_line line

let rec wait_for_unit_termination () =
  Caml_unix.pause ();
  wait_for_unit_termination ()

let run ~socket_path ~authority ~scope ~operation ~identity =
  let open Or_error.Let_syntax in
  let%bind request =
    Nixploy.Target_lease.request_of_strings ~authority ~scope ~operation
  in
  let%bind expected_identity = Nixploy.Target_lease.uuid_of_string identity in
  let socket = ref None in
  Exn.protect
    ~f:(fun () ->
      try
        let fd = Caml_unix.socket Caml_unix.PF_UNIX Caml_unix.SOCK_STREAM 0 in
        socket := Some fd;
        let%bind () =
          Nixploy.Target_lease_socket.connect fd
            (Caml_unix.ADDR_UNIX socket_path)
            ~deadline:
              (connect_timeout_seconds +. Nixploy.Target_lease_socket.now ())
        in
        let session = { fd } in
        let%bind response =
          exchange session (Nixploy.Target_lease.Acquire request)
        in
        match response with
        | Nixploy.Target_lease.Ready ready
          when same_uuid ready.authority request.authority
               && same_uuid ready.scope request.scope
               && same_uuid ready.operation request.operation
               && same_uuid ready.identity expected_identity
               && not (same_uuid ready.receipt request.operation) ->
            printf "%s\n%!" (Nixploy.Target_lease.render_response response);
            wait_for_unit_termination ()
        | Nixploy.Target_lease.Ready _ ->
            Or_error.error_string
              "broker READY did not exactly bind request and identity"
        | _ -> Or_error.error_string "broker did not make the scope mutation-ready"
      with Caml_unix.Unix_error (error, _, _) ->
        Or_error.errorf "target-lease test holder failed: %s"
          (Caml_unix.error_message error))
    ~finally:(fun () ->
      Option.iter !socket ~f:(fun fd ->
          try Caml_unix.close fd with Caml_unix.Unix_error _ -> ()))

let command =
  Command.basic
    ~summary:"VM-test-only holder for an unclean target-lease disconnect"
    (let%map_open.Command socket_path =
       flag "--socket" (required string) ~doc:"PATH broker Unix socket"
     and authority =
       flag "--authority" (required string) ~doc:"UUID broker authority"
     and scope =
       flag "--scope" (required string)
         ~doc:"UUID configured coordination scope"
     and operation =
       flag "--operation" (required string) ~doc:"UUID caller correlation id"
     and identity =
       flag "--identity" (required string)
         ~doc:"UUID expected broker build/config identity"
     in
     fun () ->
       match run ~socket_path ~authority ~scope ~operation ~identity with
       | Ok () -> ()
       | Error error ->
           eprintf "%s\n%!" (Error.to_string_hum error);
           exit 1)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
