open Async
open Core

let no_stage _ _ = Deferred.unit

let terminalize_cancelled ~request_marker ~cancel ~fail ~find_state
    ~execution_error =
  let open Deferred.Let_syntax in
  let%bind marker = request_marker () in
  let%bind cancelled = cancel () in
  match cancelled with
  | Ok () -> Deferred.Or_error.return ()
  | Error cancellation_error -> (
      let tracking_error =
        let marker_error =
          match marker with
          | Ok () -> ""
          | Error error ->
              sprintf "; cancellation marker failed: %s"
                (Error.to_string_hum error)
        in
        Error.of_string
          (sprintf
             "deployment cancellation failed to reach its cancelled terminal \
              state (execution: %s%s; terminalization: %s)"
             (Error.to_string_hum execution_error)
             marker_error
             (Error.to_string_hum cancellation_error))
      in
      let%bind failed = fail tracking_error in
      match failed with
      | Ok () -> Deferred.Or_error.return ()
      | Error failure_error ->
          let%map found = find_state () in
          Or_error.bind found ~f:(function
            | Some (Store.Succeeded | Failed | Cancelled) -> Ok ()
            | Some (Requested | Running) | None ->
                Or_error.errorf
                  "%s; terminal failure persistence also failed: %s"
                  (Error.to_string_hum tracking_error)
                  (Error.to_string_hum failure_error)))

let deploy_within_lease ?(on_stage = no_stage) ?(on_requested = Fn.ignore)
    ?application_key ?expected_project ?expected_intent ~store
    ~working_directory ~source ~target () =
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
        Deployment.deploy ~record_stage ?expected_project ?expected_intent
          ~operation_id:(Store.id operation) ~working_directory ~source ~target
          ())
  in
  let result = Or_error.join execution in
  let terminalize execution_error =
    let id = Store.id operation in
    terminalize_cancelled
      ~request_marker:(fun () -> Store.request_cancellation store ~id)
      ~cancel:(fun () -> Store.cancel store ~id)
      ~fail:(fun error -> Store.fail store ~id ~error)
      ~find_state:(fun () ->
        let%map found = Store.find store ~id in
        Option.map found ~f:Store.state)
      ~execution_error
  in
  let%bind () =
    match result with
    | Ok deployment ->
        Store.succeed store ~id:(Store.id operation) ~result:deployment
    | Error error -> (
        match cancellation with
        | Some token
          when Cancellation.was_acknowledged token
               && not (Cancellation.cleanup_failed token) ->
            terminalize error
        | _ -> Store.fail store ~id:(Store.id operation) ~error)
  in
  let%bind found = Store.find store ~id:(Store.id operation) in
  match found with
  | Some deployment -> Deferred.Or_error.return deployment
  | None -> Deferred.Or_error.error_string "tracked deployment disappeared"

module For_testing = struct
  let terminalize_cancelled = terminalize_cancelled
end

let deploy ?on_stage ?on_requested ?application_key ?expected_project
    ?expected_intent ~store ~working_directory ~source ~target () =
  let working_directory = Filename_unix.realpath working_directory in
  Store.with_lease store ~working_directory ~target (fun () ->
      deploy_within_lease ?on_stage ?on_requested ?application_key
        ?expected_project ?expected_intent ~store ~working_directory ~source
        ~target ())
