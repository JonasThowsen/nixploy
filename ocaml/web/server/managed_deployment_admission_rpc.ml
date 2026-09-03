open Async
open Core
module Admission = Nixploy.Managed_deployment_admission
module Managed_application = Nixploy.Managed_application
module Target_name = Nixploy.Target_name

let authority_mismatch format =
  Printf.ksprintf
    (fun message ->
      Or_error.errorf "NIXPLOY_MANAGED_DEPLOY_AUTHORITY_MISMATCH: %s" message)
    format

let matches_authority managed request =
  let requested_target = Admission.requested_target request in
  if
    not
      (Target_name.equal requested_target (Managed_application.target managed))
  then authority_mismatch "requested target does not match managed application"
  else
    match Managed_application.repository_provenance managed with
    | None ->
        authority_mismatch "managed application has no configured provenance"
    | Some provenance
      when not (String.equal provenance (Admission.provenance request)) ->
        authority_mismatch "provenance does not match managed application"
    | Some _ -> Ok ()

let handle ~applications ~application query =
  match
    Admission.create
      ~managed_application_key:
        query.Protocol.Admit_managed_deployment.Query.managed_application_key
      ~requested_target:query.requested_target ~provenance:query.provenance
      ~revision:query.revision
  with
  | Error _ as error -> Deferred.return error
  | Ok request -> (
      match
        Managed_application.find applications
          (Admission.managed_application_key request)
      with
      | Error _ ->
          Deferred.return
            (authority_mismatch "managed application key is not configured")
      | Ok managed -> (
          match matches_authority managed request with
          | Error _ as error -> Deferred.return error
          | Ok () ->
              let%map result =
                Nixploy.Application.admit_managed_deployment application managed
                  ~revision:(Admission.revision request)
              in
              match result with
              | Ok started ->
                  Ok
                    {
                      Protocol.Admit_managed_deployment.Response.operation_id =
                        Nixploy.Application.started_deployment_id started;
                      update_sequence = 0L;
                    }
              | Error error -> Error error))

(* TODO(tracer): Replace the broker-unconfigured admission result only after the
   Application persists broker-backed admission evidence before any deployment
   effect. The operation-id response is reserved for that successful path. *)
