open Async
open Core

type started = {
  deployment : Store.deployment;
  completion : Store.deployment Deferred.Or_error.t;
}

let deployment t = t.deployment
let completion t = t.completion

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

let finish_operation ~store operation result cancellation =
  let terminalize execution_error =
    let id = Store.id operation in
    terminalize_cancelled
      ~request_marker:(fun () -> Store.request_cancellation store ~id)
      ~cancel:(fun () -> Store.cancel store ~id)
      ~fail:(fun error -> Store.fail store ~id ~error)
      ~find_state:(fun () ->
        let%map.Deferred found = Store.find store ~id in
        Result.map found ~f:(Option.map ~f:Store.state))
      ~execution_error
  in
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    match result with
    | Ok deployment ->
        let message =
          Deployment.warning deployment
          |> Option.value ~default:"Deployment independently verified"
        in
        Store.succeed store ~id:(Store.id operation)
          ~container_name:(Deployment.container_name deployment)
          ~message
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

let run_requested ~store ~request ~prepared operation =
  let cancellation = Cancellation.current () in
  let%bind.Deferred execution =
    Monitor.try_with_or_error (fun () ->
        Deployment.execute ~store ~request ~operation_id:(Store.id operation)
          prepared)
  in
  finish_operation ~store operation (Or_error.join execution) cancellation

let start ~request ~prepared ~store () =
  let open Deferred.Let_syntax in
  let working_directory =
    Deployment_request.working_directory request |> Filename_unix.realpath
  in
  let target = Deployment_request.target request in
  let source = Deployment_request.source request in
  let started : Store.deployment Or_error.t Ivar.t = Ivar.create () in
  let completion : Store.deployment Or_error.t Ivar.t = Ivar.create () in
  let launch () =
    Monitor.protect
      ~finally:(fun () -> Deployment.cleanup_prepared prepared)
      (fun () ->
        Store.with_reconciled_lease store ~working_directory ~target (fun () ->
            let open Deferred.Or_error.Let_syntax in
            let%bind operation =
              Store.request store ~working_directory ~target
                ~commit:(Source.selection_commit source)
            in
            let%bind.Deferred binding =
              Deferred.return
                (Deployment_request.bind_operation request
                   ~operation_id:(Store.id operation))
            in
            match binding with
            | Error error ->
                let%map.Deferred terminal =
                  Store.fail store ~id:(Store.id operation) ~error
                in
                Result.bind terminal ~f:(fun () -> Error error)
            | Ok () -> (
                let%bind.Deferred resource_state =
                  Store.set_resource_state store ~working_directory ~target
                    Unknown
                in
                match resource_state with
                | Ok () ->
                    Ivar.fill_if_empty started (Ok operation);
                    run_requested ~store ~request ~prepared operation
                | Error error ->
                    let%map.Deferred terminal =
                      Store.fail store ~id:(Store.id operation) ~error
                    in
                    Result.bind terminal ~f:(fun () -> Error error))))
  in
  don't_wait_for
    ( Monitor.try_with launch >>| function
      | Ok result ->
          Ivar.fill_if_empty completion result;
          Ivar.fill_if_empty started result
      | Error error ->
          let error = Error.of_exn error in
          Ivar.fill_if_empty completion (Error error);
          Ivar.fill_if_empty started (Error error) );
  let%map started_result = Ivar.read started in
  Result.map started_result ~f:(fun deployment ->
      { deployment; completion = Ivar.read completion })

let deploy ~request ~store () =
  let open Deferred.Or_error.Let_syntax in
  let%bind prepared = Deployment.prepare ~request in
  let%bind started = start ~request ~prepared ~store () in
  completion started

module For_testing = struct
  let terminalize_cancelled = terminalize_cancelled
end
