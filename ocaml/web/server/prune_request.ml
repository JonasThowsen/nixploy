open Async
open Core

let canonical_working_directory application =
  let working_directory =
    Nixploy.Managed_application.working_directory application
  in
  Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  |> Result.ok
  |> Option.value ~default:working_directory

let handle ~applications ~store ~prune ~on_success query =
  match
    Nixploy.Managed_application.find applications
      query.Protocol.Prune.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok application ->
      let open Deferred.Or_error.Let_syntax in
      let application_key = Nixploy.Managed_application.key application in
      let working_directory = canonical_working_directory application in
      let target = Nixploy.Managed_application.target application in
      let%bind active =
        Nixploy.Store.has_active_for_application store ~application_key
          ~working_directory ~target
      in
      if active then
        Deferred.Or_error.errorf
          "cannot prune %s while its deployment or cancellation is active"
          application_key
      else
        let%map result = prune ~working_directory ~target in
        on_success ~application_key;
        Prune_response.of_application result
