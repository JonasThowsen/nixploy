open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let write_executable path contents =
  Out_channel.write_all path ~data:contents;
  Core_unix.chmod path ~perm:0o755

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-runtime-non-web-" "" in
  let fake_bin = Filename.concat directory "bin" in
  Core_unix.mkdir_p fake_bin;
  Out_channel.write_all (Filename.concat directory "flake.nix") ~data:"{}\n";
  Out_channel.write_all (Filename.concat directory "flake.lock") ~data:"{}\n";
  let git args =
    let command =
      String.concat ~sep:" "
        ("git" :: "-C" :: Filename.quote directory
        :: List.map args ~f:Filename.quote)
    in
    if not (Int.equal (Stdlib.Sys.command command) 0) then
      failwithf "fixture command failed: %s" command ()
  in
  git [ "init"; "-q" ];
  git [ "config"; "user.email"; "test@example.invalid" ];
  git [ "config"; "user.name"; "Test" ];
  git [ "add"; "flake.nix"; "flake.lock" ];
  git [ "commit"; "-qm"; "runtime fixture" ];
  let revision_path = Filename.concat directory "revision" in
  let revision_command =
    sprintf "git -C %s rev-parse HEAD > %s" (Filename.quote directory)
      (Filename.quote revision_path)
  in
  if not (Int.equal (Stdlib.Sys.command revision_command) 0) then
    failwith "could not read fixture revision";
  let revision = In_channel.read_all revision_path |> String.strip in
  let operation_id = "runtime-operation" in
  let repository_identity = "git@example.invalid:example.git" in
  write_executable
    (Filename.concat fake_bin "nix")
    {|#!/bin/sh
printf '%s\n' '{"__schema":"v0.3","project":"example","targets":{"production":{"image":"worker","ip":"host","user":"deploy","port":22}}}'
|};
  write_executable (Filename.concat fake_bin "ssh") {|#!/bin/sh
printf '[]\n'
|};
  write_executable
    (Filename.concat fake_bin "podman")
    (sprintf
       {|#!/bin/sh
case "$*" in
  *"system connection list"*) printf '[]\n' ;;
  *" inspect --type container "*)
    for name in "$@"; do :; done
    printf '[{"Id":"runtime-id","Name":"%%s","State":{"Running":true,"StartedAt":"2025-01-01T00:00:00Z"},"Config":{"Labels":{"io.nixploy.managed":"true","io.nixploy.project":"example","io.nixploy.target":"production","io.nixploy.resource_key":"%%s","io.nixploy.repository_identity":"%s","io.nixploy.revision":"%s","io.nixploy.operation_id":"%%s"}}}]\n' "$name" "$name" "$NIXPLOY_RUNTIME_OPERATION" ;;
  *" logs "*) printf '2025-01-01T00:00:00Z worker ready\n' ;;
  *" stats "*) printf '%%s\n' '[{"CPUPerc":"2.5%%","MemUsage":"4MiB / 1GiB"}]' ;;
  *) : ;;
esac
|}
       repository_identity revision);
  let old_path = Sys.getenv_exn "PATH" in
  Core_unix.putenv ~key:"PATH" ~data:(fake_bin ^ ":" ^ old_path);
  Core_unix.putenv ~key:"NIXPLOY_RUNTIME_OPERATION" ~data:operation_id;
  let application =
    Nixploy.Managed_application.all_of_json
      (sprintf
         {|{"worker":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"%s"}}|}
         directory repository_identity)
    |> assert_ok |> List.hd_exn
  in
  let commit =
    Nixploy.Source.For_testing.commit ~revision ~subject:"runtime fixture"
      ~timestamp_ms:0L
    |> assert_ok
  in
  let%bind resolved =
    Nixploy.Runtime_application.resolve ~commit ~operation_id application
  in
  let runtime = assert_ok resolved in
  assert (Option.is_none (Nixploy.Runtime_application.caddy runtime));
  assert (Option.is_none (Nixploy.Runtime_application.active_port runtime));
  let container = Nixploy.Runtime_application.container runtime in
  assert (
    String.equal
      (Nixploy.Podman.runtime_container_name container)
      (Nixploy.Runtime_application.connection runtime));
  let%bind logs =
    Nixploy.Podman.read_logs
      ~connection:(Nixploy.Runtime_application.connection runtime)
      ~container
  in
  let logs = assert_ok logs in
  [%test_eq: string] "worker ready" (List.hd_exn logs.lines).text;
  let%bind stats =
    Nixploy.Podman.read_stats
      ~connection:(Nixploy.Runtime_application.connection runtime)
      ~container
  in
  let stats = assert_ok stats in
  [%test_eq: int64] 4_194_304L stats.memory_used_bytes;
  let state_path = Filename.concat directory "state.sqlite" in
  let%bind opened = Nixploy.Store.open_ ~path:state_path in
  let store = assert_ok opened in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let%bind requested =
    Nixploy.Store.request store ~application_key:(Some "worker")
      ~working_directory:directory ~target ~commit
  in
  let requested = assert_ok requested in
  Core_unix.putenv ~key:"NIXPLOY_RUNTIME_OPERATION"
    ~data:(Nixploy.Store.id requested);
  let db = Sqlite3.db_open state_path in
  let sql =
    sprintf
      "UPDATE deployments SET state='succeeded', stage='succeeded' WHERE \
       id='%s'"
      (Nixploy.Store.id requested)
  in
  assert (phys_equal (Sqlite3.exec db sql) Sqlite3.Rc.OK);
  assert (Sqlite3.db_close db);
  let%bind present =
    Nixploy.Store.set_resource_state store ~working_directory:directory ~target
      Present
  in
  assert_ok present;
  let service = Nixploy.Application.create ~store () in
  let%bind service_logs =
    Nixploy.Application.application_logs service application
  in
  let service_logs = assert_ok service_logs in
  [%test_eq: string] "worker ready" (List.hd_exn service_logs.lines).text;
  let second_service = Nixploy.Application.create ~store () in
  let%bind second_logs =
    Nixploy.Application.application_logs second_service application
  in
  ignore (assert_ok second_logs : Nixploy.Application.log_snapshot);
  let%bind absent =
    Nixploy.Store.set_resource_state store ~working_directory:directory ~target
      Absent
  in
  assert_ok absent;
  let%bind stale = Nixploy.Application.application_logs service application in
  assert (Result.is_error stale);
  let%bind present =
    Nixploy.Store.set_resource_state store ~working_directory:directory ~target
      Present
  in
  assert_ok present;
  let%bind newer =
    Nixploy.Store.request store ~application_key:(Some "worker")
      ~working_directory:directory ~target ~commit
  in
  let newer = assert_ok newer in
  let db = Sqlite3.db_open state_path in
  let sql =
    sprintf
      "UPDATE deployments SET state='succeeded', stage='succeeded', \
       requested_at_ms=9000000000000 WHERE id='%s'"
      (Nixploy.Store.id newer)
  in
  assert (phys_equal (Sqlite3.exec db sql) Sqlite3.Rc.OK);
  assert (Sqlite3.db_close db);
  Core_unix.putenv ~key:"NIXPLOY_RUNTIME_OPERATION"
    ~data:(Nixploy.Store.id newer);
  let%bind refreshed =
    Nixploy.Application.application_logs second_service application
  in
  ignore (assert_ok refreshed : Nixploy.Application.log_snapshot);
  let%bind metrics =
    Nixploy.Application.application_metrics service application
  in
  let application_metrics = List.hd_exn metrics.applications in
  (match application_metrics.health with
  | Nixploy.Application.Unavailable message ->
      assert (String.is_substring message ~substring:"not configured")
  | Healthy | Unhealthy -> failwith "non-web health was reported as configured");
  let%bind local_success =
    Nixploy.Store.request store ~application_key:None
      ~working_directory:directory ~target ~commit
  in
  let local_success = assert_ok local_success in
  let db = Sqlite3.db_open state_path in
  let sql =
    sprintf
      "UPDATE deployments SET state='succeeded', stage='succeeded', \
       requested_at_ms=9100000000000 WHERE id='%s'"
      (Nixploy.Store.id local_success)
  in
  assert (phys_equal (Sqlite3.exec db sql) Sqlite3.Rc.OK);
  assert (Sqlite3.db_close db);
  Core_unix.putenv ~key:"NIXPLOY_RUNTIME_OPERATION"
    ~data:(Nixploy.Store.id local_success);
  let%bind ignored_local =
    Nixploy.Application.application_logs service application
  in
  assert (Result.is_error ignored_local);
  Core_unix.putenv ~key:"PATH" ~data:old_path;
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
