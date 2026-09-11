open Async
open Core

let project = Nixploy.Project_name.of_string "guard-test" |> Or_error.ok_exn
let target = Nixploy.Target_name.of_string "test" |> Or_error.ok_exn

let local_command directory argv =
  let%map.Deferred result =
    Nixploy.Process_runner.run_stdout ~working_directory:directory
      ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:4096
      ~prog:(List.hd_exn argv) ~args:(List.tl_exn argv) ()
  in
  Result.map result ~f:ignore

let child_mode () =
  match Array.to_list (Sys.get_argv ()) with
  | [ _; "hold-remote-guard"; directory; entered; finished ] ->
      Some
        (Nixploy.Mutation_guard.For_testing.with_mutation
           ~run:(local_command directory)
           ~interrupted:(fun () -> false)
           ~project ~target
           (fun () ->
             let open Deferred.Or_error.Let_syntax in
             let%bind _effect =
               Process.create ~prog:"sh"
                 ~args:
                   [
                     "-c";
                     "sleep 0.3; printf finished > \"$1\"";
                     "effect";
                     finished;
                   ]
                 ()
             in
             let%bind.Deferred () =
               Writer.save entered ~contents:"guard held"
             in
             Deferred.never ())
        >>| Or_error.ok_exn)
  | _ -> None

let rec wait_for_file path remaining =
  if Sys_unix.file_exists_exn path then Deferred.unit
  else if remaining = 0 then failwith ("timed out waiting for " ^ path)
  else
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
    wait_for_file path (remaining - 1)

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-guard-test-" "" in
  let trace = ref [] in
  let run argv =
    trace := !trace @ [ argv ];
    local_command directory argv
  in
  let guard ?(interrupted = fun () -> false) action =
    Nixploy.Mutation_guard.For_testing.with_mutation ~run ~interrupted ~project
      ~target action
  in
  let entered = Ivar.create () in
  let complete = Ivar.create () in
  let first =
    guard (fun () ->
        Ivar.fill_exn entered ();
        Ivar.read complete)
  in
  let%bind () = Ivar.read entered in
  assert (
    List.equal String.equal (List.last_exn !trace)
      [ "sync"; "-f"; ".nixploy-mutations" ]);
  let called = ref false in
  let%bind second =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error second);
  assert (not !called);
  Ivar.fill_exn complete (Ok ());
  let%bind first = first in
  Or_error.ok_exn first;
  let%bind released = guard (fun () -> Deferred.Or_error.return ()) in
  Or_error.ok_exn released;
  (* The owner reports transport loss while a previously started remote effect
     is still running. A new client cannot enter, even after that effect ends. *)
  let effect_finished = Ivar.create () in
  let%bind lost =
    guard (fun () ->
        don't_wait_for
          (let%map () = Clock_ns.after (Time_ns.Span.of_ms 50.) in
           Ivar.fill_exn effect_finished ());
        Deferred.Or_error.error_string "transport lost")
  in
  assert (Result.is_error lost);
  let%bind blocked =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error blocked);
  assert (not !called);
  let%bind () = Ivar.read effect_finished in
  let%bind still_blocked =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error still_blocked);
  assert (not !called);
  (* Explicit test-only reconciliation; production provides no takeover API. *)
  let key =
    Nixploy.Resource_key.derive_current ~project ~target |> Or_error.ok_exn
  in
  let evidence = ".nixploy-mutations/" ^ Nixploy.Resource_key.to_string key in
  let%bind reconciled = run [ "rmdir"; "--"; evidence ] in
  Or_error.ok_exn reconciled;
  trace := [];
  let%bind interrupted =
    guard ~interrupted:(fun () -> true) (fun () -> Deferred.Or_error.return ())
  in
  assert (Result.is_error interrupted);
  assert (
    not
      (List.exists !trace ~f:(fun argv ->
           String.equal (List.hd_exn argv) "rmdir")));
  let%bind reconciled = run [ "rmdir"; "--"; evidence ] in
  Or_error.ok_exn reconciled;
  let%bind raised = guard (fun () -> failwith "owner exception") in
  assert (Result.is_error raised);
  let%bind blocked =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error blocked);
  assert (not !called);
  let failed_sync argv =
    if String.equal (List.hd_exn argv) "sync" then
      Deferred.Or_error.error_string "sync failed"
    else Deferred.Or_error.return ()
  in
  let%bind failed =
    Nixploy.Mutation_guard.For_testing.with_mutation ~run:failed_sync
      ~interrupted:(fun () -> false)
      ~project ~target
      (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error failed);
  assert (not !called);
  let%bind reconciled = run [ "rmdir"; "--"; evidence ] in
  Or_error.ok_exn reconciled;
  let entered = Filename.concat directory "child-entered" in
  let finished = Filename.concat directory "orphan-effect-finished" in
  let%bind child =
    Process.create ~prog:Sys_unix.executable_name
      ~args:[ "hold-remote-guard"; directory; entered; finished ]
      ()
  in
  let child = Or_error.ok_exn child in
  let%bind () = wait_for_file entered 500 in
  let%bind concurrent =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error concurrent);
  Signal_unix.send_i Signal.kill (`Pid (Process.pid child));
  let%bind _ = Process.wait child in
  let%bind after_crash =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error after_crash);
  let%bind () = wait_for_file finished 500 in
  let%bind after_orphan_finished =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error after_orphan_finished);
  assert (not !called);
  let%bind reconciled = run [ "rmdir"; "--"; evidence ] in
  Or_error.ok_exn reconciled;
  let fail_evidence_sync argv =
    if List.equal String.equal argv [ "sync"; "-f"; ".nixploy-mutations" ] then
      Deferred.Or_error.error_string "evidence sync failed"
    else run argv
  in
  let%bind unsynced =
    Nixploy.Mutation_guard.For_testing.with_mutation ~run:fail_evidence_sync
      ~interrupted:(fun () -> false)
      ~project ~target
      (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error unsynced);
  let%bind blocked_after_sync_failure =
    guard (fun () ->
        called := true;
        Deferred.Or_error.return ())
  in
  assert (Result.is_error blocked_after_sync_failure);
  assert (not !called);
  printf
    "mutation guard: independent clients, SIGKILL with orphan effect, \
     contention, release, transport loss, interruption, exception, sync \
     failure passed\n\
     %!";
  Deferred.unit

let () =
  don't_wait_for
    (let%bind result =
       Monitor.try_with_or_error (fun () ->
           match child_mode () with Some child -> child | None -> run_tests ())
     in
     match result with
     | Ok () -> Shutdown.exit 0
     | Error error ->
         eprintf "%s\n%!" (Error.to_string_hum error);
         Shutdown.exit 1);
  never_returns (Scheduler.go ())
