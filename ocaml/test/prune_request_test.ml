open Async
open Core
module Prune_request = Nixploy_rpc_mapping.Prune_request

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-prune-request-test-" "" in
  let applications =
    sprintf
      {|{"example":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"owner/example"}}|}
      directory
    |> Nixploy.Managed_application.all_of_json |> assert_ok
  in
  let application = List.hd_exn applications in
  let project = Nixploy.Managed_application.project application in
  let target = Nixploy.Managed_application.target application in
  let resource_key =
    Nixploy.Resource_key.derive ~project ~target
      ~repository_identity:"git@example.invalid:example.git"
    |> assert_ok
  in
  let application_result =
    Nixploy.Application.For_testing.prune_result ~project ~target ~resource_key
      ~containers_removed:2 ~secrets_removed:1
      ~route:Nixploy.Application.Missing
  in
  let prune_calls = ref [] in
  let invalidated = ref [] in
  let prune ~expected_project ~repository_identity ~working_directory ~target =
    prune_calls :=
      (expected_project, repository_identity, working_directory, target)
      :: !prune_calls;
    Deferred.Or_error.return application_result
  in
  let on_started ~application_key =
    invalidated := application_key :: !invalidated
  in
  let query = { Protocol.Prune.Query.application = "example" } in
  let%bind success =
    Prune_request.handle ~applications ~prune ~on_started query
  in
  let success = assert_ok success in
  assert (String.equal success.project "example");
  assert (String.equal success.target "production");
  assert (Int.equal success.containers_removed 2);
  assert (Int.equal success.secrets_removed 1);
  assert ([%equal: Protocol.Prune_result.Route.t] success.route Missing);
  [%test_eq: string list] [ "example" ] !invalidated;
  [%test_eq:
    (Nixploy.Project_name.t * string * string * Nixploy.Target_name.t) list]
    [ (project, "owner/example", directory, target) ]
    !prune_calls;
  let failed_prune ~expected_project ~repository_identity ~working_directory:_
      ~target:_ =
    assert (String.equal repository_identity "owner/example");
    assert (Nixploy.Project_name.equal expected_project project);
    Deferred.Or_error.error_string "partial cleanup failed"
  in
  let%bind failure =
    Prune_request.handle ~applications ~prune:failed_prune ~on_started query
  in
  assert (Result.is_error failure);
  [%test_eq: string list] [ "example"; "example" ] !invalidated;
  let%map unknown =
    Prune_request.handle ~applications ~prune ~on_started
      { Protocol.Prune.Query.application = "unknown" }
  in
  assert (Result.is_error unknown);
  [%test_eq: int] 1 (List.length !prune_calls);
  [%test_eq: string list] [ "example"; "example" ] !invalidated

let () = Thread_safe.block_on_async_exn run_tests
