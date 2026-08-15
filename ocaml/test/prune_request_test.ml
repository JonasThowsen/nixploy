open Async
open Core
module Prune_request = Nixploy_rpc_mapping.Prune_request

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-prune-request-test-" "" in
  let%bind store_result =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = assert_ok store_result in
  let applications =
    sprintf
      {|{"example":{"project":"example","target":"production","repository":"%s"}}|}
      directory
    |> Nixploy.Managed_application.all_of_json |> assert_ok
  in
  let application = List.hd_exn applications in
  let project = Nixploy.Managed_application.project application in
  let target = Nixploy.Managed_application.target application in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target |> assert_ok
  in
  let application_result =
    Nixploy.Application.For_testing.prune_result ~project ~target ~resource_key
      ~containers_removed:2 ~secrets_removed:1
      ~route:Nixploy.Application.Missing
  in
  let prune_calls = ref [] in
  let invalidated = ref [] in
  let prune ~working_directory ~target =
    prune_calls := (working_directory, target) :: !prune_calls;
    Deferred.Or_error.return application_result
  in
  let on_success ~application_key =
    invalidated := application_key :: !invalidated
  in
  let query = { Protocol.Prune.Query.application = "example" } in
  let%bind success =
    Prune_request.handle ~applications ~store ~prune ~on_success query
  in
  let success = assert_ok success in
  assert (String.equal success.project "example");
  assert (String.equal success.target "production");
  assert (Int.equal success.containers_removed 2);
  assert (Int.equal success.secrets_removed 1);
  assert ([%equal: Protocol.Prune_result.Route.t] success.route Missing);
  [%test_eq: string list] [ "example" ] !invalidated;
  [%test_eq: int] 1 (List.length !prune_calls);
  let commit =
    Nixploy.Source.For_testing.commit ~revision:(String.make 40 'a')
      ~subject:"Active deployment" ~timestamp_ms:1L
    |> assert_ok
  in
  let%bind requested =
    Nixploy.Store.request store ~application_key:(Some "example")
      ~working_directory:directory ~target ~commit
  in
  let operation = assert_ok requested in
  let assert_blocked () =
    let%map blocked =
      Prune_request.handle ~applications ~store ~prune ~on_success query
    in
    let blocked_error = Result.error blocked |> Option.value_exn in
    assert (
      Error.to_string_hum blocked_error
      |> String.is_substring ~substring:"deployment or cancellation is active");
    [%test_eq: int] 1 (List.length !prune_calls);
    [%test_eq: string list] [ "example" ] !invalidated
  in
  let%bind () = assert_blocked () in
  let%bind running =
    Nixploy.Store.record_stage store
      ~id:(Nixploy.Store.id operation)
      ~stage:Nixploy.Deployment.Preparing_source ~message:"Deployment running"
  in
  ignore (assert_ok running : unit);
  let%bind cancellation =
    Nixploy.Store.request_cancellation store ~id:(Nixploy.Store.id operation)
  in
  ignore (assert_ok cancellation : unit);
  let%bind () = assert_blocked () in
  let%bind unknown =
    Prune_request.handle ~applications ~store ~prune ~on_success
      { Protocol.Prune.Query.application = "unknown" }
  in
  assert (Result.is_error unknown);
  [%test_eq: int] 1 (List.length !prune_calls);
  Deferred.unit

let () = Thread_safe.block_on_async_exn run_tests
