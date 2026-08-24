open Async
open Core

let assert_ok = function Ok value -> value | Error error -> Error.raise error

let expect_prune_refused = function
  | Ok _ -> failwith "prune unexpectedly succeeded"
  | Error error ->
      assert (
        String.is_substring
          (Error.to_string_hum error)
          ~substring:"prune is disabled in Production V1")

let create_fake_commands directory event_path =
  let bin = Filename.concat directory "bin" in
  Core_unix.mkdir_p bin;
  List.iter [ "nix"; "git"; "podman"; "caddy" ] ~f:(fun name ->
      let path = Filename.concat bin name in
      Out_channel.write_all path
        ~data:
          (sprintf "#!/bin/sh\nprintf '%%s\\n' %s >> %s\nexit 99\n" name
             (Filename.quote event_path));
      Core_unix.chmod path ~perm:0o755);
  Caml_unix.putenv "PATH" (bin ^ ":" ^ Sys.getenv_exn "PATH")

let consumed_prune_authorization ~working_directory ~target =
  let store = Nixploy.Operation_receipt.create_prune_store () |> assert_ok in
  let receipt =
    Nixploy.Operation_receipt.issue_prune store ~application_key:(Some "app")
      ~expected_project:None ~repository_identity:None ~intent:None
      ~application:None ~commit:None ~working_directory ~target
    |> assert_ok
  in
  Nixploy.Operation_receipt.consume_prune store ~application_key:"app" ~receipt
  |> assert_ok

let target_configuration target_name =
  let configuration =
    Nixploy.Configuration.of_json
      {|{"__schema":"v0.3","project":"sample","targets":{"production":{"image":"image","ip":"example.invalid"}}}|}
    |> assert_ok
  in
  ( configuration,
    Nixploy.Configuration.find_target configuration target_name |> assert_ok )

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-prune-disabled-" "" in
  let event_path = Filename.concat directory "process-events" in
  create_fake_commands directory event_path;
  let state_path = Filename.concat directory "state.sqlite" in
  let%bind opened = Nixploy.Store.open_ ~path:state_path in
  let store = Or_error.ok_exn opened in
  let target = Nixploy.Target_name.of_string "production" |> Or_error.ok_exn in
  let authorization =
    consumed_prune_authorization ~working_directory:directory ~target
  in
  let%bind prepared = Nixploy.Prune.prepare ~authorization in
  expect_prune_refused prepared;
  expect_prune_refused
    (Nixploy.Prune.validate_bound ~authorization
       Nixploy.Prune.For_testing.prepared);
  let%bind executed =
    Nixploy.Prune.execute ~authorization Nixploy.Prune.For_testing.prepared
  in
  expect_prune_refused executed;
  let%bind direct = Nixploy.Prune.prune ~authorization () in
  expect_prune_refused direct;
  let configuration, podman_target = target_configuration target in
  let project = Nixploy.Configuration.project configuration in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target
      ~repository_identity:"repository"
    |> assert_ok
  in
  let%bind podman_preflight =
    Nixploy.Podman.preflight_prune_owned_resources ~connection:"connection"
      ~project ~target:podman_target ~resource_key
      ~repository_identity:"repository"
  in
  expect_prune_refused podman_preflight;
  let%bind podman_execute =
    Nixploy.Podman.execute_prepared_prune
      Nixploy.Podman.For_testing.prepared_prune
  in
  expect_prune_refused podman_execute;
  assert (not (Sys_unix.file_exists_exn event_path));
  let application = Nixploy.Application.create ~store () in
  let%bind refused =
    Nixploy.Application.prune_non_production application
      ~working_directory:directory ~target
  in
  expect_prune_refused refused;
  let%bind history = Nixploy.Store.list store ~limit:10 in
  [%test_eq: int] 0 (List.length (Or_error.ok_exn history));
  let%bind state =
    Nixploy.Store.resource_state store ~working_directory:directory ~target
  in
  [%test_eq: Nixploy.Store.resource_state] Unknown (Or_error.ok_exn state);
  let%map lease =
    Nixploy.Store.with_reconciled_lease store ~application_key:None
      ~working_directory:directory ~target (fun () ->
        Deferred.Or_error.return ())
  in
  Or_error.ok_exn lease;
  assert (not (Sys_unix.file_exists_exn event_path))

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
