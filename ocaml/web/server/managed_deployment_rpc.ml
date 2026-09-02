open Async
open Core

module Managed_application = Nixploy.Managed_application
module Application = Nixploy.Application

let preview ~applications ~application query =
  match
    Managed_application.find applications
      query.Protocol.Preview_deployment.Query.application
  with
  | Error _ as error -> Deferred.return error
  | Ok managed_application ->
      let%map preview =
        Application.preview_managed_deployment application managed_application
      in
      Or_error.map preview ~f:(fun preview ->
          let commit = Application.deployment_preview_commit preview in
          {
            Protocol.Deployment_preview.commit =
              {
                Protocol.Commit.revision = Application.commit_revision commit;
                subject = Application.commit_subject commit;
                timestamp_ms = Application.commit_timestamp_ms commit;
              };
            receipt = Application.deployment_preview_receipt preview;
            prune_receipt = Application.deployment_preview_prune_receipt preview;
          })

let start ~applications ~application query =
  match Managed_application.find applications query.Protocol.Deploy.Query.application with
  | Error _ as error -> Deferred.return error
  | Ok managed_application ->
      let%map started =
        Application.start_managed_deployment application managed_application
      in
      Result.map started ~f:Application.started_deployment_id
