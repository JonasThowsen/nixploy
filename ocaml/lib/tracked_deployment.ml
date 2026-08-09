open Async
open Core

let deploy ~store ~working_directory ~target =
  let open Deferred.Or_error.Let_syntax in
  let working_directory = Filename_unix.realpath working_directory in
  let%bind operation = Store.request store ~working_directory ~target in
  let on_stage stage message =
    Store.record_stage store ~id:(Store.id operation) ~stage ~message
    |> Deferred.map ~f:Or_error.ok_exn
  in
  let%bind.Deferred execution =
    Monitor.try_with_or_error (fun () ->
        Deployment.deploy ~on_stage ~working_directory ~target ())
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
  | None -> Deferred.Or_error.error_string "tracked deployment disappeared"
