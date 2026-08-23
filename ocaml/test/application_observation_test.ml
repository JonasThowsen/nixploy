open Async
open Core

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let managed directory key =
  sprintf
    {|{"%s":{"project":"example","target":"production","repository":"%s","repositoryIdentity":"git@example.invalid:example.git"}}|}
    key directory
  |> Nixploy.Managed_application.all_of_json |> assert_ok |> List.hd_exn

let run_tests () =
  let open Deferred.Let_syntax in
  let directory =
    Filename_unix.temp_dir "nixploy-application-observation-" ""
  in
  let other_directory = Filename_unix.temp_dir "nixploy-other-" "" in
  let%bind opened =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = assert_ok opened in
  let target = Nixploy.Target_name.of_string "production" |> assert_ok in
  let revision = String.make 40 'd' in
  let commit =
    Nixploy.Application.For_testing.commit ~revision ~subject:"Observed commit"
      ~timestamp_ms:42L
    |> assert_ok
  in
  let store_commit =
    Nixploy.Source.For_testing.commit ~revision ~subject:"Observed commit"
      ~timestamp_ms:42L
    |> assert_ok
  in
  let source =
    Nixploy.Application.For_testing.local_source ~working_directory:directory
      commit
  in
  let application = managed directory "example" in
  let other_application = managed directory "other" in
  let status_calls = ref 0 in
  let log_calls = ref [] in
  let metric_calls = ref [] in
  let started = Ivar.create () in
  let fake =
    Nixploy.Application.For_testing.create ~store
      ~status:(fun ~scope:_ ->
        Int.incr status_calls;
        Deferred.Or_error.error_string "status boundary reached")
      ~logs:(fun application ->
        log_calls := Nixploy.Managed_application.key application :: !log_calls;
        Deferred.Or_error.return
          {
            Nixploy.Application.container_name = "example-production-green";
            revision = Some revision;
            observed_at_ms = 100L;
            lines = [ { timestamp = Some "2025-01-01T00:00:00Z"; text = "ok" } ];
            truncated = false;
          })
      ~metrics:(fun application ->
        metric_calls :=
          Nixploy.Managed_application.key application :: !metric_calls;
        Deferred.return
          {
            Nixploy.Application.target = "production";
            host = "deploy@example.invalid:22";
            observed_at_ms = 101L;
            error = None;
            cpu_percent = Some 10.;
            memory_used_bytes = Some 20L;
            memory_total_bytes = Some 100L;
            filesystem_used_bytes = Some 30L;
            filesystem_total_bytes = Some 200L;
            load_1 = Some 1.;
            load_5 = Some 2.;
            load_15 = Some 3.;
            uptime_seconds = Some 40L;
            applications =
              [
                {
                  Nixploy.Application.application =
                    Nixploy.Managed_application.key application;
                  container_name = Some "example-production-green";
                  health = Healthy;
                  error = None;
                  cpu_percent = Some 4.;
                  memory_used_bytes = Some 5L;
                  memory_host_percent = Some 5.;
                  uptime_seconds = Some 6L;
                };
              ];
          })
      ~preview_main:(fun ~working_directory:_ ->
        Deferred.Or_error.return commit)
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.return commit)
      ~deploy:(fun ~on_stage:_ ~on_requested ~on_authorized ~authorization ->
        let application_key =
          Nixploy.Operation_receipt.deploy_application_key authorization
        and working_directory =
          Nixploy.Operation_receipt.deploy_working_directory authorization
        and target = Nixploy.Operation_receipt.deploy_target authorization in
        let open Deferred.Or_error.Let_syntax in
        let%bind () = on_authorized () in
        let%bind stored =
          Nixploy.Store.request store ~application_key ~working_directory
            ~target ~commit:store_commit
        in
        let operation =
          Nixploy.Application.For_testing.deployment ?application_key
            ~working_directory ~target ~id:(Nixploy.Store.id stored)
            ~state:Running ~revision ()
        in
        on_requested operation;
        Ivar.fill_if_empty started operation;
        let cancellation =
          Nixploy.Cancellation.current () |> Option.value_exn
        in
        let%bind.Deferred () = Nixploy.Cancellation.requested cancellation in
        let%bind persisted =
          Nixploy.Store.find store ~id:(Nixploy.Store.id stored)
        in
        assert (
          Option.bind persisted ~f:Nixploy.Store.cancel_requested_at_ms
          |> Option.is_some);
        assert (Nixploy.Cancellation.acknowledge_current ());
        let%bind () =
          Nixploy.Store.cancel store ~id:(Nixploy.Store.id stored)
        in
        Deferred.Or_error.return
          (Nixploy.Application.For_testing.deployment ?application_key
             ~working_directory ~target ~id:(Nixploy.Store.id stored)
             ~state:Cancelled ~revision ()))
      ~prune:(fun ~on_authorized:_ ~authorization:_ ->
        Deferred.Or_error.error_string "unused prune")
      ()
  in
  let scope = Nixploy.Application.managed_scope application |> assert_ok in
  let other_scope =
    Nixploy.Application.managed_scope other_application |> assert_ok
  in
  let%bind status = Nixploy.Application.live_status fake ~scope in
  assert (Result.is_error status);
  [%test_eq: int] 1 !status_calls;
  let%bind logs = Nixploy.Application.application_logs fake application in
  let logs = assert_ok logs in
  [%test_eq: string] "example-production-green" logs.container_name;
  [%test_eq: int] 1 (List.length logs.lines);
  let%bind metrics = Nixploy.Application.application_metrics fake application in
  [%test_eq: string] "production" metrics.target;
  [%test_eq: string list] [ "example" ] (List.rev !log_calls);
  [%test_eq: string list] [ "example" ] (List.rev !metric_calls);
  let running =
    Nixploy.Application.deploy_non_production ~application_key:"example" fake
      ~working_directory:directory ~source ~target ()
  in
  let%bind operation = Ivar.read started in
  let operation_id = Nixploy.Application.deployment_id operation in
  let%bind history =
    Nixploy.Application.deployment_history fake ~scope ~limit:25
  in
  let history = assert_ok history in
  assert (
    List.exists history ~f:(fun item ->
        String.equal operation_id (Nixploy.Application.deployment_id item)));
  let active =
    List.find_exn history ~f:(fun item ->
        String.equal operation_id (Nixploy.Application.deployment_id item))
  in
  assert (Nixploy.Application.deployment_can_cancel fake ~scope active);
  let%bind wrong_owner =
    Nixploy.Application.cancel_deployment fake ~scope:other_scope ~operation_id
  in
  assert (Result.is_error wrong_owner);
  assert (not (Deferred.is_determined running));
  let%bind unchanged = Nixploy.Store.find store ~id:operation_id in
  assert (
    Option.bind (assert_ok unchanged) ~f:Nixploy.Store.cancel_requested_at_ms
    |> Option.is_none);
  let%bind cancellation =
    Nixploy.Application.cancel_deployment fake ~scope ~operation_id
  in
  assert (
    [%equal: Nixploy.Application.cancellation_result] (assert_ok cancellation)
      Cancellation_requested);
  let%bind completed = running in
  let completed = assert_ok completed in
  assert (
    [%equal: Nixploy.Application.deployment_state]
      (Nixploy.Application.deployment_state completed)
      Cancelled);
  let%bind interrupted =
    Nixploy.Store.request store ~application_key:(Some "example")
      ~working_directory:directory ~target ~commit:store_commit
  in
  let interrupted = assert_ok interrupted in
  let%bind foreign =
    Nixploy.Store.request store ~application_key:(Some "other")
      ~working_directory:directory ~target ~commit:store_commit
  in
  let foreign = assert_ok foreign in
  let%bind stale_identity =
    Nixploy.Store.request store ~application_key:(Some "example")
      ~working_directory:other_directory ~target ~commit:store_commit
  in
  let stale_identity = assert_ok stale_identity in
  let restarted = Nixploy.Application.create ~store () in
  let%bind not_active =
    Nixploy.Application.cancel_deployment restarted ~scope
      ~operation_id:(Nixploy.Store.id interrupted)
  in
  assert (Result.is_error not_active);
  assert (
    Result.error not_active |> Option.value_exn |> Error.to_string_hum
    |> String.is_substring ~substring:"not active in this control-plane process");
  let%bind not_owned =
    Nixploy.Application.cancel_deployment restarted ~scope
      ~operation_id:(Nixploy.Store.id foreign)
  in
  assert (Result.is_error not_owned);
  let%bind restarted_history =
    Nixploy.Application.deployment_history restarted ~scope ~limit:100
  in
  let restarted_history = assert_ok restarted_history in
  assert (
    List.exists restarted_history ~f:(fun deployment ->
        String.equal
          (Nixploy.Store.id interrupted)
          (Nixploy.Application.deployment_id deployment)));
  assert (
    not
      (List.exists restarted_history ~f:(fun deployment ->
           String.equal (Nixploy.Store.id foreign)
             (Nixploy.Application.deployment_id deployment))));
  assert (
    not
      (List.exists restarted_history ~f:(fun deployment ->
           String.equal
             (Nixploy.Store.id stale_identity)
             (Nixploy.Application.deployment_id deployment))));
  let%bind invalid_limit =
    Nixploy.Application.deployment_history restarted ~scope ~limit:101
  in
  assert (Result.is_error invalid_limit);
  let calls = ref [] in
  let persisted_error = ref None in
  let%bind reconciled =
    Nixploy.Tracked_deployment.For_testing.terminalize_cancelled
      ~request_marker:(fun () ->
        calls := "marker" :: !calls;
        Deferred.Or_error.error_string "marker unavailable")
      ~cancel:(fun () ->
        calls := "cancel" :: !calls;
        Deferred.Or_error.error_string "cancel write unavailable")
      ~fail:(fun error ->
        calls := "fail" :: !calls;
        persisted_error := Some (Error.to_string_hum error);
        Deferred.Or_error.return ())
      ~find_state:(fun () -> Deferred.Or_error.return None)
      ~execution_error:(Error.of_string "execution cancelled")
  in
  assert_ok reconciled;
  [%test_eq: string list] [ "marker"; "cancel"; "fail" ] (List.rev !calls);
  let persisted_error = Option.value_exn !persisted_error in
  assert (String.is_substring persisted_error ~substring:"marker unavailable");
  assert (
    String.is_substring persisted_error ~substring:"cancel write unavailable");
  let%bind unpersisted =
    Nixploy.Tracked_deployment.For_testing.terminalize_cancelled
      ~request_marker:(fun () -> Deferred.Or_error.return ())
      ~cancel:(fun () -> Deferred.Or_error.error_string "cancel failed")
      ~fail:(fun _ -> Deferred.Or_error.error_string "failure write failed")
      ~find_state:(fun () ->
        Deferred.Or_error.return (Some Nixploy.Store.Running))
      ~execution_error:(Error.of_string "execution cancelled")
  in
  assert (Result.is_error unpersisted);
  let error =
    Result.error unpersisted |> Option.value_exn |> Error.to_string_hum
  in
  assert (String.is_substring error ~substring:"terminal failure persistence");
  Deferred.unit

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
