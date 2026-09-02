open Async
open Core

module Managed_deployment_rpc = Nixploy_rpc_mapping.Managed_deployment_rpc

let unavailable =
  "NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE: immutable revision admission, \
   root-owned source custody, and authoritative target-lease broker \
   integration are required before managed deployment"

let assert_unavailable = function
  | Ok _ -> failwith "managed deployment RPC unexpectedly succeeded"
  | Error error -> [%test_eq: string] unavailable (Error.to_string_hum error)

let assert_no_deployments store =
  let%map deployments = Nixploy.Store.list store ~limit:10 in
  [%test_eq: int] 0 (List.length (Or_error.ok_exn deployments))

let run () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-managed-deploy-rpc-" "" in
  let%bind store =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = Or_error.ok_exn store in
  let managed =
    Nixploy.Managed_application.all_of_json
      (sprintf
         {|{"example":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"owner/example","nonProduction":{"host":"target.example.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"example-production"}}}|}
         directory)
    |> Or_error.ok_exn |> List.hd_exn
  in
  let preview_calls = ref 0 in
  let deploy_calls = ref 0 in
  let application =
    Nixploy.Application.For_testing.create ~store
      ~managed_applications:[ managed ]
      ~preview_main:(fun ~working_directory:_ ->
        incr preview_calls;
        Deferred.Or_error.error_string "preview must not run")
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.error_string "commit lookup must not run")
      ~deploy:(fun ~authorization:_ ~prepared:_ ->
        incr deploy_calls;
        Deferred.Or_error.error_string "deployment must not run")
      ~prune:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "prune must not run")
      ()
  in
  let%bind preview =
    Managed_deployment_rpc.preview ~applications:[ managed ] ~application
      { Protocol.Preview_deployment.Query.application = "example" }
  in
  assert_unavailable preview;
  let%bind started =
    Managed_deployment_rpc.start ~applications:[ managed ] ~application
      { Protocol.Deploy.Query.application = "example" }
  in
  assert_unavailable started;
  let%bind () = assert_no_deployments store in
  [%test_eq: int] 0 !preview_calls;
  [%test_eq: int] 0 !deploy_calls;
  Deferred.unit

let () =
  don't_wait_for
    (Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1);
  never_returns (Scheduler.go ())
