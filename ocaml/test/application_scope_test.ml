open Async
open Core
open Nixploy

let run_tests () =
  let open Deferred.Let_syntax in
  let directory = Filename_unix.temp_dir "nixploy-application-scope-" "" in
  let other_directory = Filename_unix.temp_dir "nixploy-other-scope-" "" in
  let target = Target_name.of_string "test" |> Or_error.ok_exn in
  let commit =
    Source.For_testing.commit ~revision:(String.make 40 'a') ~subject:"scope"
      ~timestamp_ms:1L
    |> Or_error.ok_exn
  in
  let%bind store =
    Store.open_ ~path:(Filename.concat directory "state.sqlite")
  in
  let store = Or_error.ok_exn store in
  let%bind operation =
    Store.request store ~working_directory:directory ~target ~commit
  in
  let operation = Or_error.ok_exn operation in
  let id = Store.id operation in
  let deployment state =
    Application.For_testing.deployment ~working_directory:directory ~target ~id
      ~state ()
  in
  let completion = Ivar.create () in
  let token = ref None in
  let create () =
    Application.For_testing.create ~store
      ~deploy:(fun ~request ~prepared:_ ->
        assert (
          String.equal (Deployment_request.working_directory request) directory);
        token := Cancellation.current ();
        Deferred.Or_error.return (deployment Requested, Ivar.read completion))
      ()
  in
  let application = create () in
  let start application =
    Application.start_direct_deployment application ~working_directory:directory
      ~source:(Source.immutable commit) ~target ()
  in
  let%bind started = start application in
  let started = Or_error.ok_exn started in
  let original_token = Option.value_exn !token in
  let scope =
    Application.local_scope ~working_directory:directory ~target
    |> Or_error.ok_exn
  in
  let other_scope =
    Application.local_scope ~working_directory:other_directory ~target
    |> Or_error.ok_exn
  in
  assert (
    Application.deployment_can_cancel application ~scope (deployment Requested));
  assert (
    not
      (Application.deployment_can_cancel application ~scope:other_scope
         (deployment Requested)));
  let%bind wrong_scope =
    Application.cancel_deployment application ~scope:other_scope
      ~operation_id:id
  in
  assert (Result.is_error wrong_scope);
  let%bind unknown =
    Application.cancel_deployment application ~scope ~operation_id:"missing"
  in
  assert (Result.is_error unknown);
  let%bind untouched = Store.find store ~id in
  assert (
    Option.is_none
      (Store.cancel_requested_at_ms
         (Or_error.ok_exn untouched |> Option.value_exn)));
  assert (not (Cancellation.was_requested original_token));
  (* Even an identically numbered operation in another facade is not this handle. *)
  let other_application = create () in
  let%bind other_started = start other_application in
  let%bind forged_handle =
    Application.cancel_started_deployment application
      (Or_error.ok_exn other_started)
  in
  assert (Result.is_error forged_handle);
  assert (not (Cancellation.was_requested original_token));
  let%bind requested =
    Application.cancel_deployment application ~scope ~operation_id:id
  in
  assert (
    Application.equal_cancellation_result
      (Or_error.ok_exn requested)
      Cancellation_requested);
  assert (Cancellation.was_requested original_token);
  let%bind repeated =
    Application.cancel_deployment application ~scope ~operation_id:id
  in
  assert (
    Application.equal_cancellation_result (Or_error.ok_exn repeated)
      Already_requested);
  let%bind cancelled = Store.cancel store ~id in
  Or_error.ok_exn cancelled;
  Ivar.fill_exn completion (Ok (deployment Cancelled));
  let%bind completed = Application.await_started_deployment started in
  assert (
    Application.equal_deployment_state
      (Application.deployment_state (Or_error.ok_exn completed))
      Cancelled);
  let%bind () = Application.mutations_drained application in
  let%bind actual_history =
    Application.deployment_history application ~scope ~limit:10
  in
  assert (List.length (Or_error.ok_exn actual_history) = 1);
  let%bind other_history =
    Application.deployment_history application ~scope:other_scope ~limit:10
  in
  assert (List.is_empty (Or_error.ok_exn other_history));
  printf
    "Application scope: foreign scope/handle refusal, exact cancellation, \
     repeated cancellation, terminal drain and scoped history passed\n\
     %!";
  Deferred.unit

let () =
  don't_wait_for
    ( Clock_ns.with_timeout (Time_ns.Span.of_sec 10.)
        (Monitor.try_with_or_error run_tests)
    >>| function
      | `Result (Ok ()) -> Shutdown.shutdown 0
      | `Result (Error error) ->
          eprintf "%s\n%!" (Error.to_string_hum error);
          Shutdown.shutdown 1
      | `Timeout ->
          eprintf "Application scope test timed out\n%!";
          Shutdown.shutdown 1 );
  never_returns (Scheduler.go ())
