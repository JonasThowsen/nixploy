open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run () =
  let directory = Filename_unix.temp_dir "nixploy-direct-mode-fence-" "" in
  let target = Nixploy.Target_name.of_string "staging" |> assert_ok in
  let managed =
    Nixploy.Managed_application.all_of_json
      (sprintf
         {|{"app":{"project":"sample","target":"staging","repository":"%s","repositoryIdentity":"owner/sample","repositoryProvenance":"provider:sample","nonProduction":{"host":"target.example.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"sample-staging"}}}|}
         directory)
    |> assert_ok
  in
  let%bind store =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = assert_ok store in
  let commit =
    Nixploy.Application.For_testing.commit
      ~revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ~subject:"test"
      ~timestamp_ms:0L
    |> assert_ok
  in
  let application =
    Nixploy.Application.For_testing.create ~managed_applications:managed ~store
      ~preview_main:(fun ~working_directory:_ ->
        Deferred.Or_error.return commit)
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.return commit)
      ~deploy:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "direct deployment must not start")
      ~prune:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "prune is irrelevant")
      ()
  in
  let source =
    Nixploy.Application.For_testing.local_source ~working_directory:directory
      commit
  in
  let%bind overlapping_scope =
    Nixploy.Application.start_non_production application
      ~working_directory:directory ~source ~target ()
  in
  assert (Result.is_error overlapping_scope);
  let other_target = Nixploy.Target_name.of_string "other" |> assert_ok in
  let%map managed_key =
    Nixploy.Application.start_non_production ~application_key:"app" application
      ~working_directory:directory ~source ~target:other_target ()
  in
  assert (Result.is_error managed_key)

let () =
  don't_wait_for
    ( Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
