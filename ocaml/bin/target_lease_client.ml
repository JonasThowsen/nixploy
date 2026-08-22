open Core
module U = Caml_unix

let read_response input =
  match In_channel.input_line input with
  | None -> Or_error.error_string "broker closed without a response"
  | Some response ->
      if String.length response > Nixploy.Target_lease.max_line_bytes then
        Or_error.error_string "broker response exceeded bound"
      else Or_error.return response

let run ~socket_path ~authority ~scope ~operation ~hold_seconds ~release =
  let open Or_error.Let_syntax in
  let%bind request =
    Nixploy.Target_lease.request_of_strings ~authority ~scope ~operation
  in
  try
    let socket = U.socket U.PF_UNIX U.SOCK_STREAM 0 in
    U.connect socket (U.ADDR_UNIX socket_path);
    let output = U.out_channel_of_descr socket in
    Out_channel.output_string output
      (Nixploy.Target_lease.render_client_message
         (Nixploy.Target_lease.Acquire request)
      ^ "\n");
    Out_channel.flush output;
    let input = U.in_channel_of_descr socket in
    let%bind response = read_response input in
    printf "%s\n%!" response;
    if String.is_prefix response ~prefix:"V1 READY " then (
      if hold_seconds > 0 then U.sleep hold_seconds;
      if release then (
        Out_channel.output_string output
          (Nixploy.Target_lease.render_client_message
             (Nixploy.Target_lease.Release
                { operation = request.operation; receipt = request.operation })
          ^ "\n");
        Out_channel.flush output;
        let%map released = read_response input in
        printf "%s\n%!" released)
      else Or_error.return ())
    else Or_error.error_string "broker did not make the scope mutation-ready"
  with U.Unix_error (error, _, _) ->
    Or_error.errorf "target-lease client failed: %s" (U.error_message error)

let command =
  Command.basic
    ~summary:"Probe a configured target-lease broker without executing work"
    (let%map_open.Command socket_path =
       flag "--socket" (required string) ~doc:"PATH broker Unix socket"
     and authority =
       flag "--authority" (required string) ~doc:"UUID broker authority"
     and scope =
       flag "--scope" (required string)
         ~doc:"UUID configured coordination scope"
     and operation =
       flag "--operation" (required string) ~doc:"UUID caller correlation id"
     and hold_seconds =
       flag "--hold-seconds"
         (optional_with_default 0 int)
         ~doc:"SECONDS keep the live session open (0-60)"
     and release =
       flag "--release" no_arg
         ~doc:" explicitly cleanly release this live session"
     in
     fun () ->
       if hold_seconds < 0 || hold_seconds > 60 then (
         eprintf "--hold-seconds must be 0 to 60\n%!";
         exit 2)
       else
         match
           run ~socket_path ~authority ~scope ~operation ~hold_seconds ~release
         with
         | Ok () -> ()
         | Error error ->
             eprintf "%s\n%!" (Error.to_string_hum error);
             exit 1)

let () = Command_unix.run ~version:"0.1.0-ocaml" command
