open Async
open Core
module Observer = Nixploy_cli_mapping.Deployment_observer

type child_outcome = Succeed | Fail

let assert_ok = function
  | Ok value -> value
  | Error error -> failwith (Error.to_string_hum error)

let target = Nixploy.Target_name.of_string "production" |> assert_ok
let revision = String.make 40 'e'

let run_case ~on_operation ~render_stage ~history ~termination ~release_child
    ~expect =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-deployment-observer-" "" in
  let%bind store =
    Nixploy.Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = assert_ok store in
  let commit =
    Nixploy.Application.For_testing.commit ~revision ~subject:"Observer"
      ~timestamp_ms:1L
    |> assert_ok
  in
  let store_commit =
    Nixploy.Source.For_testing.commit ~revision ~subject:"Observer"
      ~timestamp_ms:1L
    |> assert_ok
  in
  let remote_effect = ref false in
  let child_started = Ivar.create () in
  let child_gate = Ivar.create () in
  let application =
    Nixploy.Application.For_testing.create ~store ~deployment_history:history
      ~preview_main:(fun ~working_directory:_ ->
        Deferred.Or_error.return commit)
      ~find_commit:(fun ~working_directory:_ ~revision:_ ->
        Deferred.Or_error.return commit)
      ~deploy:(fun ~authorization ~prepared:_ ->
        let application_key =
          Nixploy.Operation_receipt.deploy_application_key authorization
        in
        let working_directory =
          Nixploy.Operation_receipt.deploy_working_directory authorization
        in
        let target = Nixploy.Operation_receipt.deploy_target authorization in
        let open Deferred.Or_error.Let_syntax in
        let%bind requested =
          Nixploy.Store.request store ~application_key ~working_directory
            ~target ~commit:store_commit
        in
        let id = Nixploy.Store.id requested in
        let operation =
          Nixploy.Application.For_testing.deployment ?application_key
            ~working_directory ~target ~id ~state:Requested ~revision ()
        in
        on_operation id;
        let cancellation =
          Nixploy.Cancellation.current () |> Option.value_exn
        in
        Ivar.fill_if_empty child_started ();
        let completion =
          let%bind.Deferred outcome =
            Deferred.choose
              [
                Deferred.choice (Nixploy.Cancellation.requested cancellation)
                  (fun () -> `Cancelled);
                Deferred.choice (Ivar.read child_gate) (fun outcome ->
                    `Remote outcome);
              ]
          in
          match outcome with
          | `Cancelled ->
              assert (Nixploy.Cancellation.acknowledge_current ());
              let%map () = Nixploy.Store.cancel store ~id in
              Nixploy.Application.For_testing.deployment ?application_key
                ~working_directory ~target ~id ~state:Cancelled ~revision ()
          | `Remote Succeed ->
              remote_effect := true;
              let%map () =
                Nixploy.Store.succeed store ~id ~container_name:"fake"
                  ~message:"completed"
              in
              Nixploy.Application.For_testing.deployment ?application_key
                ~working_directory ~target ~id ~state:Succeeded ~revision ()
          | `Remote Fail ->
              remote_effect := true;
              let%map () =
                Nixploy.Store.fail store ~id
                  ~error:(Error.of_string "fake failure")
              in
              Nixploy.Application.For_testing.deployment ?application_key
                ~working_directory ~target ~id ~state:Failed ~revision
                ~error:"fake failure" ()
        in
        Deferred.Or_error.return (operation, completion))
      ~prune:(fun ~authorization:_ ~prepared:_ ->
        Deferred.Or_error.error_string "unused prune")
      ()
  in
  let source =
    Nixploy.Application.For_testing.local_source ~working_directory:directory
      commit
  in
  let%bind started =
    Nixploy.Application.start_direct_deployment application
      ~working_directory:directory ~source ~target ()
  in
  let started = assert_ok started in
  let scope =
    Nixploy.Application.local_scope ~working_directory:directory ~target
    |> assert_ok
  in
  let observed =
    Observer.observe_and_drain ~termination ~render_stage application ~scope
      started
  in
  let%bind () = Ivar.read child_started in
  let%bind () = release_child child_gate in
  let%bind observed = observed in
  expect observed !remote_effect;
  let%bind drained = Nixploy.Application.mutations_drained application in
  ignore drained;
  assert (
    Deferred.is_determined (Nixploy.Application.mutations_drained application));
  Deferred.unit

let run_tests () =
  let open Deferred.Let_syntax in
  let no_signal = Deferred.never () in
  let history_error ~scope:_ ~limit:_ =
    Deferred.Or_error.error_string "history unavailable"
  in
  let history_missing ~scope:_ ~limit:_ = Deferred.Or_error.return [] in
  let%bind () =
    run_case ~on_operation:(fun _ -> ()) ~render_stage:(fun _ _ -> ())
      ~history:history_error ~termination:no_signal
      ~release_child:(fun _ -> Deferred.unit)
      ~expect:(fun observed remote_effect ->
        assert (Result.is_error observed);
        assert (not remote_effect))
  in
  let%bind () =
    run_case ~on_operation:(fun _ -> ()) ~render_stage:(fun _ _ -> ())
      ~history:history_missing ~termination:no_signal
      ~release_child:(fun _ -> Deferred.unit)
      ~expect:(fun observed remote_effect ->
        assert (Result.is_error observed);
        assert (not remote_effect))
  in
  let signal = Ivar.create () in
  let%bind () =
    run_case ~on_operation:(fun _ -> ()) ~render_stage:(fun _ _ -> ())
      ~history:history_error ~termination:(Ivar.read signal)
      ~release_child:(fun _ ->
        Ivar.fill_exn signal Signal.int;
        Deferred.unit)
      ~expect:(fun observed remote_effect ->
        match observed with
        | Ok (Observer.Interrupted received) ->
            assert ([%equal: Signal.t] received Signal.int);
            assert (not remote_effect)
        | Ok (Observer.Completed _) | Error _ -> assert false)
  in
  let%bind () =
    run_case ~on_operation:(fun _ -> ()) ~render_stage:(fun _ _ -> ())
      ~history:(fun ~scope:_ ~limit:_ -> Deferred.never ())
      ~termination:no_signal
      ~release_child:(fun gate ->
        Ivar.fill_exn gate Succeed;
        Deferred.unit)
      ~expect:(fun observed remote_effect ->
        match observed with
        | Ok (Observer.Completed deployment) ->
            assert remote_effect;
            assert (
              [%equal: Nixploy.Application.deployment_state]
                (Nixploy.Application.deployment_state deployment)
                Succeeded)
        | Ok (Observer.Interrupted _) | Error _ -> assert false)
  in
  let observed_operation = ref None in
  let rendered_stages = ref [] in
  let rec release_after_stage gate remaining =
    if not (List.is_empty !rendered_stages) then (
      Ivar.fill_exn gate Succeed;
      Deferred.unit)
    else if remaining = 0 then failwith "observer did not render a durable stage"
    else
      let%bind () = Clock_ns.after (Time_ns.Span.of_ms 10.) in
      release_after_stage gate (remaining - 1)
  in
  let%bind () =
    run_case
      ~on_operation:(fun id -> observed_operation := Some id)
      ~render_stage:(fun stage message ->
        rendered_stages := (stage, message) :: !rendered_stages)
      ~history:(fun ~scope:_ ~limit:_ ->
        match !observed_operation with
        | None -> Deferred.Or_error.return []
        | Some id ->
            Deferred.Or_error.return
              [
                Nixploy.Application.For_testing.deployment ~id ~state:Running
                  ~stage:"building" ~message:"Building and loading the image"
                  ();
              ])
      ~termination:no_signal
      ~release_child:(fun gate -> release_after_stage gate 100)
      ~expect:(fun observed remote_effect ->
        assert remote_effect;
        assert (
          List.mem !rendered_stages
            ("building", "Building and loading the image")
            ~equal:[%equal: string * string]);
        match observed with
        | Ok (Observer.Completed deployment) ->
            assert (
              [%equal: Nixploy.Application.deployment_state]
                (Nixploy.Application.deployment_state deployment)
                Succeeded)
        | Ok (Observer.Interrupted _) | Error _ -> assert false)
  in
  run_case ~on_operation:(fun _ -> ()) ~render_stage:(fun _ _ -> ())
    ~history:(fun ~scope:_ ~limit:_ -> Deferred.never ())
    ~termination:no_signal
    ~release_child:(fun gate ->
      Ivar.fill_exn gate Fail;
      Deferred.unit)
    ~expect:(fun observed remote_effect ->
      match observed with
      | Ok (Observer.Completed deployment) ->
          assert remote_effect;
          assert (
            [%equal: Nixploy.Application.deployment_state]
              (Nixploy.Application.deployment_state deployment)
              Failed)
      | Ok (Observer.Interrupted _) | Error _ -> assert false)

let () =
  don't_wait_for
    ( Monitor.try_with run_tests >>| function
      | Ok () -> Shutdown.shutdown 0
      | Error error ->
          eprintf "%s\n" (Exn.to_string error);
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
