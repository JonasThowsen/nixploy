open Core

let response_timeout_seconds = 2.
let connect_timeout_seconds = 2.

(* One absolute CLOCK_MONOTONIC deadline bounds connect, write, and read for
   each exchange; every EINTR/EAGAIN retry recomputes the remaining time from
   it. *)
type session = { fd : Caml_unix.file_descr }

(* Each exchange gets one absolute CLOCK_MONOTONIC deadline; every
   EINTR/EAGAIN retry inside it recomputes the remaining time from that same
   deadline, so a long-held lease session cannot inherit a stale bound. *)
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

let fail_terminal _response =
  Or_error.error_string "broker did not make the scope mutation-ready"

(* Test harnesses can use a file as an explicit release barrier: once READY is
   printed, this client cannot retire the dirty marker until the file exists.
   Unlike a duration, VM scheduling delay cannot accidentally clean the lease
   before a test observes its durable evidence. *)
let release_signal_exists path =
  try
    Caml_unix.access path [ Caml_unix.F_OK ];
    true
  with Caml_unix.Unix_error (Caml_unix.ENOENT, _, _) -> false

let rec wait_for_release_signal path =
  if release_signal_exists path then ()
  else (
    ignore (Caml_unix.select [] [] [] 0.05 : _ * _ * _);
    wait_for_release_signal path)

let run ~socket_path ~authority ~scope ~operation ~identity ~hold_seconds
    ~release_signal =
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
        (* Nonblocking connect bounded by one absolute deadline. *)
        (match
           Nixploy.Target_lease_socket.connect fd
             (Caml_unix.ADDR_UNIX socket_path)
             ~deadline:
               (connect_timeout_seconds +. Nixploy.Target_lease_socket.now ())
         with
        | Ok () -> ()
        | Error error -> raise_s [%message "connect failed" (error : Error.t)]);
        let session = { fd } in
        let%bind response =
          exchange session (Nixploy.Target_lease.Acquire request)
        in
        printf "%s\n%!" (Nixploy.Target_lease.render_response response);
        match response with
        | Nixploy.Target_lease.Ready ready
          when same_uuid ready.authority request.authority
               && same_uuid ready.scope request.scope
               && same_uuid ready.operation request.operation
               && same_uuid ready.identity expected_identity
               && not (same_uuid ready.receipt request.operation) -> (
            Option.iter release_signal ~f:wait_for_release_signal;
            if hold_seconds > 0 then Caml_unix.sleep hold_seconds;
            let%bind released =
              exchange session
                (Nixploy.Target_lease.Release
                   { operation = request.operation; receipt = ready.receipt })
            in
            printf "%s\n%!" (Nixploy.Target_lease.render_response released);
            match released with
            | Nixploy.Target_lease.Released -> Ok ()
            | _ ->
                Or_error.error_string
                  "broker did not acknowledge the exact release")
        | Nixploy.Target_lease.Ready _ ->
            Or_error.error_string
              "broker READY did not exactly bind request and identity"
        | response -> fail_terminal response
      with Caml_unix.Unix_error (error, _, _) ->
        Or_error.errorf "target-lease client failed: %s"
          (Caml_unix.error_message error))
    ~finally:(fun () ->
      Option.iter !socket ~f:(fun fd ->
          try Caml_unix.close fd with Caml_unix.Unix_error _ -> ()))

let command =
  Command.basic
    ~summary:
      "Acquire one configured target lease and cleanly release it on the same \
       session"
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
     and hold_seconds =
       flag "--hold-seconds"
         (optional_with_default 0 int)
         ~doc:"SECONDS keep the live session open (0-60)"
     and release_signal =
       flag "--release-signal" (optional string)
         ~doc:"PATH wait for this test barrier before cleanly releasing"
     in
     fun () ->
       if hold_seconds < 0 || hold_seconds > 60 then (
         eprintf "--hold-seconds must be 0 to 60\n%!";
         exit 2)
       else if Option.is_some release_signal && hold_seconds <> 0 then (
         eprintf "--release-signal cannot be combined with --hold-seconds\n%!";
         exit 2)
       else
         match
           run ~socket_path ~authority ~scope ~operation ~identity ~hold_seconds
             ~release_signal
         with
         | Ok () -> ()
         | Error error ->
             eprintf "%s\n%!" (Error.to_string_hum error);
             exit 1)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
