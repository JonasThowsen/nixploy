open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let target = Nixploy.Target_name.of_string "staging" |> assert_ok

let commit =
  Nixploy.Source.For_testing.commit
    ~revision:"0123456789abcdef0123456789abcdef01234567"
    ~subject:"Crash recovery test" ~timestamp_ms:1_700_000_000_000L
  |> assert_ok

let child_mode () =
  match Array.to_list (Sys.get_argv ()) with
  | _ :: "hold-scope-lease" :: database :: working_directory :: marker :: _ ->
      Some
        (let open Deferred.Let_syntax in
         let%bind store = Nixploy.Store.open_ ~path:database in
         Nixploy.Store.with_lease (assert_ok store) ~working_directory ~target
           (fun _lease ->
             let%bind deployment =
               Nixploy.Store.request (assert_ok store)
                 ~application_key:(Some "managed-app") ~working_directory
                 ~target ~commit
             in
             let deployment = assert_ok deployment in
             let%bind staged =
               Nixploy.Store.record_stage (assert_ok store)
                 ~id:(Nixploy.Store.id deployment)
                 ~stage:Nixploy.Deployment.Building
                 ~message:"Building and loading the image"
             in
             assert_ok staged;
             Out_channel.write_all marker ~data:(Nixploy.Store.id deployment);
             Deferred.never ())
         >>| ignore)
  | _ -> None

let rec wait_for_file path attempts =
  if Sys_unix.file_exists_exn path then Deferred.unit
  else if attempts = 0 then failwith "lease holder did not become ready"
  else
    let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
    wait_for_file path (attempts - 1)

let set_prior_error database deployment_id =
  let db = Sqlite3.db_open database in
  let statement =
    Sqlite3.prepare db "UPDATE deployments SET error = ? WHERE id = ?"
  in
  assert (
    phys_equal
      (Sqlite3.bind_values statement
         [
           Sqlite3.Data.TEXT "prior diagnostic evidence";
           Sqlite3.Data.TEXT deployment_id;
         ])
      Sqlite3.Rc.OK);
  assert (phys_equal (Sqlite3.step statement) Sqlite3.Rc.DONE);
  ignore (Sqlite3.finalize statement : Sqlite3.Rc.t);
  assert (Sqlite3.db_close db)

let interrupted_event_count database deployment_id =
  let db = Sqlite3.db_open database in
  let statement =
    Sqlite3.prepare db
      "SELECT COUNT(*) FROM deployment_events WHERE deployment_id = ? AND \
       stage = 'interrupted'"
  in
  assert (
    phys_equal
      (Sqlite3.bind_values statement [ Sqlite3.Data.TEXT deployment_id ])
      Sqlite3.Rc.OK);
  let count =
    match Sqlite3.step statement with
    | ROW -> Sqlite3.column_int statement 0
    | result ->
        failwithf "count interrupted events: %s"
          (Sqlite3.Rc.to_string result)
          ()
  in
  ignore (Sqlite3.finalize statement : Sqlite3.Rc.t);
  assert (Sqlite3.db_close db);
  count

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-crash-recovery-test-" "" in
  let database = Filename.concat directory "state.sqlite" in
  let marker = Filename.concat directory "lease-ready" in
  let working_directory = Filename_unix.realpath directory in
  let unrelated_directory =
    Filename_unix.temp_dir "nixploy-unrelated-scope-" ""
  in
  let cleanup () =
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm"
      ~args:[ "-rf"; "--"; directory; unrelated_directory ]
      ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let%bind opened = Nixploy.Store.open_ ~path:database in
      let store = assert_ok opened in
      let%bind local_cli_deployment =
        Nixploy.Store.request store ~application_key:None ~working_directory
          ~target ~commit
      in
      let local_cli_deployment = assert_ok local_cli_deployment in
      let%bind other_application =
        Nixploy.Store.request store ~application_key:(Some "other-app")
          ~working_directory ~target ~commit
      in
      let other_application = assert_ok other_application in
      let%bind unrelated_scope =
        Nixploy.Store.request store ~application_key:(Some "managed-app")
          ~working_directory:unrelated_directory ~target ~commit
      in
      let unrelated_scope = assert_ok unrelated_scope in
      let%bind child =
        Process.create ~prog:Sys_unix.executable_name
          ~args:[ "hold-scope-lease"; database; working_directory; marker ]
          ()
      in
      let child = assert_ok child in
      let child_wait = Process.wait child in
      let%bind () = wait_for_file marker 200 in
      let interrupted_id = In_channel.read_all marker in
      set_prior_error database interrupted_id;
      let recovery_entered = Ivar.create () in
      let recovered =
        Nixploy.Store.with_lease store ~working_directory ~target (fun lease ->
            Ivar.fill_if_empty recovery_entered ();
            let open Deferred.Or_error.Let_syntax in
            let%bind () =
              Nixploy.Store.reconcile_interrupted_within_lease lease
                ~application_key:(Some "managed-app")
            in
            let%bind () =
              Nixploy.Store.reconcile_interrupted_within_lease lease
                ~application_key:(Some "managed-app")
            in
            let%map deployment =
              Nixploy.Store.request store ~application_key:(Some "managed-app")
                ~working_directory ~target ~commit
            in
            deployment)
      in
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 75.) in
      assert (not (Deferred.is_determined recovered));
      assert (Ivar.is_empty recovery_entered);
      Signal_unix.send_i Signal.kill (`Pid (Process.pid child));
      let%bind _ = child_wait in
      let%bind recovered = recovered in
      let new_deployment = assert_ok recovered in
      assert (not (Ivar.is_empty recovery_entered));
      assert (
        Nixploy.Store.equal_state (Nixploy.Store.state new_deployment) Requested);
      let%bind interrupted = Nixploy.Store.find store ~id:interrupted_id in
      let interrupted = assert_ok interrupted |> Option.value_exn in
      assert (Nixploy.Store.equal_state (Nixploy.Store.state interrupted) Failed);
      assert (String.equal (Nixploy.Store.stage interrupted) "building");
      assert (
        Option.equal String.equal
          (Nixploy.Store.revision interrupted)
          (Some "0123456789abcdef0123456789abcdef01234567"));
      let error = Nixploy.Store.error interrupted |> Option.value_exn in
      assert (String.is_substring error ~substring:"prior diagnostic evidence");
      assert (String.is_substring error ~substring:"remote outcome is unknown");
      assert (
        String.is_substring
          (Nixploy.Store.message interrupted)
          ~substring:"remote outcome is unknown");
      [%test_eq: int] 1 (interrupted_event_count database interrupted_id);
      let%bind local_cli_deployment =
        Nixploy.Store.find store ~id:(Nixploy.Store.id local_cli_deployment)
      in
      let local_cli_deployment =
        assert_ok local_cli_deployment |> Option.value_exn
      in
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state local_cli_deployment)
          Failed);
      [%test_eq: int] 1
        (interrupted_event_count database
           (Nixploy.Store.id local_cli_deployment));
      let%bind other_application =
        Nixploy.Store.find store ~id:(Nixploy.Store.id other_application)
      in
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state
             (assert_ok other_application |> Option.value_exn))
          Requested);
      let%bind unrelated_scope =
        Nixploy.Store.find store ~id:(Nixploy.Store.id unrelated_scope)
      in
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state (assert_ok unrelated_scope |> Option.value_exn))
          Requested);
      let%bind local_recovery =
        Nixploy.Store.with_lease store ~working_directory ~target (fun lease ->
            Nixploy.Store.reconcile_interrupted_within_lease lease
              ~application_key:None)
      in
      assert_ok local_recovery;
      let%map new_deployment =
        Nixploy.Store.find store ~id:(Nixploy.Store.id new_deployment)
      in
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state (assert_ok new_deployment |> Option.value_exn))
          Requested))

let run deferred =
  don't_wait_for
    ( Monitor.try_with (fun () -> deferred) >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())

let () =
  match child_mode () with
  | Some child -> run child
  | None -> run (run_tests ())
