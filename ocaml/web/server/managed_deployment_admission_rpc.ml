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

let unavailable () =
  Or_error.error_string
    "NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE: immutable revision admission, \
     root-owned source custody, and authoritative target-lease broker \
     integration are required before managed deployment"

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

let handle ~applications query =
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
          | Ok () -> Deferred.return (unavailable ())))

(* TODO(tracer): Replace this unavailable result only after source custody verifies
   the exact revision and the Application lifecycle persists broker-backed
   admission evidence before any deployment effect. *)
