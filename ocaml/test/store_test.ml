open Async
open Core

let create_v1_database path =
  let db = Sqlite3.db_open path in
  let sql =
    {|
      CREATE TABLE deployments (
        id TEXT PRIMARY KEY,
        working_directory TEXT NOT NULL,
        target TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('requested', 'running', 'succeeded', 'failed')),
        stage TEXT NOT NULL,
        message TEXT NOT NULL,
        revision TEXT,
        container_name TEXT,
        error TEXT,
        requested_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      );
      CREATE TABLE deployment_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deployment_id TEXT NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
        stage TEXT NOT NULL,
        message TEXT NOT NULL,
        inserted_at_ms INTEGER NOT NULL
      );
      CREATE INDEX deployments_recent ON deployments(requested_at_ms DESC);
      CREATE INDEX deployment_events_operation ON deployment_events(deployment_id, id);
      INSERT INTO deployments VALUES (
        'legacy-operation', '/tmp/legacy', 'production', 'succeeded',
        'succeeded', 'verified',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'legacy-blue', NULL,
        1000, 2000
      );
      INSERT INTO deployment_events
        (deployment_id, stage, message, inserted_at_ms)
      VALUES ('legacy-operation', 'succeeded', 'verified', 2000);
      PRAGMA user_version = 1;
    |}
  in
  let result = Sqlite3.exec db sql in
  if not (phys_equal result Sqlite3.Rc.OK) then failwith (Sqlite3.errmsg db);
  assert (Sqlite3.db_close db)

let create_v2_database path =
  let db = Sqlite3.db_open path in
  let sql =
    {|
      CREATE TABLE deployments (
        id TEXT PRIMARY KEY,
        application_key TEXT,
        working_directory TEXT NOT NULL,
        target TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('requested', 'running', 'succeeded', 'failed', 'cancelled')),
        stage TEXT NOT NULL,
        message TEXT NOT NULL,
        revision TEXT,
        commit_subject TEXT,
        commit_timestamp_ms INTEGER,
        container_name TEXT,
        error TEXT,
        requested_at_ms INTEGER NOT NULL,
        started_at_ms INTEGER,
        finished_at_ms INTEGER,
        cancel_requested_at_ms INTEGER,
        updated_at_ms INTEGER NOT NULL
      );
      CREATE TABLE deployment_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        deployment_id TEXT NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
        stage TEXT NOT NULL,
        message TEXT NOT NULL,
        inserted_at_ms INTEGER NOT NULL
      );
      CREATE INDEX deployments_recent ON deployments(requested_at_ms DESC);
      CREATE INDEX deployments_application_recent ON deployments(application_key, requested_at_ms DESC);
      CREATE INDEX deployment_events_operation ON deployment_events(deployment_id, id);
      PRAGMA user_version = 2;
    |}
  in
  let result = Sqlite3.exec db sql in
  if not (phys_equal result Sqlite3.Rc.OK) then failwith (Sqlite3.errmsg db);
  assert (Sqlite3.db_close db)

let force_succeeded path deployment ~requested_at_ms =
  let db = Sqlite3.db_open path in
  let statement =
    Sqlite3.prepare db
      "UPDATE deployments SET state = 'succeeded', stage = 'succeeded', \
       requested_at_ms = ?, updated_at_ms = ? WHERE id = ?"
  in
  let result =
    Sqlite3.bind_values statement
      [
        Sqlite3.Data.INT requested_at_ms;
        Sqlite3.Data.INT requested_at_ms;
        Sqlite3.Data.TEXT (Nixploy.Store.id deployment);
      ]
  in
  assert (phys_equal result Sqlite3.Rc.OK);
  assert (phys_equal (Sqlite3.step statement) Sqlite3.Rc.DONE);
  ignore (Sqlite3.finalize statement : Sqlite3.Rc.t);
  assert (Sqlite3.db_close db)

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-store-test-" "" in
  let path = Filename.concat directory "state.db" in
  let target = Nixploy.Target_name.of_string "production" |> Or_error.ok_exn in
  let commit =
    Nixploy.Source.For_testing.commit
      ~revision:"0123456789abcdef0123456789abcdef01234567"
      ~subject:"Test deployment" ~timestamp_ms:1_700_000_000_000L
    |> Or_error.ok_exn
  in
  let%bind opened = Nixploy.Store.open_ ~path in
  let store = Or_error.ok_exn opened in
  let%bind initial_resources =
    Nixploy.Store.resource_state store ~working_directory:"/tmp/project" ~target
  in
  assert (
    [%equal: Nixploy.Store.resource_state]
      (Or_error.ok_exn initial_resources)
      Unknown);
  let%bind present =
    Nixploy.Store.set_resource_state store ~working_directory:"/tmp/project"
      ~target Present
  in
  Or_error.ok_exn present;
  let%bind present =
    Nixploy.Store.resource_state store ~working_directory:"/tmp/project" ~target
  in
  assert (
    [%equal: Nixploy.Store.resource_state] (Or_error.ok_exn present) Present);
  let lease_entered = Ivar.create () in
  let release_lease = Ivar.create () in
  let first_lease =
    Nixploy.Store.with_reconciled_lease store ~application_key:None
      ~working_directory:"/tmp/project" ~target (fun () ->
        Ivar.fill_if_empty lease_entered ();
        let%map () = Ivar.read release_lease in
        Ok ())
  in
  let%bind () = Ivar.read lease_entered in
  let second_lease =
    Nixploy.Store.with_reconciled_lease store ~application_key:None
      ~working_directory:"/tmp/project" ~target (fun () ->
        Deferred.Or_error.return ())
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 50.) in
  assert (not (Deferred.is_determined second_lease));
  Ivar.fill_exn release_lease ();
  let%bind lease_results = Deferred.all [ first_lease; second_lease ] in
  List.iter lease_results ~f:Or_error.ok_exn;
  let%bind requested =
    Nixploy.Store.request store ~application_key:(Some "test")
      ~working_directory:"/tmp/project" ~target ~commit
  in
  let requested = Or_error.ok_exn requested in
  assert (
    [%equal: Nixploy.Store.state] (Nixploy.Store.state requested) Requested);
  let%bind staged =
    Nixploy.Store.record_stage store
      ~id:(Nixploy.Store.id requested)
      ~stage:"building" ~message:"Building"
  in
  Or_error.ok_exn staged;
  let%bind failed =
    Nixploy.Store.fail store
      ~id:(Nixploy.Store.id requested)
      ~error:(Error.of_string "nix interrupted by sigint")
  in
  Or_error.ok_exn failed;
  let%bind deployments = Nixploy.Store.list store ~limit:10 in
  let deployment = Or_error.ok_exn deployments |> List.hd_exn in
  assert ([%equal: Nixploy.Store.state] (Nixploy.Store.state deployment) Failed);
  assert (
    Option.equal String.equal
      (Nixploy.Store.error deployment)
      (Some "nix interrupted by sigint"));
  assert (
    Option.equal String.equal
      (Nixploy.Store.revision deployment)
      (Some "0123456789abcdef0123456789abcdef01234567"));
  assert (String.equal (Nixploy.Store.stage deployment) "building");
  assert (Option.is_some (Nixploy.Store.started_at_ms deployment));
  assert (Option.is_some (Nixploy.Store.finished_at_ms deployment));
  let%bind requested_cancel =
    Nixploy.Store.request store ~application_key:(Some "test")
      ~working_directory:"/tmp/project" ~target ~commit
  in
  let requested_cancel = Or_error.ok_exn requested_cancel in
  let%bind staged_cancel =
    Nixploy.Store.record_stage store
      ~id:(Nixploy.Store.id requested_cancel)
      ~stage:"building" ~message:"Building"
  in
  Or_error.ok_exn staged_cancel;
  let%bind cancellation =
    Nixploy.Store.request_cancellation store
      ~id:(Nixploy.Store.id requested_cancel)
  in
  Or_error.ok_exn cancellation;
  let%bind cancelled =
    Nixploy.Store.cancel store ~id:(Nixploy.Store.id requested_cancel)
  in
  Or_error.ok_exn cancelled;
  let%bind cancelled =
    Nixploy.Store.find store ~id:(Nixploy.Store.id requested_cancel)
  in
  let cancelled = Or_error.ok_exn cancelled |> Option.value_exn in
  assert (
    [%equal: Nixploy.Store.state] (Nixploy.Store.state cancelled) Cancelled);
  assert (Option.is_some (Nixploy.Store.cancel_requested_at_ms cancelled));
  let%bind stale_heartbeat =
    Nixploy.Store.record_stage store
      ~id:(Nixploy.Store.id requested_cancel)
      ~stage:"building"
      ~message:
        "Nix image build still running (elapsed 30s; build output remains \
         buffered)"
  in
  assert (Result.is_error stale_heartbeat);
  let%bind terminal_after_heartbeat =
    Nixploy.Store.find store ~id:(Nixploy.Store.id requested_cancel)
  in
  let terminal_after_heartbeat =
    Or_error.ok_exn terminal_after_heartbeat |> Option.value_exn
  in
  assert (
    [%equal: Nixploy.Store.state]
      (Nixploy.Store.state terminal_after_heartbeat)
      Cancelled);
  assert (
    String.equal (Nixploy.Store.stage terminal_after_heartbeat) "cancelled");
  let%bind exact_success =
    Nixploy.Store.request store ~application_key:(Some "managed")
      ~working_directory:"/tmp/exact" ~target ~commit
  in
  let exact_success = Or_error.ok_exn exact_success in
  force_succeeded path exact_success ~requested_at_ms:10L;
  let%bind later_failures =
    Deferred.List.map (List.init 30 ~f:Fn.id) ~how:`Sequential ~f:(fun index ->
        let%bind requested =
          Nixploy.Store.request store ~application_key:(Some "managed")
            ~working_directory:"/tmp/exact" ~target ~commit
        in
        let requested = Or_error.ok_exn requested in
        Nixploy.Store.fail store
          ~id:(Nixploy.Store.id requested)
          ~error:(Error.of_string (sprintf "failure %d" index)))
  in
  List.iter later_failures ~f:Or_error.ok_exn;
  let%bind unkeyed_success =
    Nixploy.Store.request store ~application_key:None
      ~working_directory:"/tmp/exact" ~target ~commit
  in
  let unkeyed_success = Or_error.ok_exn unkeyed_success in
  force_succeeded path unkeyed_success ~requested_at_ms:9_000_000_000_000L;
  let%bind latest_exact =
    Nixploy.Store.latest_successful_for_application store
      ~application_key:"managed" ~working_directory:"/tmp/exact" ~target
  in
  let latest_exact = Or_error.ok_exn latest_exact |> Option.value_exn in
  [%test_eq: string]
    (Nixploy.Store.id exact_success)
    (Nixploy.Store.id latest_exact);
  let migration_path = Filename.concat directory "legacy.db" in
  create_v1_database migration_path;
  let%bind migrated_store = Nixploy.Store.open_ ~path:migration_path in
  let migrated_store = Or_error.ok_exn migrated_store in
  let%bind migrated =
    Nixploy.Store.find migrated_store ~id:"legacy-operation"
  in
  let migrated = Or_error.ok_exn migrated |> Option.value_exn in
  assert ([%equal: Nixploy.Store.state] (Nixploy.Store.state migrated) Succeeded);
  assert (Option.is_some (Nixploy.Store.started_at_ms migrated));
  assert (Option.is_some (Nixploy.Store.finished_at_ms migrated));
  let%bind migrated_resource =
    Nixploy.Store.resource_state migrated_store ~working_directory:"/tmp/legacy"
      ~target
  in
  assert (
    [%equal: Nixploy.Store.resource_state]
      (Or_error.ok_exn migrated_resource)
      Unknown);
  let concurrent_v2_path = Filename.concat directory "concurrent-v2.db" in
  create_v2_database concurrent_v2_path;
  let%bind concurrent_opens =
    List.init 8 ~f:(fun _ -> Nixploy.Store.open_ ~path:concurrent_v2_path)
    |> Deferred.all
  in
  let concurrent_stores = List.map concurrent_opens ~f:Or_error.ok_exn in
  let%bind concurrent_resources =
    List.map concurrent_stores ~f:(fun concurrent_store ->
        Nixploy.Store.resource_state concurrent_store
          ~working_directory:"/tmp/concurrent" ~target)
    |> Deferred.all
  in
  List.iter concurrent_resources ~f:(fun state ->
      assert (
        [%equal: Nixploy.Store.resource_state] (Or_error.ok_exn state) Unknown));
  let%bind reopened = Nixploy.Store.open_ ~path in
  let%bind persisted_resource =
    Nixploy.Store.resource_state (Or_error.ok_exn reopened)
      ~working_directory:"/tmp/project" ~target
  in
  assert (
    [%equal: Nixploy.Store.resource_state]
      (Or_error.ok_exn persisted_resource)
      Present);
  let%map _ =
    Nixploy.Process_runner.run_stdout ~timeout:(Time_ns.Span.of_sec 5.)
      ~max_output_bytes:65_536 ~prog:"rm" ~args:[ "-rf"; "--"; directory ] ()
  in
  ()

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
