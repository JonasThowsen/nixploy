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
  | _ -> None

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
  (match success.exit_status with Ok () -> () | Error _ -> assert false);
  let%bind overflow =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-overflow" ] ()
  in
  assert (Result.is_error overflow);
  let%bind timed_out =
    Nixploy.Process_runner.run ~timeout:(Time_ns.Span.of_ms 50.)
      ~max_output_bytes:1024 ~prog:executable ~args:[ "child-timeout" ] ()
  in
  assert (Result.is_error timed_out);
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
