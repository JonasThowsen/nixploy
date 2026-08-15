open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-application-test-" "" in
  let%bind opened =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = assert_ok opened in
  let main_revision = String.make 40 'a' in
  let selected_revision = String.make 40 'b' in
  let main_commit =
    Nixploy.Application.For_testing.commit ~revision:main_revision
      ~subject:"Main commit" ~timestamp_ms:1_000L
    |> assert_ok
  in
  let selected_commit =
    Nixploy.Application.For_testing.commit ~revision:selected_revision
      ~subject:"Selected commit" ~timestamp_ms:2_000L
    |> assert_ok
  in
  let deployed = ref [] in
  let deployment_state = ref Nixploy.Application.Succeeded in
  let deployment_error = ref None in
  let deployment_started = ref None in
  let deployment_gate = ref None in
  let pruned = ref [] in
  let prune_error = ref None in
  let project = Nixploy.Project_name.of_string "example" |> assert_ok in
  let prune_target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let prune_resource =
    Nixploy.Resource_key.derive ~project ~target:prune_target |> assert_ok
  in
  let prune_result =
    Nixploy.Application.For_testing.prune_result ~project ~target:prune_target
      ~resource_key:prune_resource ~containers_removed:2 ~secrets_removed:3
      ~route:Nixploy.Application.Removed
  in
  let application =
    Nixploy.Application.For_testing.create ~store
      ~preview_main:(fun ~working_directory ->
        assert (String.equal working_directory directory);
        Deferred.Or_error.return main_commit)
      ~find_commit:(fun ~working_directory ~revision ->
        assert (String.equal working_directory directory);
        assert (String.equal revision selected_revision);
        Deferred.Or_error.return selected_commit)
      ~deploy:(fun
          ~on_stage
          ~on_requested
          ~application_key
          ~expected_project
          ~working_directory
          ~commit
          ~target:_
          ()
        ->
        let revision = Nixploy.Application.commit_revision commit in
        Option.iter !deployment_started ~f:(fun started ->
            Ivar.fill_if_empty started ());
        let%bind () =
          Option.value_map !deployment_gate ~default:Deferred.unit ~f:Ivar.read
        in
        match !deployment_error with
        | Some error -> Deferred.return (Error error)
        | None ->
            let deployment =
              Nixploy.Application.For_testing.deployment
                ~id:("deployment-" ^ String.prefix revision 1)
                ~state:!deployment_state ~revision ()
            in
            deployed :=
              (application_key, expected_project, working_directory, revision)
              :: !deployed;
            let%map () =
              on_stage Nixploy.Deployment.Preparing_source revision
            in
            on_requested deployment;
            Ok deployment)
      ~prune:(fun ~expected_project ~working_directory ~target ->
        pruned := (expected_project, working_directory, target) :: !pruned;
        match !prune_error with
        | None -> Deferred.Or_error.return prune_result
        | Some error -> Deferred.return (Error error))
  in
  let target = prune_target in
  let stages = ref [] in
  let requested = ref [] in
  let on_stage stage message =
    stages := (stage, message) :: !stages;
    Deferred.unit
  in
  let on_requested deployment =
    requested := Nixploy.Application.deployment_id deployment :: !requested
  in
  let%bind preview =
    Nixploy.Application.preview_main_commit application
      ~working_directory:directory
  in
  let preview = assert_ok preview in
  assert (
    String.equal main_revision (Nixploy.Application.commit_revision preview));
  let%bind cli_result =
    Nixploy.Application.deploy ~on_stage ~on_requested application
      ~working_directory:directory ~commit:preview ~target ()
  in
  let cli_deployment = assert_ok cli_result in
  assert (
    String.equal main_revision
      (Nixploy.Application.deployment_revision cli_deployment
      |> Option.value_exn));
  let%bind resolved =
    Nixploy.Application.resolve_commit application ~working_directory:directory
      ~revision:selected_revision
  in
  let resolved = assert_ok resolved in
  assert (
    String.equal selected_revision
      (Nixploy.Application.commit_revision resolved));
  let%bind rpc_result =
    Nixploy.Application.deploy ~on_stage ~on_requested
      ~application_key:"example" ~expected_project:project application
      ~working_directory:directory ~commit:resolved ~target ()
  in
  let rpc_deployment = assert_ok rpc_result in
  assert (
    String.equal selected_revision
      (Nixploy.Application.deployment_revision rpc_deployment
      |> Option.value_exn));
  [%test_eq:
    (string option * Nixploy.Project_name.t option * string * string) list]
    [
      (None, None, directory, main_revision);
      (Some "example", Some project, directory, selected_revision);
    ]
    (List.rev !deployed);
  [%test_eq: (Nixploy.Deployment.stage * string) list]
    [ (Preparing_source, main_revision); (Preparing_source, selected_revision) ]
    (List.rev !stages);
  [%test_eq: string list]
    [ "deployment-a"; "deployment-b" ]
    (List.rev !requested);
  let%bind deployed_resources =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state]
      (assert_ok deployed_resources)
      Present);
  let store_commit =
    Nixploy.Source.For_testing.commit ~revision:selected_revision
      ~subject:"Interrupted deployment" ~timestamp_ms:2_000L
    |> assert_ok
  in
  let%bind interrupted =
    Nixploy.Store.request store ~application_key:(Some "example")
      ~working_directory:directory ~target ~commit:store_commit
  in
  ignore (assert_ok interrupted : Nixploy.Store.deployment);
  let%bind prune =
    Nixploy.Application.prune application ~working_directory:directory ~target
  in
  let prune = assert_ok prune in
  [%test_eq: int] 2 (Nixploy.Application.prune_containers_removed prune);
  [%test_eq: int] 3 (Nixploy.Application.prune_secrets_removed prune);
  let%bind absent =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert ([%equal: Nixploy.Application.resource_state] (assert_ok absent) Absent);
  prune_error := Some (Error.of_string "cleanup stopped after one container");
  let%bind failed_prune =
    Nixploy.Application.prune application ~working_directory:directory ~target
  in
  assert (Result.is_error failed_prune);
  let%bind unknown =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state] (assert_ok unknown) Unknown);
  let%bind reopened =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let restarted = Nixploy.Application.create ~store:(assert_ok reopened) () in
  let%bind read_back =
    Nixploy.Application.resource_state restarted ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state] (assert_ok read_back) Unknown);
  deployment_state := Failed;
  let%bind failed_deployment =
    Nixploy.Application.deploy application ~working_directory:directory
      ~commit:resolved ~target ()
  in
  assert (
    [%equal: Nixploy.Application.deployment_state]
      (Nixploy.Application.deployment_state (assert_ok failed_deployment))
      Failed);
  let%bind failed_state =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state] (assert_ok failed_state)
      Unknown);
  deployment_state := Cancelled;
  let%bind cancelled_deployment =
    Nixploy.Application.deploy application ~working_directory:directory
      ~commit:resolved ~target ()
  in
  assert (
    [%equal: Nixploy.Application.deployment_state]
      (Nixploy.Application.deployment_state (assert_ok cancelled_deployment))
      Cancelled);
  let%bind cancelled_state =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state]
      (assert_ok cancelled_state)
      Unknown);
  deployment_state := Succeeded;
  prune_error := None;
  let deploy_started = Ivar.create () in
  let release_deploy = Ivar.create () in
  deployment_started := Some deploy_started;
  deployment_gate := Some release_deploy;
  let waiting_deploy =
    Nixploy.Application.deploy application ~working_directory:directory
      ~commit:resolved ~target ()
  in
  let%bind () = Ivar.read deploy_started in
  let prunes_before_wait = List.length !pruned in
  let waiting_prune =
    Nixploy.Application.prune application ~working_directory:directory ~target
  in
  let%bind () = Clock_ns.after (Time_ns.Span.of_ms 50.) in
  assert (not (Deferred.is_determined waiting_prune));
  [%test_eq: int] prunes_before_wait (List.length !pruned);
  Ivar.fill_exn release_deploy ();
  let%bind deployment_after_wait = waiting_deploy in
  ignore (assert_ok deployment_after_wait : Nixploy.Application.deployment);
  let%bind prune_after_wait = waiting_prune in
  ignore (assert_ok prune_after_wait : Nixploy.Application.prune_result);
  deployment_started := None;
  deployment_gate := None;
  let%bind final_state =
    Nixploy.Application.resource_state application ~working_directory:directory
      ~target
  in
  assert (
    [%equal: Nixploy.Application.resource_state] (assert_ok final_state) Absent);
  [%test_eq:
    (Nixploy.Project_name.t option * string * Nixploy.Target_name.t) list]
    [
      (None, directory, target);
      (None, directory, target);
      (None, directory, target);
    ]
    (List.rev !pruned);
  Deferred.unit

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
