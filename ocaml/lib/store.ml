open Async
open Core

type t = { path : string }

type state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

type deployment = {
  id : string;
  application_key : string option;
  working_directory : string;
  target : Target_name.t;
  state : state;
  stage : string;
  message : string;
  revision : string option;
  commit_subject : string option;
  commit_timestamp_ms : int64 option;
  container_name : string option;
  error : string option;
  requested_at_ms : int64;
  started_at_ms : int64 option;
  finished_at_ms : int64 option;
  cancel_requested_at_ms : int64 option;
  updated_at_ms : int64;
}

let id t = t.id
let application_key t = t.application_key
let working_directory t = t.working_directory
let target t = t.target
let state t = t.state
let stage t = t.stage
let message t = t.message
let revision t = t.revision
let commit_subject t = t.commit_subject
let commit_timestamp_ms t = t.commit_timestamp_ms
let container_name t = t.container_name
let error t = t.error
let requested_at_ms t = t.requested_at_ms
let started_at_ms t = t.started_at_ms
let finished_at_ms t = t.finished_at_ms
let cancel_requested_at_ms t = t.cancel_requested_at_ms
let updated_at_ms t = t.updated_at_ms

let state_name = function
  | Requested -> "requested"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let state_of_string = function
  | "requested" -> Requested
  | "running" -> Running
  | "succeeded" -> Succeeded
  | "failed" -> Failed
  | "cancelled" -> Cancelled
  | state -> failwithf "unknown deployment state %s" state ()

let now_ms () = Caml_unix.gettimeofday () *. 1000. |> Int64.of_float

let new_id () =
  Uuid.create_random (Random.State.make_self_init ()) |> Uuid.to_string

let check db operation = function
  | Sqlite3.Rc.OK | DONE | ROW -> ()
  | code ->
      failwithf "%s failed: %s (%s)" operation
        (Sqlite3.Rc.to_string code)
        (Sqlite3.errmsg db) ()

let exec db sql = check db "SQLite statement" (Sqlite3.exec db sql)

let with_statement db sql ~f =
  let statement = Sqlite3.prepare db sql in
  Exn.protect
    ~f:(fun () -> f statement)
    ~finally:(fun () -> ignore (Sqlite3.finalize statement : Sqlite3.Rc.t))

let bind db statement values =
  check db "SQLite bind" (Sqlite3.bind_values statement values)

let with_db t ~f =
  let db = Sqlite3.db_open ~mutex:`FULL t.path in
  Sqlite3.busy_timeout db 5_000;
  Exn.protect
    ~f:(fun () ->
      exec db "PRAGMA foreign_keys = ON";
      f db)
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then failwith "SQLite database remained busy")

let schema_v2 =
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
  |}

let resource_state_schema =
  {|
    CREATE TABLE resource_states (
      working_directory TEXT NOT NULL,
      target TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('unknown', 'present', 'absent')),
      updated_at_ms INTEGER NOT NULL,
      PRIMARY KEY (working_directory, target)
    );
  |}

let user_version db =
  with_statement db "PRAGMA user_version" ~f:(fun statement ->
      match Sqlite3.step statement with
      | ROW -> Sqlite3.column_int statement 0
      | code ->
          check db "read schema version" code;
          assert false)

let check_foreign_keys db =
  with_statement db "PRAGMA foreign_key_check" ~f:(fun statement ->
      match Sqlite3.step statement with
      | DONE -> ()
      | ROW -> failwith "SQLite foreign key check found a violation"
      | code -> check db "check foreign keys" code)

let migrate_v1 db =
  exec db "PRAGMA foreign_keys = OFF";
  exec db "BEGIN IMMEDIATE";
  let committed = ref false in
  Exn.protect
    ~f:(fun () ->
      if Int.equal (user_version db) 2 then exec db "COMMIT"
      else (
        exec db "ALTER TABLE deployment_events RENAME TO deployment_events_v1";
        exec db "ALTER TABLE deployments RENAME TO deployments_v1";
        exec db "DROP INDEX IF EXISTS deployments_recent";
        exec db "DROP INDEX IF EXISTS deployment_events_operation";
        exec db schema_v2;
        exec db
          {|
          INSERT INTO deployments (
            id, working_directory, target, state, stage, message, revision,
            container_name, error, requested_at_ms, started_at_ms,
            finished_at_ms, updated_at_ms
          )
          SELECT id, working_directory, target, state, stage, message, revision,
            container_name, error, requested_at_ms,
            CASE WHEN state = 'requested' THEN NULL ELSE requested_at_ms END,
            CASE WHEN state IN ('succeeded', 'failed') THEN updated_at_ms ELSE NULL END,
            updated_at_ms
          FROM deployments_v1;
          INSERT INTO deployment_events
            (id, deployment_id, stage, message, inserted_at_ms)
          SELECT id, deployment_id, stage, message, inserted_at_ms
          FROM deployment_events_v1;
          DROP TABLE deployment_events_v1;
          DROP TABLE deployments_v1;
          PRAGMA user_version = 2;
          COMMIT;
        |});
      committed := true)
    ~finally:(fun () ->
      if not !committed then ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t));
  exec db "PRAGMA foreign_keys = ON";
  check_foreign_keys db

let migrate_v2 db =
  exec db "BEGIN IMMEDIATE";
  let committed = ref false in
  Exn.protect
    ~f:(fun () ->
      exec db resource_state_schema;
      exec db "PRAGMA user_version = 3";
      exec db "COMMIT";
      committed := true)
    ~finally:(fun () ->
      if not !committed then ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t))

let migrate db =
  exec db "PRAGMA journal_mode = DELETE";
  exec db "PRAGMA synchronous = FULL";
  match user_version db with
  | 0 ->
      exec db "BEGIN IMMEDIATE";
      let committed = ref false in
      Exn.protect
        ~f:(fun () ->
          exec db schema_v2;
          exec db resource_state_schema;
          exec db "PRAGMA user_version = 3";
          exec db "COMMIT";
          committed := true)
        ~finally:(fun () ->
          if not !committed then
            ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t))
  | 1 ->
      migrate_v1 db;
      migrate_v2 db
  | 2 -> migrate_v2 db
  | 3 -> ()
  | version -> failwithf "unsupported SQLite schema version %d" version ()

let open_ ~path =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let directory = Filename.dirname path in
          Core_unix.mkdir_p directory;
          let store = { path } in
          with_db store ~f:migrate;
          store))

let lease_path t ~working_directory ~target =
  let identity =
    working_directory ^ "\000" ^ Target_name.to_string target
    |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex
  in
  t.path ^ "." ^ identity ^ ".lock"

let acquire_lease t ~working_directory ~target =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let path = lease_path t ~working_directory ~target in
          let descriptor =
            Core_unix.openfile path ~mode:[ O_CREAT; O_RDWR ] ~perm:0o600
          in
          if Core_unix.flock descriptor Core_unix.Flock_command.lock_exclusive
          then descriptor
          else (
            Core_unix.close descriptor;
            failwith "another deployment already holds the target lease")))

let release_lease descriptor =
  In_thread.run (fun () ->
      ignore (Core_unix.flock descriptor Core_unix.Flock_command.unlock : bool);
      Core_unix.close descriptor)

let with_lease t ~working_directory ~target deploy =
  let open Deferred.Or_error.Let_syntax in
  let%bind descriptor = acquire_lease t ~working_directory ~target in
  Monitor.protect deploy ~finally:(fun () -> release_lease descriptor)

let data =
  Option.value_map ~default:Sqlite3.Data.NULL ~f:(fun value ->
      Sqlite3.Data.TEXT value)

let transaction db f =
  exec db "BEGIN IMMEDIATE";
  let committed = ref false in
  Exn.protect
    ~f:(fun () ->
      let result = f () in
      exec db "COMMIT";
      committed := true;
      result)
    ~finally:(fun () ->
      if not !committed then ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t))

let insert_event db ~id ~stage ~message ~now =
  with_statement db
    "INSERT INTO deployment_events (deployment_id, stage, message, \
     inserted_at_ms) VALUES (?, ?, ?, ?)" ~f:(fun statement ->
      bind db statement
        [ Sqlite3.Data.TEXT id; TEXT stage; TEXT message; INT now ];
      check db "insert deployment event" (Sqlite3.step statement))

let request t ~application_key ~working_directory ~target ~commit =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let id = new_id () in
          let now = now_ms () in
          let target_text = Target_name.to_string target in
          let revision = Source.commit_revision commit in
          let subject = Source.commit_subject commit in
          let commit_timestamp_ms = Source.commit_timestamp_ms commit in
          with_db t ~f:(fun db ->
              transaction db (fun () ->
                  with_statement db
                    "INSERT INTO deployments (id, application_key, \
                     working_directory, target, state, stage, message, \
                     revision, commit_subject, commit_timestamp_ms, \
                     requested_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, \
                     'requested', 'requested', 'Deployment requested', ?, ?, \
                     ?, ?, ?)" ~f:(fun statement ->
                      bind db statement
                        [
                          Sqlite3.Data.TEXT id;
                          data application_key;
                          TEXT working_directory;
                          TEXT target_text;
                          TEXT revision;
                          TEXT subject;
                          INT commit_timestamp_ms;
                          INT now;
                          INT now;
                        ];
                      check db "insert deployment" (Sqlite3.step statement));
                  insert_event db ~id ~stage:"requested"
                    ~message:"Deployment requested" ~now));
          {
            id;
            application_key;
            working_directory;
            target;
            state = Requested;
            stage = "requested";
            message = "Deployment requested";
            revision = Some revision;
            commit_subject = Some subject;
            commit_timestamp_ms = Some commit_timestamp_ms;
            container_name = None;
            error = None;
            requested_at_ms = now;
            started_at_ms = None;
            finished_at_ms = None;
            cancel_requested_at_ms = None;
            updated_at_ms = now;
          }))

let record_stage t ~id ~stage ~message =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let stage = Deployment.stage_name stage in
          let now = now_ms () in
          with_db t ~f:(fun db ->
              transaction db (fun () ->
                  with_statement db
                    "UPDATE deployments SET state = 'running', stage = ?, \
                     message = ?, started_at_ms = COALESCE(started_at_ms, ?), \
                     updated_at_ms = ? WHERE id = ? AND state IN ('requested', \
                     'running')" ~f:(fun statement ->
                      bind db statement
                        [ TEXT stage; TEXT message; INT now; INT now; TEXT id ];
                      check db "update deployment stage"
                        (Sqlite3.step statement));
                  if Sqlite3.changes db <> 1 then
                    failwith "deployment stage transition conflicted";
                  insert_event db ~id ~stage ~message ~now))))

let request_cancellation t ~id =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let now = now_ms () in
          with_db t ~f:(fun db ->
              transaction db (fun () ->
                  let state, already_requested =
                    with_statement db
                      "SELECT state, cancel_requested_at_ms FROM deployments \
                       WHERE id = ?" ~f:(fun statement ->
                        bind db statement [ Sqlite3.Data.TEXT id ];
                        match Sqlite3.step statement with
                        | ROW ->
                            ( Sqlite3.column_text statement 0 |> state_of_string,
                              match Sqlite3.column statement 1 with
                              | NULL -> false
                              | _ -> true )
                        | DONE -> failwith "deployment does not exist"
                        | code ->
                            check db "read deployment cancellation" code;
                            assert false)
                  in
                  match state with
                  | Succeeded | Failed | Cancelled ->
                      failwith "deployment is no longer active"
                  | (Requested | Running) when already_requested -> ()
                  | Requested | Running ->
                      with_statement db
                        "UPDATE deployments SET cancel_requested_at_ms = ?, \
                         updated_at_ms = ? WHERE id = ?" ~f:(fun statement ->
                          bind db statement [ INT now; INT now; TEXT id ];
                          check db "request deployment cancellation"
                            (Sqlite3.step statement));
                      insert_event db ~id ~stage:"cancellation-requested"
                        ~message:"Cancellation requested; cleanup may continue"
                        ~now))))

let finish t ~id ~state ~stage ~event_stage ~message ~container_name ~error =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let now = now_ms () in
          with_db t ~f:(fun db ->
              transaction db (fun () ->
                  with_statement db
                    "UPDATE deployments SET state = ?, stage = COALESCE(?, \
                     stage), message = ?, container_name = ?, error = ?, \
                     finished_at_ms = ?, updated_at_ms = ? WHERE id = ? AND \
                     state IN ('requested', 'running')" ~f:(fun statement ->
                      bind db statement
                        [
                          Sqlite3.Data.TEXT (state_name state);
                          data stage;
                          TEXT message;
                          data container_name;
                          data error;
                          INT now;
                          INT now;
                          TEXT id;
                        ];
                      check db "finish deployment" (Sqlite3.step statement));
                  if Sqlite3.changes db <> 1 then
                    failwith "deployment terminal transition conflicted";
                  insert_event db ~id ~stage:event_stage ~message ~now))))

let succeed t ~id ~result =
  let message =
    Deployment.warning result
    |> Option.value ~default:"Deployment independently verified"
  in
  finish t ~id ~state:Succeeded ~stage:(Some "succeeded")
    ~event_stage:"succeeded" ~message
    ~container_name:(Some (Deployment.container_name result))
    ~error:None

let fail t ~id ~error =
  let message = Error.to_string_hum error in
  finish t ~id ~state:Failed ~stage:None ~event_stage:"failed" ~message
    ~container_name:None ~error:(Some message)

let cancel t ~id =
  finish t ~id ~state:Cancelled ~stage:(Some "cancelled")
    ~event_stage:"cancelled" ~message:"Deployment cancelled after cleanup"
    ~container_name:None ~error:None

let optional_text statement index =
  match Sqlite3.column statement index with
  | Sqlite3.Data.TEXT value -> Some value
  | NULL -> None
  | value -> Some (Sqlite3.Data.to_string_coerce value)

let optional_int64 statement index =
  match Sqlite3.column statement index with
  | Sqlite3.Data.INT value -> Some value
  | NULL -> None
  | value -> Some (Sqlite3.Data.to_string_coerce value |> Int64.of_string)

let deployment_of_statement statement =
  {
    id = Sqlite3.column_text statement 0;
    application_key = optional_text statement 1;
    working_directory = Sqlite3.column_text statement 2;
    target =
      Sqlite3.column_text statement 3
      |> Target_name.of_string |> Or_error.ok_exn;
    state = Sqlite3.column_text statement 4 |> state_of_string;
    stage = Sqlite3.column_text statement 5;
    message = Sqlite3.column_text statement 6;
    revision = optional_text statement 7;
    commit_subject = optional_text statement 8;
    commit_timestamp_ms = optional_int64 statement 9;
    container_name = optional_text statement 10;
    error = optional_text statement 11;
    requested_at_ms = Sqlite3.column_int64 statement 12;
    started_at_ms = optional_int64 statement 13;
    finished_at_ms = optional_int64 statement 14;
    cancel_requested_at_ms = optional_int64 statement 15;
    updated_at_ms = Sqlite3.column_int64 statement 16;
  }

let select_columns =
  "id, application_key, working_directory, target, state, stage, message, \
   revision, commit_subject, commit_timestamp_ms, container_name, error, \
   requested_at_ms, started_at_ms, finished_at_ms, cancel_requested_at_ms, \
   updated_at_ms"

let collect db statement operation =
  let rec loop deployments =
    match Sqlite3.step statement with
    | ROW -> loop (deployment_of_statement statement :: deployments)
    | DONE -> List.rev deployments
    | code ->
        check db operation code;
        assert false
  in
  loop []

let list t ~limit =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          with_db t ~f:(fun db ->
              with_statement db
                ("SELECT " ^ select_columns
               ^ " FROM deployments ORDER BY requested_at_ms DESC LIMIT ?")
                ~f:(fun statement ->
                  bind db statement [ Sqlite3.Data.INT (Int64.of_int limit) ];
                  collect db statement "list deployments"))))

let list_for_application t ~application_key ~working_directory ~target ~limit =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          with_db t ~f:(fun db ->
              with_statement db
                ("SELECT " ^ select_columns
               ^ " FROM deployments WHERE application_key = ? OR \
                  (application_key IS NULL AND working_directory = ? AND \
                  target = ?) ORDER BY requested_at_ms DESC LIMIT ?")
                ~f:(fun statement ->
                  bind db statement
                    [
                      Sqlite3.Data.TEXT application_key;
                      TEXT working_directory;
                      TEXT (Target_name.to_string target);
                      INT (Int64.of_int limit);
                    ];
                  collect db statement "list application deployments"))))

let resource_state_of_string = function
  | "unknown" -> Unknown
  | "present" -> Present
  | "absent" -> Absent
  | state -> failwithf "unknown resource state %s" state ()

let resource_state_name = function
  | Unknown -> "unknown"
  | Present -> "present"
  | Absent -> "absent"

let resource_state t ~working_directory ~target =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          with_db t ~f:(fun db ->
              with_statement db
                "SELECT state FROM resource_states WHERE working_directory = ? \
                 AND target = ?" ~f:(fun statement ->
                  bind db statement
                    [
                      Sqlite3.Data.TEXT working_directory;
                      TEXT (Target_name.to_string target);
                    ];
                  match Sqlite3.step statement with
                  | ROW ->
                      Sqlite3.column_text statement 0
                      |> resource_state_of_string
                  | DONE -> Unknown
                  | code ->
                      check db "read resource state" code;
                      assert false))))

let set_resource_state t ~working_directory ~target state =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let now = now_ms () in
          with_db t ~f:(fun db ->
              with_statement db
                "INSERT INTO resource_states (working_directory, target, \
                 state, updated_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT \
                 (working_directory, target) DO UPDATE SET state = \
                 excluded.state, updated_at_ms = excluded.updated_at_ms"
                ~f:(fun statement ->
                  bind db statement
                    [
                      Sqlite3.Data.TEXT working_directory;
                      TEXT (Target_name.to_string target);
                      TEXT (resource_state_name state);
                      INT now;
                    ];
                  check db "write resource state" (Sqlite3.step statement)))))

let find t ~id =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          with_db t ~f:(fun db ->
              with_statement db
                ("SELECT " ^ select_columns ^ " FROM deployments WHERE id = ?")
                ~f:(fun statement ->
                  bind db statement [ Sqlite3.Data.TEXT id ];
                  match Sqlite3.step statement with
                  | ROW -> Some (deployment_of_statement statement)
                  | DONE -> None
                  | code ->
                      check db "find deployment" code;
                      assert false))))
