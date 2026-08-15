open Async
open Core

let no_stage _ _ = Deferred.unit

let deploy_within_lease ?(on_stage = no_stage) ?(on_requested = Fn.ignore)
    ?application_key ?expected_project ~store ~working_directory ~source ~target
    () =
  let cancellation = Cancellation.current () in
  let open Deferred.Or_error.Let_syntax in
  let%bind operation =
    Store.request store ~application_key ~working_directory ~target
      ~commit:(Source.selection_commit source)
  in
  on_requested operation;
  let record_stage stage message =
    let open Deferred.Or_error.Let_syntax in
    let%bind () =
      Store.record_stage store ~id:(Store.id operation) ~stage ~message
    in
    let%bind.Deferred _ = Monitor.try_with (fun () -> on_stage stage message) in
    Deferred.Or_error.return ()
  in
  let%bind.Deferred execution =
    Monitor.try_with_or_error (fun () ->
        Deployment.deploy ~record_stage ?expected_project
          ~operation_id:(Store.id operation) ~working_directory ~source ~target
          ())
  in
  let result = Or_error.join execution in
  let%bind () =
    match result with
    | Ok deployment ->
        Store.succeed store ~id:(Store.id operation) ~result:deployment
    | Error error -> (
        match cancellation with
        | Some token
          when Cancellation.was_acknowledged token
               && not (Cancellation.cleanup_failed token) ->
            let%bind _ =
              Store.request_cancellation store ~id:(Store.id operation)
            in
            Store.cancel store ~id:(Store.id operation)
        | _ -> Store.fail store ~id:(Store.id operation) ~error)
  in
  let%bind found = Store.find store ~id:(Store.id operation) in
  match found with
  | Some deployment -> Deferred.Or_error.return deployment
  | None -> Deferred.Or_error.error_string "tracked deployment disappeared"

let deploy ?on_stage ?on_requested ?application_key ?expected_project ~store
    ~working_directory ~source ~target () =
  let working_directory = Filename_unix.realpath working_directory in
  Store.with_lease store ~working_directory ~target (fun () ->
      deploy_within_lease ?on_stage ?on_requested ?application_key
        ?expected_project ~store ~working_directory ~source ~target ())
