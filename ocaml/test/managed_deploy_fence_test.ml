open Async
open Core

let assert_unavailable = function
  | Ok _ -> failwith "managed deployment unexpectedly succeeded"
  | Error error ->
      assert (
        String.equal (Error.to_string_hum error)
          "NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE: immutable revision admission, \
           root-owned source custody, and authoritative target-lease broker \
           integration are required before managed deployment")

let run () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-managed-deploy-fence-" "" in
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
    Nixploy.Application.preview_managed_deployment application managed
  in
  assert_unavailable preview;
  let%bind preview_started =
    Nixploy.Application.start_managed_preview application managed ~receipt:"x"
  in
  assert_unavailable preview_started;
  let%bind preview_deployed =
    Nixploy.Application.deploy_managed_preview application managed ~receipt:"x"
  in
  assert_unavailable preview_deployed;
  [%test_eq: int] 0 !preview_calls;
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
