open Async
open Core

let canonical_working_directory application =
  let working_directory =
    Nixploy.Managed_application.working_directory application
  in
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  |> Result.ok
  |> Option.value ~default:working_directory

let handle ~applications ~prune ~on_started query =
  match
    Nixploy.Managed_application.find applications
      query.Protocol.Prune.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      let application_key = Nixploy.Managed_application.key application in
      let working_directory = canonical_working_directory application in
      let target = Nixploy.Managed_application.target application in
      on_started ~application_key;
      let%map result = prune ~working_directory ~target in
      Or_error.map result ~f:Prune_response.of_application
