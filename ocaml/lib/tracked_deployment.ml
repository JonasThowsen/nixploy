open Async
open Core

let no_stage _ _ = Deferred.unit

let deploy ?(on_stage = no_stage) ~store ~working_directory ~target () =
  let working_directory = Filename_unix.realpath working_directory in
  Store.with_lease store ~working_directory ~target (fun () ->
      let open Deferred.Or_error.Let_syntax in
      let%bind operation = Store.request store ~working_directory ~target in
      let on_stage stage message =
        let%bind.Deferred recorded =
          Store.record_stage store ~id:(Store.id operation) ~stage ~message
        in
        Or_error.ok_exn recorded;
        Monitor.try_with (fun () -> on_stage stage message)
        |> Deferred.map ~f:(fun _ -> ())
      in
      let%bind.Deferred execution =
        Monitor.try_with_or_error (fun () ->
            Deployment.deploy ~on_stage ~operation_id:(Store.id operation)
              ~working_directory ~target ())
      in
      let result = Or_error.join execution in
      let%bind () =
        match result with
        | Ok deployment ->
            Store.succeed store ~id:(Store.id operation) ~result:deployment
        | Error error -> Store.fail store ~id:(Store.id operation) ~error
      in
      let%bind found = Store.find store ~id:(Store.id operation) in
      match found with
      | Some deployment -> Deferred.Or_error.return deployment
      | None -> Deferred.Or_error.error_string "tracked deployment disappeared")
