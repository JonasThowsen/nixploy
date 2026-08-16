open Async
open Core
module Cancellation_request = Nixploy_rpc_mapping.Cancellation_request

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run_tests () =
  let directory = Filename_unix.temp_dir "nixploy-cancel-request-test-" "" in
  let applications =
    sprintf
      {|{"example":{"project":"example","target":"production","repository":"%s"}}|}
      directory
    |> Nixploy.Managed_application.all_of_json |> assert_ok
  in
  let calls = ref [] in
  let cancel ~application ~operation_id =
    calls :=
      (Nixploy.Managed_application.key application, operation_id) :: !calls;
    Deferred.Or_error.return ()
  in
  let%bind success =
    Cancellation_request.handle ~applications ~cancel
      {
        Protocol.Cancel_deployment_v1.Query.application = "example";
        operation_id = "operation-123";
      }
  in
  ignore (assert_ok success : unit);
  [%test_eq: (string * string) list] [ ("example", "operation-123") ] !calls;
  let%map unknown =
    Cancellation_request.handle ~applications ~cancel
      {
        Protocol.Cancel_deployment_v1.Query.application = "unknown";
        operation_id = "operation-123";
      }
  in
  assert (Result.is_error unknown);
  [%test_eq: int] 1 (List.length !calls)

let () = Thread_safe.block_on_async_exn run_tests
