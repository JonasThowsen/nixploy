open Async
open Core

type t = {
  stdout : string;
  stderr : string;
  exit_status : Core_unix.Exit_or_signal.t;
}

type completion =
  | Completed of t
  | Output_limit_exceeded of [ `Stdout | `Stderr ]
  | Timed_out

let termination_grace = Time_ns.Span.of_sec 2.

let read_bounded reader ~stream ~max_output_bytes ~overflow =
  let buffer = Buffer.create (Int.min max_output_bytes 65_536) in
  let%bind result =
    Reader.read_one_chunk_at_a_time reader ~handle_chunk:(fun chunk ~pos ~len ->
        if Buffer.length buffer + len > max_output_bytes then (
          if Ivar.is_empty overflow then Ivar.fill_exn overflow stream;
          Deferred.return (`Stop ()))
        else (
          Buffer.add_string buffer (Bigstring.to_string chunk ~pos ~len);
          Deferred.return `Continue))
  in
  let%map () = Reader.close reader in
  match result with
  | `Eof | `Stopped () -> Buffer.contents buffer
  | `Eof_with_unconsumed_data remaining ->
      if Buffer.length buffer + String.length remaining <= max_output_bytes then
        Buffer.add_string buffer remaining;
      Buffer.contents buffer

let terminate_process_group process wait =
  let group = `Group (Process.pid process) in
  Signal_unix.send_i Signal.term group;
  let%bind () =
    Deferred.any_unit
      [ (wait >>| fun _ -> ()); Clock_ns.after termination_grace ]
  in
  if not (Deferred.is_determined wait) then Signal_unix.send_i Signal.kill group;
  let%map _ = wait in
  ()

let run ?working_directory ?stdin ?env ~timeout ~max_output_bytes ~prog ~args ()
    =
  if max_output_bytes <= 0 then
    Deferred.Or_error.error_string "max_output_bytes must be positive"
  else
    let open Deferred.Let_syntax in
    let%bind created =
      Process.create ?working_dir:working_directory ?env
        ~setpgid:Core_unix.Pgid.new_process_group ~prog ~args ()
    in
    match created with
    | Error _ as error -> Deferred.return error
    | Ok process -> (
        let%bind () =
          match stdin with
          | None -> Writer.close (Process.stdin process)
          | Some input ->
              Writer.write (Process.stdin process) input;
              Writer.close (Process.stdin process)
        in
        let overflow = Ivar.create () in
        let stdout =
          read_bounded (Process.stdout process) ~stream:`Stdout
            ~max_output_bytes ~overflow
        in
        let stderr =
          read_bounded (Process.stderr process) ~stream:`Stderr
            ~max_output_bytes ~overflow
        in
        let wait = Process.wait process in
        let completed =
          let%map stdout = stdout and stderr = stderr and exit_status = wait in
          Completed { stdout; stderr; exit_status }
        in
        let%bind completion =
          Deferred.choose
            [
              Deferred.choice completed Fn.id;
              Deferred.choice (Ivar.read overflow) (fun stream ->
                  Output_limit_exceeded stream);
              Deferred.choice (Clock_ns.after timeout) (fun () -> Timed_out);
            ]
        in
        match completion with
        | Completed result -> Deferred.Or_error.return result
        | Output_limit_exceeded stream ->
            let%map () = terminate_process_group process wait in
            Or_error.errorf "%s %s exceeded %d bytes" prog
              (match stream with `Stdout -> "stdout" | `Stderr -> "stderr")
              max_output_bytes
        | Timed_out ->
            let%map () = terminate_process_group process wait in
            Or_error.errorf "%s timed out after %s" prog
              (Time_ns.Span.to_short_string timeout))

let run_stdout ?working_directory ?stdin ?env ~timeout ~max_output_bytes ~prog
    ~args () =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    run ?working_directory ?stdin ?env ~timeout ~max_output_bytes ~prog ~args ()
  in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result.stdout
  | Error failure ->
      Deferred.Or_error.errorf "%s failed (%s): %s" prog
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)
