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
  | _ :: "child-combined-overflow" :: _ ->
      Out_channel.output_string stdout (String.make 768 'x');
      Out_channel.output_string stderr (String.make 768 'y');
      Out_channel.flush stdout;
      Out_channel.flush stderr;
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

let run_tests () =
  let open Deferred.Let_syntax in
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
  let%bind overflow =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-overflow" ] ()
  in
  assert (Result.is_error overflow);
  let%bind combined_overflow =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable
      ~args:[ "child-combined-overflow" ] ()
  in
  assert (Result.is_error combined_overflow);
  let%bind timed_out =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_ms 50.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-timeout" ] ()
  in
  assert (Result.is_error timed_out);
  let marker = Filename_unix.temp_file "nixploy-cancel-test-" ".ready" in
  Core_unix.unlink marker;
  let cancellation = Nixploy.Cancellation.create () in
  let running =
    Nixploy.Cancellation.within cancellation (fun () ->
        Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 10.)
          ~max_output_bytes:1024 ~prog:executable
          ~args:[ "child-cancel"; marker ] ())
  in
  let%bind () = wait_for_file marker 100 in
  let descendant = In_channel.read_all marker |> Int.of_string in
  assert (
    [%equal: Nixploy.Cancellation.request]
      (Nixploy.Cancellation.request cancellation)
      Accepted);
  let%bind cancelled = running in
  assert (Result.is_error cancelled);
  assert (Nixploy.Cancellation.was_acknowledged cancellation);
  let%bind () = wait_for_process_exit descendant 100 in
  Core_unix.unlink marker;
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
  let signal_marker = Filename_unix.temp_file "nixploy-signal-test-" ".ready" in
  Core_unix.unlink signal_marker;
  Nixploy.Process_runner.handle_termination_signals ();
  let interrupted =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 10.)
      ~max_output_bytes:1024 ~prog:executable
      ~args:[ "child-cancel"; signal_marker ]
      ()
  in
  let%bind () = wait_for_file signal_marker 100 in
  let signal_descendant = In_channel.read_all signal_marker |> Int.of_string in
  Signal_unix.send_i Signal.int (`Pid (Core_unix.getpid ()));
  let%bind interrupted = interrupted in
  assert (Result.is_error interrupted);
  assert (
    Result.error interrupted |> Option.value_exn |> Error.to_string_hum
    |> String.is_substring ~substring:"interrupted by sigint");
  let%bind () = wait_for_process_exit signal_descendant 100 in
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
  Core_unix.unlink signal_marker;
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
