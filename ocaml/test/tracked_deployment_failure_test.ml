open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let write path contents = Out_channel.write_all path ~data:contents

let install_executable directory name contents =
  let path = Filename.concat directory name in
  write path contents;
  Caml_unix.chmod path 0o755

let set_or_unset name = function
  | Some value -> Caml_unix.putenv name value
  | None -> Core_unix.unsetenv name

let run_git ?working_directory args =
  Nixploy.Process_runner.run_stdout ?working_directory
    ~timeout:(Time_ns.Span.of_sec 10.) ~max_output_bytes:65_536 ~prog:"git"
    ~args ()
  >>| assert_ok

let wait_for_file path =
  let rec loop attempts =
    if Sys_unix.file_exists_exn path then Deferred.unit
    else if attempts = 0 then failwithf "timed out waiting for %s" path ()
    else
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 20.) in
      loop (attempts - 1)
  in
  loop 250

let durable_event_stages path ~deployment_id =
  let db = Sqlite3.db_open path in
  Exn.protect
    ~f:(fun () ->
      let statement =
        Sqlite3.prepare db
          "SELECT stage FROM deployment_events WHERE deployment_id = ? ORDER \
           BY id"
      in
      Exn.protect
        ~f:(fun () ->
          assert (
            phys_equal
              (Sqlite3.bind_values statement
                 [ Sqlite3.Data.TEXT deployment_id ])
              Sqlite3.Rc.OK);
          let rec collect stages =
            match Sqlite3.step statement with
            | Sqlite3.Rc.ROW ->
                collect (Sqlite3.column_text statement 0 :: stages)
            | DONE -> List.rev stages
            | code -> failwith (Sqlite3.Rc.to_string code)
          in
          collect [])
        ~finally:(fun () -> ignore (Sqlite3.finalize statement : Sqlite3.Rc.t)))
    ~finally:(fun () -> assert (Sqlite3.db_close db))

let resource_state_row_count path =
  let db = Sqlite3.db_open path in
  Exn.protect
    ~f:(fun () ->
      let statement =
        Sqlite3.prepare db "SELECT COUNT(*) FROM resource_states"
      in
      Exn.protect
        ~f:(fun () ->
          assert (phys_equal (Sqlite3.step statement) Sqlite3.Rc.ROW);
          Sqlite3.column_int statement 0)
        ~finally:(fun () -> ignore (Sqlite3.finalize statement : Sqlite3.Rc.t)))
    ~finally:(fun () -> assert (Sqlite3.db_close db))

let install_trigger path sql =
  let db = Sqlite3.db_open path in
  Exn.protect
    ~f:(fun () ->
      let result = Sqlite3.exec db sql in
      if not (phys_equal result Sqlite3.Rc.OK) then failwith (Sqlite3.errmsg db))
    ~finally:(fun () -> assert (Sqlite3.db_close db))

let expect_error_containing result text =
  match result with
  | Ok _ -> failwith "operation unexpectedly succeeded"
  | Error error ->
      assert (String.is_substring (Error.to_string_hum error) ~substring:text)

let trace_lines path =
  if Sys_unix.file_exists_exn path then In_channel.read_lines path else []

let assert_process_is_reaped pid =
  assert (not (Sys_unix.file_exists_exn ("/proc/" ^ pid)))

let assert_only_one_terminal_event stages =
  let terminal =
    List.count stages ~f:(fun stage ->
        List.mem
          [ "succeeded"; "failed"; "cancelled" ]
          stage ~equal:String.equal)
  in
  assert (Int.equal terminal 1);
  assert (
    match List.last stages with
    | Some ("succeeded" | "failed" | "cancelled") -> true
    | Some _ | None -> false)

let assert_lease_reusable store ~working_directory ~target ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind reusable =
    Nixploy.Store.with_reconciled_lease store ~application_key:None
      ~working_directory ~target (fun () ->
        let%bind operation =
          Nixploy.Store.request store ~application_key:None ~working_directory
            ~target ~commit
        in
        let%map () =
          Nixploy.Store.fail store
            ~id:(Nixploy.Store.id operation)
            ~error:(Error.of_string "benign lease reuse")
        in
        ())
  in
  Deferred.Or_error.return reusable

let run_tests () =
  let open Deferred.Let_syntax in
  let root = Filename_unix.temp_dir "nixploy-tracked-deployment-failure-" "" in
  let repository = Filename.concat root "repository" in
  let bin = Filename.concat root "bin" in
  let trace = Filename.concat root "trace" in
  let leader_pid = Filename.concat root "build-leader.pid" in
  let child_pid = Filename.concat root "build-child.pid" in
  let delayed_marker = Filename.concat root "build-delayed-marker" in
  Core_unix.mkdir repository;
  Core_unix.mkdir bin;
  install_executable bin "nix"
    {|#!/bin/sh
set -eu
case "$1" in
  eval)
    printf '%s\n' '{"__schema":"v0.3","project":"sample","targets":{"worker":{"image":"workerImage","ip":"worker.invalid","nonProduction":{"coordinationScope":"test-worker"}}}}'
    ;;
  build)
    printf '%s\n' "$$" > "$NIXPLOY_TEST_BUILD_LEADER_PID"
    (
      trap '' TERM
      sleep 35
      : > "$NIXPLOY_TEST_BUILD_DELAYED_MARKER"
    ) &
    printf '%s\n' "$!" > "$NIXPLOY_TEST_BUILD_CHILD_PID"
    trap '' TERM
    while :; do sleep 1 & wait "$!"; done
    ;;
  *) exit 97 ;;
esac
|};
  install_executable bin "podman"
    {|#!/bin/sh
set -eu
printf 'podman|%s\n' "$*" >> "$NIXPLOY_TEST_TRACE"
case "$*" in
  "ps "*|"ps"*) printf '[]\n' ;;
  "system connection list --format json") printf '[]\n' ;;
  system\ connection\ add\ *) : ;;
  "--connection "*" info") : ;;
  *) echo "unexpected podman command: $*" >&2; exit 98 ;;
esac
|};
  install_executable bin "ssh"
    {|#!/bin/sh
set -eu
printf 'ssh|%s\n' "$*" >> "$NIXPLOY_TEST_TRACE"
case "$*" in *"'podman' 'ps'"*) printf '[]\n' ;; esac
exit 0
|};
  let environment_names =
    [
      "PATH";
      "NIXPLOY_TEST_TRACE";
      "NIXPLOY_TEST_BUILD_LEADER_PID";
      "NIXPLOY_TEST_BUILD_CHILD_PID";
      "NIXPLOY_TEST_BUILD_DELAYED_MARKER";
    ]
  in
  let old_environment =
    List.map environment_names ~f:(fun name -> (name, Sys.getenv name))
  in
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH");
  Caml_unix.putenv "NIXPLOY_TEST_TRACE" trace;
  Caml_unix.putenv "NIXPLOY_TEST_BUILD_LEADER_PID" leader_pid;
  Caml_unix.putenv "NIXPLOY_TEST_BUILD_CHILD_PID" child_pid;
  Caml_unix.putenv "NIXPLOY_TEST_BUILD_DELAYED_MARKER" delayed_marker;
  let clear_process_observations () =
    List.iter [ trace; leader_pid; child_pid; delayed_marker ] ~f:(fun path ->
        if Sys_unix.file_exists_exn path then Core_unix.unlink path)
  in
  let cleanup () =
    List.iter old_environment ~f:(fun (name, value) -> set_or_unset name value);
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; root ] ()
    >>| fun _ -> ()
  in
  Monitor.protect ~finally:cleanup (fun () ->
      let%bind _ = run_git [ "init"; "-b"; "main"; repository ] in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "user.email"; "test@nixploy" ]
      in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "user.name"; "Nixploy Test" ]
      in
      let%bind _ =
        run_git ~working_directory:repository
          [ "config"; "remote.origin.url"; "git@example.invalid:test.git" ]
      in
      write (Filename.concat repository "flake.nix") "{ outputs = _: {}; }\n";
      write (Filename.concat repository "flake.lock") "{}\n";
      let%bind _ = run_git ~working_directory:repository [ "add"; "." ] in
      let%bind _ =
        run_git ~working_directory:repository [ "commit"; "-m"; "Test" ]
      in
      let%bind commit =
        Nixploy.Source.preview_main ~working_directory:repository
      in
      let commit = assert_ok commit in
      let target = Nixploy.Target_name.of_string "worker" |> assert_ok in
      let authorization () =
        let receipts =
          Nixploy.Operation_receipt.create_deploy_store () |> assert_ok
        in
        let receipt =
          Nixploy.Operation_receipt.issue_deploy receipts ~application_key:None
            ~expected_project:None ~intent:None ~application:None
            ~managed_applications:[] ~working_directory:repository
            ~source:(Nixploy.Source.immutable commit)
            ~target
          |> assert_ok
        in
        Nixploy.Operation_receipt.consume_deploy receipts
          ~application_key:"non-production" ~receipt
        |> assert_ok
      in
      let prepare authorization = Nixploy.Deployment.prepare ~authorization in

      (* A real SQLite trigger rejects only the delayed heartbeat event after
         the fake build process group (and its child) have recorded their PIDs. *)
      clear_process_observations ();
      let heartbeat_path = Filename.concat root "heartbeat.sqlite" in
      let%bind heartbeat_store = Nixploy.Store.open_ ~path:heartbeat_path in
      let heartbeat_store = assert_ok heartbeat_store in
      install_trigger heartbeat_path
        {|CREATE TRIGGER reject_build_heartbeat
          BEFORE INSERT ON deployment_events
          WHEN NEW.stage = 'building'
           AND NEW.message LIKE 'Nix image build still running%'
          BEGIN SELECT RAISE(ABORT, 'heartbeat durable write rejected'); END;|};
      let heartbeat_authorization = authorization () in
      let%bind heartbeat_prepared = prepare heartbeat_authorization in
      let heartbeat_prepared = assert_ok heartbeat_prepared in
      let cancellation = Nixploy.Cancellation.create () in
      let%bind heartbeat_started =
        Nixploy.Cancellation.within cancellation (fun () ->
            Nixploy.Tracked_deployment.start
              ~authorization:heartbeat_authorization
              ~prepared:heartbeat_prepared ~store:heartbeat_store ())
      in
      let heartbeat_started = assert_ok heartbeat_started in
      let%bind () = wait_for_file leader_pid in
      let%bind () = wait_for_file child_pid in
      let heartbeat_id =
        Nixploy.Tracked_deployment.deployment heartbeat_started
        |> Nixploy.Store.id
      in
      let%bind heartbeat_terminal =
        Nixploy.Tracked_deployment.completion heartbeat_started
      in
      let heartbeat_terminal = assert_ok heartbeat_terminal in
      assert (
        Nixploy.Store.equal_state
          (Nixploy.Store.state heartbeat_terminal)
          Cancelled);
      let stages =
        durable_event_stages heartbeat_path ~deployment_id:heartbeat_id
      in
      [%test_eq: string list]
        [
          "requested";
          "connecting";
          "building";
          "cancellation-requested";
          "cancelled";
        ]
        stages;
      assert_only_one_terminal_event stages;
      assert (Nixploy.Cancellation.was_acknowledged cancellation);
      assert_process_is_reaped (In_channel.read_all leader_pid |> String.strip);
      assert_process_is_reaped (In_channel.read_all child_pid |> String.strip);
      let%bind () = Clock_ns.after (Time_ns.Span.of_sec 5.) in
      assert (not (Sys_unix.file_exists_exn delayed_marker));
      let%bind reused_heartbeat =
        assert_lease_reusable heartbeat_store ~working_directory:repository
          ~target ~commit
      in
      assert_ok reused_heartbeat;

      (* Binding an already bound, consumed receipt fails only inside the held
         lease, before resource-state or any remote process mutation. *)
      clear_process_observations ();
      let bind_path = Filename.concat root "bind.sqlite" in
      let%bind bind_store = Nixploy.Store.open_ ~path:bind_path in
      let bind_store = assert_ok bind_store in
      let bind_authorization = authorization () in
      let%bind bind_prepared = prepare bind_authorization in
      let bind_prepared = assert_ok bind_prepared in
      assert_ok
        (Nixploy.Operation_receipt.bind_deploy_operation bind_authorization
           ~operation_id:"another-operation");
      let%bind bind_started =
        Nixploy.Tracked_deployment.start ~authorization:bind_authorization
          ~prepared:bind_prepared ~store:bind_store ()
      in
      expect_error_containing bind_started "already bound";
      assert_ok
        (Nixploy.Operation_receipt.validate_deploy_operation bind_authorization
           ~operation_id:"another-operation");
      let%bind bind_history =
        Nixploy.Store.list_for_scope bind_store ~working_directory:repository
          ~target ~limit:10
      in
      let bind_operation = assert_ok bind_history |> List.hd_exn in
      assert (
        Nixploy.Store.equal_state (Nixploy.Store.state bind_operation) Failed);
      [%test_eq: string list] [ "requested"; "failed" ]
        (durable_event_stages bind_path
           ~deployment_id:(Nixploy.Store.id bind_operation));
      [%test_eq: int] 0 (resource_state_row_count bind_path);
      assert (not (Sys_unix.file_exists_exn leader_pid));
      assert (not (Sys_unix.file_exists_exn delayed_marker));
      assert (List.is_empty (trace_lines trace));
      let%bind reused_bind =
        assert_lease_reusable bind_store ~working_directory:repository ~target
          ~commit
      in
      assert_ok reused_bind;

      (* The state write is a real SQLite error after binding.  No process can
         start, but the admitted operation becomes one durable failed terminal. *)
      clear_process_observations ();
      let state_path = Filename.concat root "state-write.sqlite" in
      let%bind state_store = Nixploy.Store.open_ ~path:state_path in
      let state_store = assert_ok state_store in
      install_trigger state_path
        {|CREATE TRIGGER reject_unknown_resource_state
          BEFORE INSERT ON resource_states
          WHEN NEW.state = 'unknown'
          BEGIN SELECT RAISE(ABORT, 'unknown resource state rejected'); END;|};
      let state_authorization = authorization () in
      let%bind state_prepared = prepare state_authorization in
      let state_prepared = assert_ok state_prepared in
      let%bind state_started =
        Nixploy.Tracked_deployment.start ~authorization:state_authorization
          ~prepared:state_prepared ~store:state_store ()
      in
      expect_error_containing state_started "unknown resource state rejected";
      let%bind state_history =
        Nixploy.Store.list_for_scope state_store ~working_directory:repository
          ~target ~limit:10
      in
      let state_operation = assert_ok state_history |> List.hd_exn in
      assert (
        Nixploy.Store.equal_state (Nixploy.Store.state state_operation) Failed);
      [%test_eq: string list] [ "requested"; "failed" ]
        (durable_event_stages state_path
           ~deployment_id:(Nixploy.Store.id state_operation));
      assert_ok
        (Nixploy.Operation_receipt.validate_deploy_operation state_authorization
           ~operation_id:(Nixploy.Store.id state_operation));
      [%test_eq: int] 0 (resource_state_row_count state_path);
      assert (not (Sys_unix.file_exists_exn leader_pid));
      assert (not (Sys_unix.file_exists_exn delayed_marker));
      assert (List.is_empty (trace_lines trace));
      let%bind reused_state =
        assert_lease_reusable state_store ~working_directory:repository ~target
          ~commit
      in
      assert_ok reused_state;

      (* V1 prune is fail-closed before it can touch state or a remote process. *)
      clear_process_observations ();
      let prune_path = Filename.concat root "prune-state-write.sqlite" in
      let%bind prune_store = Nixploy.Store.open_ ~path:prune_path in
      let prune_store = assert_ok prune_store in
      let prune_application =
        Nixploy.Application.create ~store:prune_store ()
      in
      let%bind pruned =
        Nixploy.Application.prune_non_production prune_application
          ~working_directory:repository ~target
      in
      expect_error_containing pruned "prune is disabled in Production V1";
      [%test_eq: int] 0 (resource_state_row_count prune_path);
      assert (List.is_empty (trace_lines trace));
      let%bind reused_prune =
        assert_lease_reusable prune_store ~working_directory:repository ~target
          ~commit
      in
      assert_ok reused_prune;
      Deferred.unit)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
