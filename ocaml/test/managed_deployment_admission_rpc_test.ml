open Async
open Core
module Admission = Nixploy.Managed_deployment_admission
module Admission_rpc = Nixploy_rpc_mapping.Managed_deployment_admission_rpc

let broker_unconfigured =
  "NIXPLOY_MANAGED_DEPLOY_BROKER_UNCONFIGURED: the requested revision passed \
   root-owned source custody verification, but authoritative target-lease \
   broker admission is not configured"

let authority_mismatch_prefix = "NIXPLOY_MANAGED_DEPLOY_AUTHORITY_MISMATCH:"
let invalid_prefix = "NIXPLOY_MANAGED_DEPLOY_REQUEST_INVALID:"

let assert_error_prefix prefix = function
  | Ok _ -> failwith "managed deployment admission unexpectedly succeeded"
  | Error error -> assert (String.is_prefix (Error.to_string_hum error) ~prefix)

let query ?(managed_application_key = "example")
    ?(requested_target = "production")
    ?(provenance = "ssh://git@example.invalid/example.git")
    ?(revision = "0123456789abcdef0123456789abcdef01234567") () =
  {
    Protocol.Admit_managed_deployment.Query.capability_grant = "test-grant";
    managed_application_key;
    requested_target;
    provenance;
    revision;
  }

let managed_application directory =
  Nixploy.Managed_application.all_of_json
    (sprintf
       {|{"example":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"owner/example","repositoryProvenance":"ssh://git@example.invalid/example.git","nonProduction":{"host":"target.example.invalid","user":"deploy","port":22,"kind":"non-web","coordinationScope":"example-production"}}}|}
       directory)
  |> Or_error.ok_exn |> List.hd_exn

let assert_request_validation () =
  let accepted =
    Admission.create ~managed_application_key:"example"
      ~requested_target:"production"
      ~provenance:"ssh://git@example.invalid/example.git"
      ~revision:"0123456789abcdef0123456789abcdef01234567"
    |> Or_error.ok_exn
  in
  [%test_eq: string] "example" (Admission.managed_application_key accepted);
  [%test_eq: string] "production"
    (Nixploy.Target_name.to_string (Admission.requested_target accepted));
  let maximum_target = String.make 255 't' in
  Admission.create ~managed_application_key:"example"
    ~requested_target:maximum_target ~provenance:"origin"
    ~revision:"0123456789abcdef0123456789abcdef01234567"
  |> Or_error.ok_exn |> ignore;
  List.iter
    [
      Admission.create ~managed_application_key:"EXAMPLE"
        ~requested_target:"production" ~provenance:"origin"
        ~revision:"0123456789abcdef0123456789abcdef01234567";
      Admission.create ~managed_application_key:"example" ~requested_target:""
        ~provenance:"origin"
        ~revision:"0123456789abcdef0123456789abcdef01234567";
      Admission.create ~managed_application_key:"example"
        ~requested_target:(String.make 256 't') ~provenance:"origin"
        ~revision:"0123456789abcdef0123456789abcdef01234567";
      Admission.create ~managed_application_key:"example"
        ~requested_target:"production" ~provenance:"\n"
        ~revision:"0123456789abcdef0123456789abcdef01234567";
      Admission.create ~managed_application_key:"example"
        ~requested_target:"production" ~provenance:"origin"
        ~revision:"0123456789ABCDEF0123456789abcdef01234567";
      Admission.create ~managed_application_key:"example"
        ~requested_target:"production" ~provenance:"origin"
        ~revision:"0123456789abcdef0123456789abcdef0123456";
    ]
    ~f:(assert_error_prefix invalid_prefix)

let assert_protocol_encoding () =
  let encoded =
    Bin_prot.Utils.bin_dump
      [%bin_writer: Protocol.Admit_managed_deployment.Query.t] (query ())
  in
  assert (Bigarray.Array1.dim encoded > 0)

let run () =
  let directory = Filename_unix.temp_dir "nixploy-managed-admission-rpc-" "" in
  let applications = [ managed_application directory ] in
  let revision = "0123456789abcdef0123456789abcdef01234567" in
  let%bind store =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = Or_error.ok_exn store in
  let source_verifications = ref 0 in
  let source_is_valid = ref true in
  let deploy_calls = ref 0 in
  let application =
    Nixploy.Application.For_testing.create ~store
      ~preview_main:(fun ~working_directory:_ ->
        Deferred.Or_error.error_string "preview must not run")
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.error_string "commit lookup must not run")
      ~verify_managed_source:(fun _application ~revision:requested_revision ->
        incr source_verifications;
        if not !source_is_valid then
          Deferred.Or_error.error_string "NIXPLOY_SOURCE_CUSTODY_MISMATCH: fixture"
        else
          let commit =
            Nixploy.Source.For_testing.commit ~revision:requested_revision
              ~subject:"fixture" ~timestamp_ms:0L
            |> Or_error.ok_exn
          in
          Deferred.Or_error.return
            (Nixploy.Source_authority.For_testing.create ~commit
               ~provenance:"ssh://git@example.invalid/example.git"
               ~reference:"refs/heads/main" ~evidence_digest:"fixture"
               ~repository_root:directory))
      ~deploy:(fun ~authorization:_ ~prepared:_ ->
        incr deploy_calls;
        Deferred.Or_error.error_string "deployment must not run")
      ~prune:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "prune must not run")
      ()
  in
  assert_request_validation ();
  assert_protocol_encoding ();
  let%bind unavailable_result =
    Admission_rpc.handle ~applications ~application (query ~revision ())
  in
  assert_error_prefix broker_unconfigured unavailable_result;
  [%test_eq: int] 1 !source_verifications;
  [%test_eq: int] 0 !deploy_calls;
  source_is_valid := false;
  let%bind custody_mismatch =
    Admission_rpc.handle ~applications ~application (query ~revision ())
  in
  assert_error_prefix "NIXPLOY_SOURCE_CUSTODY_MISMATCH:" custody_mismatch;
  [%test_eq: int] 2 !source_verifications;
  [%test_eq: int] 0 !deploy_calls;
  source_is_valid := true;
  let%bind target_mismatch =
    Admission_rpc.handle ~applications ~application
      (query ~requested_target:"staging" ())
  in
  assert_error_prefix authority_mismatch_prefix target_mismatch;
  let%bind provenance_mismatch =
    Admission_rpc.handle ~applications ~application (query ~provenance:"other" ())
  in
  assert_error_prefix authority_mismatch_prefix provenance_mismatch;
  let%bind key_mismatch =
    Admission_rpc.handle ~applications ~application
      (query ~managed_application_key:"other" ())
  in
  assert_error_prefix authority_mismatch_prefix key_mismatch;
  let%bind malformed =
    Admission_rpc.handle ~applications ~application (query ~revision:"not-a-sha" ())
  in
  assert_error_prefix invalid_prefix malformed;
  [%test_eq: int] 2 !source_verifications;
  [%test_eq: int] 0 !deploy_calls;
  Deferred.unit

let () =
  don't_wait_for
    ( Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
