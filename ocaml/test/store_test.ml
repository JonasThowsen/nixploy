open Async
open Core

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-store-test-" "" in
  let path = Filename.concat directory "state.db" in
  let target = Nixploy.Target_name.of_string "production" |> Or_error.ok_exn in
  let%bind opened = Nixploy.Store.open_ ~path in
  let store = Or_error.ok_exn opened in
  let%bind requested =
    Nixploy.Store.request store ~working_directory:"/tmp/project" ~target
  in
  let requested = Or_error.ok_exn requested in
  assert (
    [%equal: Nixploy.Store.state] (Nixploy.Store.state requested) Requested);
  let%bind staged =
    Nixploy.Store.record_stage store
      ~id:(Nixploy.Store.id requested)
      ~stage:Nixploy.Deployment.Building ~message:"Building"
  in
  Or_error.ok_exn staged;
  let%bind failed =
    Nixploy.Store.fail store
      ~id:(Nixploy.Store.id requested)
      ~error:(Error.of_string "fixture failure")
  in
  Or_error.ok_exn failed;
  let%bind deployments = Nixploy.Store.list store ~limit:10 in
  let deployment = Or_error.ok_exn deployments |> List.hd_exn in
  assert ([%equal: Nixploy.Store.state] (Nixploy.Store.state deployment) Failed);
  assert (
    Option.equal String.equal
      (Nixploy.Store.error deployment)
      (Some "fixture failure"));
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
