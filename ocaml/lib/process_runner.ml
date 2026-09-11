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
let termination_seen = Atomic.make false

(* Register before dispatching spawn to a worker thread. Forced shutdown waits
   for in-flight spawns as well as already-running terminal clients. *)
let streaming_cleanups : (unit -> unit Deferred.t) list ref = ref []
let forcing_shutdown = ref false

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
          then (
            Atomic.set termination_seen true;
            Ivar.fill_exn state.delivered signal)
          else if not !forcing_shutdown then (
            forcing_shutdown := true;
            List.iter !active_process_groups ~f:(fun pid ->
                Signal_unix.send_i Signal.kill (`Group pid));
            don't_wait_for
              (let%map () =
                 Deferred.List.iter !streaming_cleanups ~how:`Parallel
                   ~f:(fun cleanup ->
                     Monitor.try_with cleanup >>| function
                     | Ok () -> ()
                     | Error _ ->
                         eprintf
                           "runbook terminal cleanup failed during forced \
                            shutdown\n\
                            %!")
               in
               Shutdown.shutdown_with_signal_exn signal)))

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

type output_budget = { maximum : int; mutable captured_bytes : int }

let can_capture budget length = length <= budget.maximum - budget.captured_bytes

let capture budget buffer string =
  budget.captured_bytes <- budget.captured_bytes + String.length string;
  Buffer.add_string buffer string

let report_overflow overflow stream =
  if Ivar.is_empty overflow then Ivar.fill_exn overflow stream

let read_bounded reader ~stream ~budget ~overflow =
  let buffer = Buffer.create (Int.min budget.maximum 65_536) in
  let%bind result =
    Reader.read_one_chunk_at_a_time reader ~handle_chunk:(fun chunk ~pos ~len ->
        if not (can_capture budget len) then (
          report_overflow overflow stream;
          Deferred.return (`Stop ()))
        else (
          capture budget buffer (Bigstring.to_string chunk ~pos ~len);
          Deferred.return `Continue))
  in
  let%map () = Reader.close reader in
  match result with
  | `Eof | `Stopped () -> Buffer.contents buffer
  | `Eof_with_unconsumed_data remaining ->
      if can_capture budget (String.length remaining) then
        capture budget buffer remaining
      else report_overflow overflow stream;
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
                let budget =
                  { maximum = max_output_bytes; captured_bytes = 0 }
                in
                let stdout =
                  read_bounded (Process.stdout process) ~stream:`Stdout ~budget
                    ~overflow
                in
                let stderr =
                  read_bounded (Process.stderr process) ~stream:`Stderr ~budget
                    ~overflow
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

let terminal_attached () =
  In_thread.run (fun () ->
      Core_unix.isatty Core_unix.stdin && Core_unix.isatty Core_unix.stdout)

external terminal_foreground_group : Core_unix.File_descr.t -> int
  = "nixploy_terminal_foreground_group"

external terminal_set_foreground_group : Core_unix.File_descr.t -> int -> unit
  = "nixploy_terminal_set_foreground_group"

let restore_streaming_terminal terminal =
  Option.iter terminal ~f:(fun (state, group) ->
      terminal_set_foreground_group Core_unix.stdin group;
      Core_unix.Terminal_io.tcsetattr state Core_unix.stdin ~mode:TCSANOW)

let streaming_interruption ~cancelled ~before_exec =
  if cancelled () then ignore (Cancellation.acknowledge_current () : bool);
  if before_exec then Or_error.error_string "runbook interrupted before exec"
  else
    Or_error.error_string
      "runbook interrupted: remote command may still be running; do not retry \
       automatically"

let streaming_completion ~stopped ~cancelled completion =
  match completion with
  | `Completed status when not (stopped ()) -> Ok status
  | `Completed _ | `Interrupted ->
      streaming_interruption ~cancelled ~before_exec:false

let run_streaming ~interactive ~prog ~args () =
  let open Deferred.Or_error.Let_syntax in
  handle_termination_signals ();
  let%bind attached = terminal_attached () |> Deferred.ok in
  let%bind () =
    Deferred.return
      (if interactive && not attached then
         Or_error.error_string
           "runbook interactive command requires attached stdin and stdout \
            terminals"
       else Ok ())
  in
  let cancellation = Cancellation.current () in
  let cancelled () = Option.exists cancellation ~f:Cancellation.was_requested in
  let stopped () = Atomic.get termination_seen || cancelled () in
  let interruption_choices =
    Deferred.choice (termination_requested ()) (fun _ -> `Interrupted)
    :: Option.value_map cancellation ~default:[] ~f:(fun token ->
        [
          Deferred.choice (Cancellation.requested token) (fun () ->
              `Interrupted);
        ])
  in
  let%bind () =
    if stopped () then
      Deferred.return (streaming_interruption ~cancelled ~before_exec:true)
    else
      let flushed =
        Deferred.all_unit
          [
            Writer.flushed (Lazy.force Writer.stdout);
            Writer.flushed (Lazy.force Writer.stderr);
          ]
      in
      let%bind ready =
        Deferred.choose
          (Deferred.choice flushed (fun () -> `Flushed) :: interruption_choices)
        |> Deferred.ok
      in
      if stopped () || Poly.equal ready `Interrupted then
        Deferred.return (streaming_interruption ~cancelled ~before_exec:true)
      else Deferred.Or_error.return ()
  in
  (* The registration covers the thread-dispatch window too: a second signal
     cannot exit the parent while an unregistered child is being created. *)
  let cleanup_ready = Ivar.create () in
  let cleanup () = Deferred.bind (Ivar.read cleanup_ready) ~f:Lazy.force in
  streaming_cleanups := cleanup :: !streaming_cleanups;
  let%bind result =
    Monitor.protect
      ~finally:(fun () ->
        Deferred.map (cleanup ()) ~f:(fun () ->
            streaming_cleanups :=
              List.filter !streaming_cleanups ~f:(fun entry ->
                  not (phys_equal entry cleanup))))
      (fun () ->
        let%bind created =
          In_thread.run (fun () ->
              Or_error.try_with (fun () ->
                  let terminal =
                    if interactive then (
                      let group = terminal_foreground_group Core_unix.stdin in
                      if
                        not
                          (Option.exists
                             (Core_unix.getpgid (Core_unix.getpid ()))
                             ~f:(fun own -> Pid.to_int own = group))
                      then
                        failwith
                          "runbook requires foreground terminal ownership";
                      Some
                        (Core_unix.Terminal_io.tcgetattr Core_unix.stdin, group))
                    else None
                  in
                  let stdin =
                    if interactive then Core_unix.stdin
                    else
                      Core_unix.openfile "/dev/null"
                        ~mode:[ Core_unix.O_RDONLY ]
                  in
                  Exn.protect
                    ~finally:(fun () ->
                      if not interactive then Core_unix.close stdin)
                    ~f:(fun () ->
                      (* No Async operations between this last check and spawn. *)
                      if stopped () then None
                      else
                        let process =
                          Core_unix.create_process_with_fds ~prog ~args
                            ~setpgid:Core_unix.Pgid.new_process_group
                            ~stdin:(Use_this stdin)
                            ~stdout:(Use_this Core_unix.stdout)
                            ~stderr:(Use_this Core_unix.stderr) ()
                        in
                        let handoff =
                          Or_error.try_with (fun () ->
                              if interactive then (
                                terminal_set_foreground_group Core_unix.stdin
                                  (Pid.to_int process.pid);
                                (* A fast child may have stopped on SIGTTIN/SIGTTOU before
                         foreground handoff. Resume only our owned group. *)
                                Signal_unix.send_i Signal.cont
                                  (`Group process.pid)))
                        in
                        Some (process.pid, terminal, handoff))))
          |> Deferred.ok
        in
        match created with
        | Error _ | Ok None ->
            Ivar.fill_exn cleanup_ready (lazy Deferred.unit);
            if stopped () then
              Deferred.return
                (streaming_interruption ~cancelled ~before_exec:true)
            else
              Deferred.Or_error.error_string
                "runbook could not start local exec client"
        | Ok (Some (pid, terminal, handoff)) -> (
            let wait = Async.Unix.waitpid pid in
            let cleanup =
              lazy
                (Signal_unix.send_i Signal.kill (`Group pid);
                 In_thread.run (fun () -> restore_streaming_terminal terminal))
            in
            Ivar.fill_exn cleanup_ready cleanup;
            let%bind () =
              match handoff with
              | Ok () -> Deferred.Or_error.return ()
              | Error _ ->
                  let%bind () = Lazy.force cleanup |> Deferred.ok in
                  let%bind _ = wait |> Deferred.ok in
                  Deferred.Or_error.error_string
                    "runbook could not hand off the terminal; remote outcome \
                     may be unknown"
            in
            let%bind completion =
              Deferred.choose
                (Deferred.choice wait (fun status -> `Completed status)
                :: interruption_choices)
              |> Deferred.ok
            in
            let result = streaming_completion ~stopped ~cancelled completion in
            match result with
            | Ok _ -> Deferred.return result
            | Error _ ->
                Signal_unix.send_i Signal.term (`Group pid);
                (* Leader exit is not group exit. Descendants get the same bounded
                 grace and are killed even when the leader has already exited. *)
                let%bind () = Clock_ns.after termination_grace |> Deferred.ok in
                let%bind () = Lazy.force cleanup |> Deferred.ok in
                let%bind _ = wait |> Deferred.ok in
                Deferred.return result))
    |> Deferred.ok
  in
  match result with
  | Error _ -> Deferred.return result
  | Ok status ->
      (* Restoring the terminal yields too; a signal delivered during cleanup
         must not turn a completed wait into a falsely certain success. *)
      Deferred.return
        (streaming_completion ~stopped ~cancelled (`Completed status))

module For_testing = struct
  let should_force_termination = should_force_termination

  let streaming_completed ~interrupted status =
    let cancelled () =
      Option.exists (Cancellation.current ()) ~f:Cancellation.was_requested
    in
    streaming_completion
      ~stopped:(fun () -> interrupted || cancelled ())
      ~cancelled (`Completed status)
end
