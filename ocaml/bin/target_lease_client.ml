open Core
module U = Caml_unix

let response_timeout_seconds = 2.
let now () = U.gettimeofday ()

let rec wait fd readable writable remaining =
  try
    let readable_fds, writable_fds, _ = U.select (if readable then [ fd ] else []) (if writable then [ fd ] else []) [] remaining in
    (not (List.is_empty readable_fds), not (List.is_empty writable_fds))
  with U.Unix_error (U.EINTR, _, _) -> wait fd readable writable remaining

let write_all fd line =
  let deadline = now () +. response_timeout_seconds in
  let rec write offset =
    if offset = String.length line then Ok ()
    else
      try
        let count = U.write_substring fd line offset (String.length line - offset) in
        if count > 0 then write (offset + count) else Or_error.error_string "socket write returned zero bytes"
      with
      | U.Unix_error (U.EINTR, _, _) -> write offset
      | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) ->
          let remaining = deadline -. now () in
          if Float.(remaining <= 0.) then Or_error.error_string "broker response write timed out"
          else
            let _, writable = wait fd false true remaining in
            if Float.(now () >= deadline) || not writable then Or_error.error_string "broker response write timed out" else write offset
      | U.Unix_error (error, _, _) -> Or_error.errorf "socket write failed: %s" (U.error_message error)
  in
  write 0

let read_response fd =
  let deadline = now () +. response_timeout_seconds in
  let buffer = Buffer.create Nixploy.Target_lease.max_line_bytes in
  let bytes = Bytes.create 64 in
  let rec read () =
    if Float.(now () >= deadline) then Or_error.error_string "broker response timed out"
    else
      match String.lsplit2 (Buffer.contents buffer) ~on:'\n' with
      | Some (line, "") -> Nixploy.Target_lease.parse_response_line line
      | Some _ -> Or_error.error_string "broker response contains extra bytes"
      | None ->
          if Buffer.length buffer > Nixploy.Target_lease.max_line_bytes then Or_error.error_string "broker response exceeded bound"
          else
            let wait_remaining = deadline -. now () in
            if Float.(wait_remaining <= 0.) then Or_error.error_string "broker response timed out"
            else
              let readable, _ = wait fd true false wait_remaining in
              if not readable then Or_error.error_string "broker response timed out"
              else
                let remaining = Nixploy.Target_lease.max_line_bytes + 1 - Buffer.length buffer in
                try
                match U.read fd bytes 0 (Int.min (Bytes.length bytes) remaining) with
                | 0 -> Or_error.error_string "broker closed without a response"
                | count ->
                    Buffer.add_string buffer (Stdlib.Bytes.sub_string bytes 0 count);
                    read ()
              with
              | U.Unix_error (U.EINTR, _, _) -> read ()
              | U.Unix_error ((U.EAGAIN | U.EWOULDBLOCK), _, _) -> read ()
              | U.Unix_error (error, _, _) -> Or_error.errorf "socket read failed: %s" (U.error_message error)
  in
  read ()

let same_uuid left right =
  String.equal (Nixploy.Target_lease.uuid_to_string left) (Nixploy.Target_lease.uuid_to_string right)

let fail_terminal _response = Or_error.error_string "broker did not make the scope mutation-ready"

let run ~socket_path ~authority ~scope ~operation ~identity ~hold_seconds =
  let open Or_error.Let_syntax in
  let%bind request = Nixploy.Target_lease.request_of_strings ~authority ~scope ~operation in
  let%bind expected_identity = Nixploy.Target_lease.uuid_of_string identity in
  let socket = ref None in
  Exn.protect
    ~f:(fun () ->
      try
        let fd = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
        socket := Some fd;
        U.connect fd (U.ADDR_UNIX socket_path);
        U.set_nonblock fd;
        let%bind () =
          write_all fd
            (Nixploy.Target_lease.render_client_message (Nixploy.Target_lease.Acquire request) ^ "\n")
        in
        let%bind response = read_response fd in
        printf "%s\n%!" (Nixploy.Target_lease.render_response response);
        match response with
        | Nixploy.Target_lease.Ready ready
          when same_uuid ready.authority request.authority
               && same_uuid ready.scope request.scope
               && same_uuid ready.operation request.operation
               && same_uuid ready.identity expected_identity
               && not (same_uuid ready.receipt request.operation) ->
            if hold_seconds > 0 then U.sleep hold_seconds;
            let%bind () =
              write_all fd
                (Nixploy.Target_lease.render_client_message
                   (Nixploy.Target_lease.Release { operation = request.operation; receipt = ready.receipt })
                ^ "\n")
            in
            let%bind released = read_response fd in
            printf "%s\n%!" (Nixploy.Target_lease.render_response released);
            (match released with
            | Nixploy.Target_lease.Released -> Ok ()
            | _ -> Or_error.error_string "broker did not acknowledge the exact release")
        | Nixploy.Target_lease.Ready _ -> Or_error.error_string "broker READY did not exactly bind request and identity"
        | response -> fail_terminal response
      with U.Unix_error (error, _, _) ->
        Or_error.errorf "target-lease client failed: %s" (U.error_message error))
    ~finally:(fun () ->
      Option.iter !socket ~f:(fun fd -> try U.close fd with U.Unix_error _ -> ()))

let command =
  Command.basic
    ~summary:"Acquire one configured target lease and cleanly release it on the same session"
    (let%map_open.Command socket_path =
       flag "--socket" (required string) ~doc:"PATH broker Unix socket"
     and authority = flag "--authority" (required string) ~doc:"UUID broker authority"
     and scope = flag "--scope" (required string) ~doc:"UUID configured coordination scope"
     and operation = flag "--operation" (required string) ~doc:"UUID caller correlation id"
     and identity = flag "--identity" (required string) ~doc:"UUID expected broker build/config identity"
     and hold_seconds = flag "--hold-seconds" (optional_with_default 0 int) ~doc:"SECONDS keep the live session open (0-60)"
     in
     fun () ->
       if hold_seconds < 0 || hold_seconds > 60 then (
         eprintf "--hold-seconds must be 0 to 60\n%!";
         exit 2)
       else
         match run ~socket_path ~authority ~scope ~operation ~identity ~hold_seconds with
         | Ok () -> ()
         | Error error ->
             eprintf "%s\n%!" (Error.to_string_hum error);
             exit 1)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
