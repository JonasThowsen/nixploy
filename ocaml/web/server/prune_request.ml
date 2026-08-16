open Async
open Core

let handle ~applications ~prune query =
  match
    Nixploy.Managed_application.find applications
      query.Protocol.Prune.Query.application
  with
  | Error error -> Deferred.return (Error error)
  | Ok application ->
      let%map result = prune ~application in
      Or_error.map result ~f:Prune_response.of_application
