open Async
open Core

let fail error = failwith (Error.to_string_hum error)

let child_mode () =
  match Array.to_list (Sys.get_argv ()) with
  | _ :: "child-success" :: _ ->
      Out_channel.output_string stdout "hello";
      Out_channel.output_string stderr "diagnostic";
      Out_channel.flush stdout;
      Out_channel.flush stderr;
      Some 0
  | _ :: "child-overflow" :: _ ->
      Out_channel.output_string stdout (String.make 4096 'x');
      Out_channel.flush stdout;
      Some 0
  | _ :: "child-timeout" :: _ ->
      Core_unix.sleep 10;
      Some 0
  | _ :: "child-cancel" :: marker :: _ ->
      let descendant = Caml_unix.fork () in
      if descendant = 0 then (
        Stdlib.Sys.set_signal Stdlib.Sys.sigterm Stdlib.Sys.Signal_ignore;
        Core_unix.sleep 10;
        Some 0)
      else (
        Out_channel.write_all marker ~data:(Int.to_string descendant);
        Core_unix.sleep 10;
        Some 0)
  | _ -> None

let rec wait_for_file path attempts =
  if Sys_unix.file_exists_exn path then Deferred.unit
  else if attempts = 0 then failwith "cancel test child did not start"
  else
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
    wait_for_file path (attempts - 1)

let process_exists pid =
  try
    Caml_unix.kill pid 0;
    true
  with Caml_unix.Unix_error (Caml_unix.ESRCH, _, _) -> false

let rec wait_for_process_exit pid attempts =
  if not (process_exists pid) then Deferred.unit
  else if attempts = 0 then failwith "cancel test left a descendant running"
  else
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
    wait_for_process_exit pid (attempts - 1)

let require_prompt_completion deferred =
  let open Deferred.Let_syntax in
  let%bind completion =
    Deferred.choose
      [
        Deferred.choice deferred (fun value -> `Completed value);
        Deferred.choice
          (Clock_ns.after (Time_ns.Span.of_sec 4.))
          (fun () -> `Timed_out);
      ]
  in
  match completion with
  | `Completed value -> Deferred.return value
  | `Timed_out -> failwith "progress observer delayed terminal process cleanup"

let test_progress_observers_do_not_own_operation_liveness () =
  let open Deferred.Let_syntax in
  let completion = Ivar.create () in
  let callback_started = Ivar.create () in
  let blocked_callbacks = ref 0 in
  let blocked_observer =
    Nixploy.Process_runner.For_testing.with_progress_heartbeats
      ~interval:(Time_ns.Span.of_ms 5.) ~max_heartbeats:3
      ~on_heartbeat:(fun _ ->
        Int.incr blocked_callbacks;
        Ivar.fill_if_empty callback_started ();
        Deferred.never ())
      (fun () -> Ivar.read completion)
  in
  let%bind () = Ivar.read callback_started in
  Ivar.fill_exn completion "completed";
  let%bind result = require_prompt_completion blocked_observer in
  [%test_eq: string] "completed" result;
  let callbacks_at_terminal = !blocked_callbacks in
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 25.) in
  [%test_eq: int] callbacks_at_terminal !blocked_callbacks;

  let callback_errors = ref 0 in
  let exceptional_observer =
    Nixploy.Process_runner.For_testing.with_progress_heartbeats
      ~interval:(Time_ns.Span.of_ms 5.) ~max_heartbeats:3
      ~on_heartbeat:(fun _ ->
        Int.incr callback_errors;
        raise_s [%message "progress observer failure"])
      (fun () -> Clock_ns.after (Time_ns.Span.of_ms 20.))
  in
  let%bind () = require_prompt_completion exceptional_observer in
  assert (!callback_errors > 0);

  let delayed_callbacks = ref 0 in
  let delayed_observer =
    Nixploy.Process_runner.For_testing.with_progress_heartbeats
      ~interval:(Time_ns.Span.of_ms 20.) ~max_heartbeats:3
      ~on_heartbeat:(fun _ ->
        Int.incr delayed_callbacks;
        Deferred.unit)
      (fun () -> Deferred.unit)
  in
  let%bind () = require_prompt_completion delayed_observer in
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 30.) in
  [%test_eq: int] 0 !delayed_callbacks;
  Deferred.unit

let run_tests () =
  let open Deferred.Let_syntax in
  let%bind () = test_progress_observers_do_not_own_operation_liveness () in
  let executable = Sys_unix.executable_name in
  let%bind success =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-success" ] ()
  in
  let success =
    match success with Ok result -> result | Error error -> fail error
  in
  assert (String.equal success.stdout "hello");
  assert (String.equal success.stderr "diagnostic");
  (match success.exit_status with Ok () -> () | Error _ -> assert false);
  let%bind overflow =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-overflow" ] ()
  in
  assert (Result.is_error overflow);
  let timed_out =
    Nixploy.Process_runner.For_testing.with_progress_heartbeats
      ~interval:(Time_ns.Span.of_ms 5.) ~max_heartbeats:3
      ~on_heartbeat:(fun _ -> Deferred.never ())
      (fun () ->
        Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_ms 50.)
          ~max_output_bytes:1024 ~prog:executable ~args:[ "child-timeout" ] ())
  in
  let%bind timed_out = require_prompt_completion timed_out in
  assert (Result.is_error timed_out);
  let scoped_marker =
    Filename_unix.temp_file "nixploy-scoped-cancel-" ".ready"
  in
  Core_unix.unlink scoped_marker;
  let cancellation = Nixploy.Cancellation.create () in
  let scoped =
    Nixploy.Cancellation.within cancellation (fun () ->
        Nixploy.Process_runner.For_testing.with_progress_heartbeats
          ~interval:(Time_ns.Span.of_ms 5.) ~max_heartbeats:3
          ~on_heartbeat:(fun _ -> Deferred.never ())
          (fun () ->
            Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 10.)
              ~max_output_bytes:1024 ~prog:executable
              ~args:[ "child-cancel"; scoped_marker ]
              ()))
  in
  let%bind () = wait_for_file scoped_marker 100 in
  let scoped_descendant = In_channel.read_all scoped_marker |> Int.of_string in
  assert (
    [%equal: Nixploy.Cancellation.request]
      (Nixploy.Cancellation.request cancellation)
      Accepted);
  let%bind scoped = require_prompt_completion scoped in
  (match scoped with
  | Ok _ -> failwith "scoped cancellation completed successfully"
  | Error error ->
      assert (
        String.is_substring (Error.to_string_hum error) ~substring:"cancelled"));
  assert (Nixploy.Cancellation.was_acknowledged cancellation);
  let%bind () = wait_for_process_exit scoped_descendant 100 in
  let%bind unaffected =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-success" ] ()
  in
  assert (Result.is_ok unaffected);
  Core_unix.unlink scoped_marker;
  let committed = Nixploy.Cancellation.create () in
  assert (
    [%equal: Nixploy.Cancellation.commit]
      (Nixploy.Cancellation.within committed (fun () ->
           Nixploy.Cancellation.commit_current ()))
      Continue);
  assert (
    [%equal: Nixploy.Cancellation.request]
      (Nixploy.Cancellation.request committed)
      Too_late);
  let marker = Filename_unix.temp_file "nixploy-cancel-test-" ".ready" in
  Core_unix.unlink marker;
  Nixploy.Process_runner.handle_termination_signals ();
  let cancelled =
    Nixploy.Process_runner.For_testing.with_progress_heartbeats
      ~interval:(Time_ns.Span.of_ms 5.) ~max_heartbeats:3
      ~on_heartbeat:(fun _ -> Deferred.never ())
      (fun () ->
        Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 10.)
          ~max_output_bytes:1024 ~prog:executable
          ~args:[ "child-cancel"; marker ] ())
  in
  let%bind () = wait_for_file marker 100 in
  let descendant = In_channel.read_all marker |> Int.of_string in
  Signal_unix.send_i Signal.int (`Pid (Core_unix.getpid ()));
  let%bind cancelled = require_prompt_completion cancelled in
  (match cancelled with
  | Ok _ -> failwith "cancelled process completed successfully"
  | Error error ->
      assert (
        String.is_substring
          (Error.to_string_hum error)
          ~substring:"interrupted by sigint"));
  let%bind () = wait_for_process_exit descendant 100 in
  let%bind retry =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-success" ] ()
  in
  assert (Result.is_error retry);
  let%bind cleanup =
    Nixploy.Process_runner.run ~ignore_termination:true
      ~timeout:(Time_ns.Span.of_sec 5.) ~max_output_bytes:1024 ~prog:executable
      ~args:[ "child-success" ] ()
  in
  assert (Result.is_ok cleanup);
  Core_unix.unlink marker;
  Deferred.unit

let () =
  match child_mode () with
  | Some status -> Stdlib.exit status
  | None ->
      don't_wait_for
        ( Monitor.try_with run_tests >>| function
          | Ok () -> Shutdown.shutdown 0
          | Error error ->
              eprintf "%s\n" (Exn.to_string error);
              Shutdown.shutdown 1 );
      never_returns (Scheduler.go ())
