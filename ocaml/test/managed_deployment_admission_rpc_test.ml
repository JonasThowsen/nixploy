open Async
open Core
module Admission = Nixploy.Managed_deployment_admission
module Admission_rpc = Nixploy_rpc_mapping.Managed_deployment_admission_rpc

let unavailable =
  "NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE: immutable revision admission, \
   root-owned source custody, and authoritative target-lease broker \
   integration are required before managed deployment"

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
  assert_request_validation ();
  assert_protocol_encoding ();
  let%bind unavailable_result = Admission_rpc.handle ~applications (query ()) in
  assert_error_prefix unavailable unavailable_result;
  let%bind target_mismatch =
    Admission_rpc.handle ~applications (query ~requested_target:"staging" ())
  in
  assert_error_prefix authority_mismatch_prefix target_mismatch;
  let%bind provenance_mismatch =
    Admission_rpc.handle ~applications (query ~provenance:"other" ())
  in
  assert_error_prefix authority_mismatch_prefix provenance_mismatch;
  let%bind key_mismatch =
    Admission_rpc.handle ~applications
      (query ~managed_application_key:"other" ())
  in
  assert_error_prefix authority_mismatch_prefix key_mismatch;
  let%bind malformed =
    Admission_rpc.handle ~applications (query ~revision:"not-a-sha" ())
  in
  assert_error_prefix invalid_prefix malformed;
  Deferred.unit

let () =
  don't_wait_for
    ( Monitor.try_with run >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
