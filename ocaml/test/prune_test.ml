open Async
open Core

let expect_prune_refused = function
  | Ok _ -> failwith "prune unexpectedly succeeded"
  | Error error ->
      assert (
        String.is_substring
          (Error.to_string_hum error)
          ~substring:"prune is disabled in Production V1")

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-prune-disabled-" "" in
  let state_path = Filename.concat directory "state.sqlite" in
  let%bind opened = Nixploy.Store.open_ ~path:state_path in
  let store = Or_error.ok_exn opened in
  let target = Nixploy.Target_name.of_string "production" |> Or_error.ok_exn in
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
  Or_error.ok_exn lease

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
