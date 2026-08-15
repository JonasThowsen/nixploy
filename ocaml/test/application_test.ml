open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run_tests () =
  let open Deferred.Let_syntax in
  let main_revision = String.make 40 'a' in
  let selected_revision = String.make 40 'b' in
  let main_commit =
    Nixploy.Application.For_testing.commit ~revision:main_revision
      ~subject:"Main commit" ~timestamp_ms:1_000L
    |> assert_ok
  in
  let selected_commit =
    Nixploy.Application.For_testing.commit ~revision:selected_revision
      ~subject:"Selected commit" ~timestamp_ms:2_000L
    |> assert_ok
  in
  let deployed = ref [] in
  let application =
    Nixploy.Application.For_testing.create
      ~preview_main:(fun ~working_directory ->
        assert (String.equal working_directory "/srv/example");
        Deferred.Or_error.return main_commit)
      ~find_commit:(fun ~working_directory ~revision ->
        assert (String.equal working_directory "/srv/example");
        assert (String.equal revision selected_revision);
        Deferred.Or_error.return selected_commit)
      ~deploy:(fun
          ~on_stage:_
          ~on_requested:_
          ~application_key
          ~working_directory
          ~commit
          ~target:_
          ()
        ->
        deployed :=
          ( application_key,
            working_directory,
            Nixploy.Application.commit_revision commit )
          :: !deployed;
        Deferred.Or_error.error_string "fake deployment stopped")
  in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let%bind preview =
    Nixploy.Application.preview_commit application
      ~working_directory:"/srv/example"
  in
  let preview = assert_ok preview in
  assert (
    String.equal main_revision (Nixploy.Application.commit_revision preview));
  let%bind cli_result =
    Nixploy.Application.deploy application ~working_directory:"/srv/example"
      ~commit:preview ~target ()
  in
  assert (Result.is_error cli_result);
  [%test_eq: (string option * string * string) list]
    [ (None, "/srv/example", main_revision) ]
    (List.rev !deployed);
  let%bind resolved =
    Nixploy.Application.resolve_commit application
      ~working_directory:"/srv/example" ~revision:selected_revision
  in
  let resolved = assert_ok resolved in
  assert (
    String.equal selected_revision
      (Nixploy.Application.commit_revision resolved));
  let%map rpc_result =
    Nixploy.Application.deploy ~application_key:"example" application
      ~working_directory:"/srv/example" ~commit:resolved ~target ()
  in
  assert (Result.is_error rpc_result);
  [%test_eq: (string option * string * string) list]
    [
      (None, "/srv/example", main_revision);
      (Some "example", "/srv/example", selected_revision);
    ]
    (List.rev !deployed)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
