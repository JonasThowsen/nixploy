open Core

type deploy_payload = {
  application_key : string option;
  expected_project : Project_name.t option;
  intent : Deployment_intent.t option;
  application : Managed_application.t option;
  managed_applications : Managed_application.t list;
  working_directory : string;
  source : Source.selection;
  target : Target_name.t;
}

type prune_payload = {
  application_key : string option;
  expected_project : Project_name.t option;
  repository_identity : string option;
  intent : Deployment_intent.t option;
  application : Managed_application.t option;
  commit : Source.commit option;
  working_directory : string;
  target : Target_name.t;
}

type deploy_store = deploy_payload Deployment_receipt_store.t
type prune_store = prune_payload Deployment_receipt_store.t

type deploy = {
  payload : deploy_payload;
  mutable claimed : bool;
  mutable operation_id : string option;
}

type prune = { payload : prune_payload; mutable claimed : bool }

let create_deploy_store ?capacity ?ttl_seconds ?now ?random_bytes () =
  Deployment_receipt_store.create ?capacity ?ttl_seconds ?now ?random_bytes ()

let create_prune_store ?capacity ?ttl_seconds ?now ?random_bytes () =
  Deployment_receipt_store.create ?capacity ?ttl_seconds ?now ?random_bytes ()

let receipt_key = Option.value ~default:"non-production"

let direct_deploy ~application_key ~expected_project ~intent ~application
    ~managed_applications ~working_directory ~source ~target =
  let open Or_error.Let_syntax in
  let%map working_directory =
    Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  in
  {
    payload =
      {
        application_key;
        expected_project;
        intent;
        application;
        managed_applications;
        working_directory;
        source;
        target;
      };
    claimed = false;
    operation_id = None;
  }

let issue_deploy store ~application_key ~expected_project ~intent ~application
    ~managed_applications ~working_directory ~source ~target =
  let open Or_error.Let_syntax in
  let%bind working_directory =
    Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  in
  Deployment_receipt_store.issue store
    ~application_key:(receipt_key application_key)
    {
      application_key;
      expected_project;
      intent;
      application;
      managed_applications;
      working_directory;
      source;
      target;
    }

let issue_prune store ~application_key ~expected_project ~repository_identity
    ~intent ~application ~commit ~working_directory ~target =
  let open Or_error.Let_syntax in
  let%bind working_directory =
    Or_error.try_with (fun () -> Filename_unix.realpath working_directory)
  in
  Deployment_receipt_store.issue store
    ~application_key:(receipt_key application_key)
    {
      application_key;
      expected_project;
      repository_identity;
      intent;
      application;
      commit;
      working_directory;
      target;
    }

let consume_deploy store ~application_key ~receipt =
  let%map.Or_error payload =
    Deployment_receipt_store.consume store ~application_key ~receipt
  in
  { payload; claimed = false; operation_id = None }

let consume_prune store ~application_key ~receipt =
  let%map.Or_error payload =
    Deployment_receipt_store.consume store ~application_key ~receipt
  in
  { payload; claimed = false }

let deploy_application_key (t : deploy) = t.payload.application_key
let deploy_expected_project (t : deploy) = t.payload.expected_project
let deploy_intent (t : deploy) = t.payload.intent
let deploy_application (t : deploy) = t.payload.application
let deploy_managed_applications (t : deploy) = t.payload.managed_applications
let deploy_working_directory (t : deploy) = t.payload.working_directory
let deploy_source (t : deploy) = t.payload.source
let deploy_target (t : deploy) = t.payload.target

let claim_deploy (t : deploy) =
  if t.claimed then
    Or_error.error_string "deploy capability was already claimed"
  else (
    t.claimed <- true;
    Ok ())

let bind_deploy_operation (t : deploy) ~operation_id =
  if not t.claimed then
    Or_error.error_string
      "deploy capability must be claimed before operation binding"
  else
    match t.operation_id with
    | None ->
        t.operation_id <- Some operation_id;
        Ok ()
    | Some _ ->
        Or_error.error_string
          "deploy capability is already bound to an operation"

let validate_deploy_operation (t : deploy) ~operation_id =
  match t.operation_id with
  | Some expected when String.equal expected operation_id -> Ok ()
  | Some _ ->
      Or_error.error_string "deploy capability does not match this operation"
  | None -> Or_error.error_string "deploy capability has no bound operation"

let prune_application_key (t : prune) = t.payload.application_key
let prune_expected_project (t : prune) = t.payload.expected_project
let prune_repository_identity (t : prune) = t.payload.repository_identity
let prune_intent (t : prune) = t.payload.intent
let prune_application (t : prune) = t.payload.application
let prune_commit (t : prune) = t.payload.commit
let prune_working_directory (t : prune) = t.payload.working_directory
let prune_target (t : prune) = t.payload.target

let claim_prune (t : prune) =
  if t.claimed then Or_error.error_string "prune capability was already claimed"
  else (
    t.claimed <- true;
    Ok ())

let validate_prune (t : prune) =
  if t.claimed then Ok ()
  else Or_error.error_string "prune capability must be claimed before mutation"
