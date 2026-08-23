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
  | Interrupted of Signal.t
  | Cancelled

let termination_grace = Time_ns.Span.of_sec 2.

type termination_state = { delivered : Signal.t Ivar.t }

let termination_state = ref None
let active_process_groups = ref []

let unregister_process_group pid =
  active_process_groups :=
    List.filter !active_process_groups ~f:(fun active ->
        not (Pid.equal active pid))

let should_force_termination ~already_delivered = already_delivered

let handle_termination_signals () =
  match !termination_state with
  | Some _ -> ()
  | None ->
      let state = { delivered = Ivar.create () } in
      termination_state := Some state;
      Async.Signal.handle [ Signal.int; Signal.term ] ~f:(fun signal ->
          if
            not
              (should_force_termination
                 ~already_delivered:(not (Ivar.is_empty state.delivered)))
          then Ivar.fill_exn state.delivered signal
          else (
            List.iter !active_process_groups ~f:(fun pid ->
                Signal_unix.send_i Signal.kill (`Group pid));
            Shutdown.shutdown_with_signal_exn signal))

let interruption_error prog signal =
  Or_error.errorf "%s interrupted by %s" prog (Signal.to_string signal)

let cancellation_error prog = Or_error.errorf "%s cancelled" prog

let termination_signal () =
  Option.bind !termination_state ~f:(fun state -> Ivar.peek state.delivered)

let termination_requested () =
  handle_termination_signals ();
  match !termination_state with
  | Some state -> Ivar.read state.delivered
  | None -> raise_s [%message "termination signal handler was not initialized"]

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
  let grace_elapsed = Clock_ns.after termination_grace in
  let%bind first =
    Deferred.choose
      [
        Deferred.choice wait (fun _ -> `Leader_exited);
        Deferred.choice grace_elapsed (fun () -> `Grace_elapsed);
      ]
  in
  let group_exists () =
    match Signal_unix.send Signal.zero group with
    | `Ok -> true
    | `No_such_process -> false
  in
  let%bind () =
    match first with
    | `Grace_elapsed -> Deferred.unit
    | `Leader_exited -> if group_exists () then grace_elapsed else Deferred.unit
  in
  if group_exists () then Signal_unix.send_i Signal.kill group;
  let%map _ = wait in
  ()

let run_without_progress ?working_directory ?stdin ?env
    ?(ignore_termination = false) ~timeout ~max_output_bytes ~prog ~args () =
  if max_output_bytes <= 0 then
    Deferred.Or_error.error_string "max_output_bytes must be positive"
  else
    let delivered =
      if ignore_termination then None
      else Option.map !termination_state ~f:(fun state -> state.delivered)
    in
    let cancellation =
      if ignore_termination then None else Cancellation.current ()
    in
    match Option.bind delivered ~f:Ivar.peek with
    | Some signal -> Deferred.return (interruption_error prog signal)
    | None
      when Option.exists cancellation ~f:(fun token ->
               Deferred.is_determined (Cancellation.requested token)) ->
        ignore (Cancellation.acknowledge_current () : bool);
        Deferred.return (cancellation_error prog)
    | None -> (
        let open Deferred.Let_syntax in
        let%bind created =
          Process.create ?working_dir:working_directory ?env
            ~setpgid:Core_unix.Pgid.new_process_group ~prog ~args ()
        in
        match created with
        | Error _ as error ->
            if
              Option.exists cancellation ~f:(fun token ->
                  Deferred.is_determined (Cancellation.requested token))
            then (
              ignore (Cancellation.acknowledge_current () : bool);
              Deferred.return (cancellation_error prog))
            else Deferred.return error
        | Ok process ->
            let pid = Process.pid process in
            active_process_groups := pid :: !active_process_groups;
            Monitor.protect
              ~finally:(fun () ->
                unregister_process_group pid;
                Deferred.unit)
              (fun () ->
                let wait = Process.wait process in
                let overflow = Ivar.create () in
                let stdout =
                  read_bounded (Process.stdout process) ~stream:`Stdout
                    ~max_output_bytes ~overflow
                in
                let stderr =
                  read_bounded (Process.stderr process) ~stream:`Stderr
                    ~max_output_bytes ~overflow
                in
                let stdin_closed =
                  match stdin with
                  | None -> Writer.close (Process.stdin process)
                  | Some input ->
                      Writer.write (Process.stdin process) input;
                      Writer.close (Process.stdin process)
                in
                let completed =
                  let%map () = stdin_closed
                  and stdout = stdout
                  and stderr = stderr
                  and exit_status = wait in
                  Completed { stdout; stderr; exit_status }
                in
                let choices =
                  Option.value_map cancellation ~default:[] ~f:(fun token ->
                      [
                        Deferred.choice (Cancellation.requested token)
                          (fun () -> Cancelled);
                      ])
                  @ [
                      Deferred.choice completed Fn.id;
                      Deferred.choice (Ivar.read overflow) (fun stream ->
                          Output_limit_exceeded stream);
                      Deferred.choice (Clock_ns.after timeout) (fun () ->
                          Timed_out);
                    ]
                  @ Option.value_map delivered ~default:[] ~f:(fun delivered ->
                      [
                        Deferred.choice (Ivar.read delivered) (fun signal ->
                            Interrupted signal);
                      ])
                in
                let%bind completion = Deferred.choose choices in
                match completion with
                | Completed result -> Deferred.Or_error.return result
                | Output_limit_exceeded stream ->
                    let%map () = terminate_process_group process wait in
                    Or_error.errorf "%s %s exceeded %d bytes" prog
                      (match stream with
                      | `Stdout -> "stdout"
                      | `Stderr -> "stderr")
                      max_output_bytes
                | Timed_out ->
                    let%map () = terminate_process_group process wait in
                    Or_error.errorf "%s timed out after %s" prog
                      (Time_ns.Span.to_short_string timeout)
                | Interrupted signal ->
                    let%map () = terminate_process_group process wait in
                    interruption_error prog signal
                | Cancelled ->
                    ignore (Cancellation.acknowledge_current () : bool);
                    let%map () = terminate_process_group process wait in
                    cancellation_error prog))

let run ?working_directory ?stdin ?env ?ignore_termination ~timeout
    ~max_output_bytes ~prog ~args () =
  run_without_progress ?working_directory ?stdin ?env ?ignore_termination
    ~timeout ~max_output_bytes ~prog ~args ()

let run_stdout ?working_directory ?stdin ?env ?ignore_termination ~timeout
    ~max_output_bytes ~prog ~args () =
  let open Deferred.Or_error.Let_syntax in
  let%bind result =
    run ?working_directory ?stdin ?env ?ignore_termination ~timeout
      ~max_output_bytes ~prog ~args ()
  in
  match result.exit_status with
  | Ok () -> Deferred.Or_error.return result.stdout
  | Error failure ->
      Deferred.Or_error.errorf "%s failed (%s): %s" prog
        (Core_unix.Exit_or_signal.to_string_hum (Error failure))
        (String.strip result.stderr)

module For_testing = struct
  let should_force_termination = should_force_termination
end
