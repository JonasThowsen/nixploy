open Async
open Core

type t = { path : string }

type state = Requested | Running | Succeeded | Failed
[@@deriving compare, equal, sexp]

type deployment = {
  id : string;
  working_directory : string;
  target : Target_name.t;
  state : state;
  stage : string;
  message : string;
  revision : string option;
  container_name : string option;
  error : string option;
  requested_at_ms : int64;
  updated_at_ms : int64;
}

let id t = t.id
let working_directory t = t.working_directory
let target t = t.target
let state t = t.state
let stage t = t.stage
let message t = t.message
let revision t = t.revision
let container_name t = t.container_name
let error t = t.error
let requested_at_ms t = t.requested_at_ms
let updated_at_ms t = t.updated_at_ms

let state_name = function
  | Requested -> "requested"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"

let state_of_string = function
  | "requested" -> Requested
  | "running" -> Running
  | "succeeded" -> Succeeded
  | "failed" -> Failed
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
    ~f:(fun () -> f db)
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then failwith "SQLite database remained busy")

let migration =
  {|
    PRAGMA journal_mode = DELETE;
    PRAGMA synchronous = FULL;
    CREATE TABLE IF NOT EXISTS deployments (
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
    CREATE TABLE IF NOT EXISTS deployment_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      deployment_id TEXT NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
      stage TEXT NOT NULL,
      message TEXT NOT NULL,
      inserted_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS deployments_recent ON deployments(requested_at_ms DESC);
    CREATE INDEX IF NOT EXISTS deployment_events_operation ON deployment_events(deployment_id, id);
    PRAGMA user_version = 1;
  |}

let open_ ~path =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let directory = Filename.dirname path in
          Core_unix.mkdir_p directory;
          let store = { path } in
          with_db store ~f:(fun db ->
              exec db "PRAGMA foreign_keys = ON";
              exec db migration);
          store))

let request t ~working_directory ~target =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let id = new_id () in
          let now = now_ms () in
          let target_text = Target_name.to_string target in
          with_db t ~f:(fun db ->
              with_statement db
                "INSERT INTO deployments (id, working_directory, target, \
                 state, stage, message, requested_at_ms, updated_at_ms) VALUES \
                 (?, ?, ?, 'requested', 'requested', 'Deployment requested', \
                 ?, ?)" ~f:(fun statement ->
                  bind db statement
                    [
                      Sqlite3.Data.TEXT id;
                      TEXT working_directory;
                      TEXT target_text;
                      INT now;
                      INT now;
                    ];
                  check db "insert deployment" (Sqlite3.step statement));
              with_statement db
                "INSERT INTO deployment_events (deployment_id, stage, message, \
                 inserted_at_ms) VALUES (?, 'requested', 'Deployment \
                 requested', ?)" ~f:(fun statement ->
                  bind db statement [ Sqlite3.Data.TEXT id; INT now ];
                  check db "insert deployment event" (Sqlite3.step statement)));
          {
            id;
            working_directory;
            target;
            state = Requested;
            stage = "requested";
            message = "Deployment requested";
            revision = None;
            container_name = None;
            error = None;
            requested_at_ms = now;
            updated_at_ms = now;
          }))

let record_stage t ~id ~stage ~message =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let stage = Deployment.stage_name stage in
          let now = now_ms () in
          with_db t ~f:(fun db ->
              exec db "BEGIN IMMEDIATE";
              let committed = ref false in
              Exn.protect
                ~f:(fun () ->
                  with_statement db
                    "UPDATE deployments SET state = 'running', stage = ?, \
                     message = ?, updated_at_ms = ? WHERE id = ? AND state IN \
                     ('requested', 'running')" ~f:(fun statement ->
                      bind db statement
                        [
                          Sqlite3.Data.TEXT stage;
                          TEXT message;
                          INT now;
                          TEXT id;
                        ];
                      check db "update deployment stage"
                        (Sqlite3.step statement));
                  if Sqlite3.changes db <> 1 then
                    failwith "deployment stage transition conflicted";
                  with_statement db
                    "INSERT INTO deployment_events (deployment_id, stage, \
                     message, inserted_at_ms) VALUES (?, ?, ?, ?)"
                    ~f:(fun statement ->
                      bind db statement
                        [
                          Sqlite3.Data.TEXT id;
                          TEXT stage;
                          TEXT message;
                          INT now;
                        ];
                      check db "insert deployment event"
                        (Sqlite3.step statement));
                  exec db "COMMIT";
                  committed := true)
                ~finally:(fun () ->
                  if not !committed then
                    ignore (Sqlite3.exec db "ROLLBACK" : Sqlite3.Rc.t)))))

let finish t ~id ~state ~stage ~message ~revision ~container_name ~error =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          let now = now_ms () in
          let data =
            Option.value_map ~default:Sqlite3.Data.NULL ~f:(fun value ->
                Sqlite3.Data.TEXT value)
          in
          with_db t ~f:(fun db ->
              with_statement db
                "UPDATE deployments SET state = ?, stage = ?, message = ?, \
                 revision = ?, container_name = ?, error = ?, updated_at_ms = \
                 ? WHERE id = ?" ~f:(fun statement ->
                  bind db statement
                    [
                      Sqlite3.Data.TEXT (state_name state);
                      TEXT stage;
                      TEXT message;
                      data revision;
                      data container_name;
                      data error;
                      INT now;
                      TEXT id;
                    ];
                  check db "finish deployment" (Sqlite3.step statement));
              if Sqlite3.changes db <> 1 then
                failwith "deployment does not exist";
              with_statement db
                "INSERT INTO deployment_events (deployment_id, stage, message, \
                 inserted_at_ms) VALUES (?, ?, ?, ?)" ~f:(fun statement ->
                  bind db statement
                    [ Sqlite3.Data.TEXT id; TEXT stage; TEXT message; INT now ];
                  check db "insert terminal event" (Sqlite3.step statement)))))

let succeed t ~id ~result =
  finish t ~id ~state:Succeeded ~stage:"succeeded"
    ~message:"Deployment independently verified"
    ~revision:(Some (Deployment.revision result))
    ~container_name:(Some (Deployment.container_name result))
    ~error:None

let fail t ~id ~error =
  let message = Error.to_string_hum error in
  finish t ~id ~state:Failed ~stage:"failed" ~message ~revision:None
    ~container_name:None ~error:(Some message)

let deployment_of_statement statement =
  let optional_text index =
    match Sqlite3.column statement index with
    | Sqlite3.Data.TEXT value -> Some value
    | NULL -> None
    | value -> Some (Sqlite3.Data.to_string_coerce value)
  in
  {
    id = Sqlite3.column_text statement 0;
    working_directory = Sqlite3.column_text statement 1;
    target =
      Sqlite3.column_text statement 2
      |> Target_name.of_string |> Or_error.ok_exn;
    state = Sqlite3.column_text statement 3 |> state_of_string;
    stage = Sqlite3.column_text statement 4;
    message = Sqlite3.column_text statement 5;
    revision = optional_text 6;
    container_name = optional_text 7;
    error = optional_text 8;
    requested_at_ms = Sqlite3.column_int64 statement 9;
    updated_at_ms = Sqlite3.column_int64 statement 10;
  }

let select_columns =
  "id, working_directory, target, state, stage, message, revision, \
   container_name, error, requested_at_ms, updated_at_ms"

let list t ~limit =
  Monitor.try_with_or_error (fun () ->
      In_thread.run (fun () ->
          with_db t ~f:(fun db ->
              with_statement db
                ("SELECT " ^ select_columns
               ^ " FROM deployments ORDER BY requested_at_ms DESC LIMIT ?")
                ~f:(fun statement ->
                  bind db statement [ Sqlite3.Data.INT (Int64.of_int limit) ];
                  let rec collect deployments =
                    match Sqlite3.step statement with
                    | ROW ->
                        collect
                          (deployment_of_statement statement :: deployments)
                    | DONE -> List.rev deployments
                    | code ->
                        check db "list deployments" code;
                        assert false
                  in
                  collect []))))

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
