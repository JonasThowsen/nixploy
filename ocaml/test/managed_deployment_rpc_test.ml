open Async
open Core

module Managed_deployment_rpc = Nixploy_rpc_mapping.Managed_deployment_rpc

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
         {|{"example":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"owner/example","repositoryProvenance":"ssh://git@example.invalid/example.git","repositoryReference":"refs/heads/main","repositoryEvidenceFile":"/var/lib/nixploy/example.evidence.json","production":{"host":"target.example.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"example-production"}}}|}
         directory)
    |> Or_error.ok_exn |> List.hd_exn
  in
  let commit =
    Nixploy.Application.For_testing.commit
      ~revision:"0123456789abcdef0123456789abcdef01234567"
      ~subject:"managed fixture" ~timestamp_ms:0L
    |> Or_error.ok_exn
  in
  let source =
    Nixploy.Application.For_testing.local_source ~working_directory:directory
      commit
  in
  let source_authority_commit =
    Nixploy.Source.For_testing.commit
      ~revision:"0123456789abcdef0123456789abcdef01234567"
      ~subject:"managed fixture" ~timestamp_ms:0L
    |> Or_error.ok_exn
  in
  let source_authority =
    Nixploy.Source_authority.For_testing.create ~commit:source_authority_commit
      ~provenance:"ssh://git@example.invalid/example.git"
      ~reference:"refs/heads/main" ~evidence_digest:"fixture"
      ~repository_root:directory
  in
  let source_verifications = ref 0 in
  let deploy_calls = ref 0 in
  let application =
    Nixploy.Application.For_testing.create ~store
      ~managed_applications:[ managed ]
      ~preview_main:(fun ~working_directory:_ ->
        Deferred.Or_error.error_string "preview must not run")
      ~local_source:(fun ~working_directory ->
        [%test_eq: string] directory working_directory;
        Deferred.Or_error.return source)
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.error_string "commit lookup must not run")
      ~verify_managed_source:(fun verified ~revision ->
        incr source_verifications;
        [%test_eq: string] "example" (Nixploy.Managed_application.key verified);
        [%test_eq: string] "0123456789abcdef0123456789abcdef01234567" revision;
        Deferred.Or_error.return source_authority)
      ~deploy:(fun ~authorization ~prepared:_ ->
        incr deploy_calls;
        [%test_eq: string] "example"
          (Nixploy.Operation_receipt.deploy_application_key authorization
          |> Option.value_exn);
        [%test_eq: string] directory
          (Nixploy.Operation_receipt.deploy_working_directory authorization);
        [%test_eq: string] "production"
          (Nixploy.Operation_receipt.deploy_target authorization
          |> Nixploy.Target_name.to_string);
        [%test_eq: string] "example"
          (Nixploy.Operation_receipt.deploy_application authorization
          |> Option.value_exn |> Nixploy.Managed_application.key);
        let deployment =
          Nixploy.Application.For_testing.deployment ~id:"managed-operation"
            ~state:Nixploy.Application.Requested ()
        in
        Deferred.Or_error.return
          (deployment, Deferred.Or_error.return deployment))
      ~prune:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "prune must not run")
      ()
  in
  let%bind started =
    Managed_deployment_rpc.start ~applications:[ managed ] ~application
      { Protocol.Deploy.Query.application = "example" }
  in
  [%test_eq: string] "managed-operation" (Or_error.ok_exn started);
  [%test_eq: int] 1 !source_verifications;
  [%test_eq: int] 1 !deploy_calls;
  let%bind invalid =
    Managed_deployment_rpc.start ~applications:[ managed ] ~application
      { Protocol.Deploy.Query.application = "other" }
  in
  assert (Result.is_error invalid);
  [%test_eq: int] 1 !source_verifications;
  [%test_eq: int] 1 !deploy_calls;
  Deferred.unit

let () =
  don't_wait_for
    (Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1);
  never_returns (Scheduler.go ())
