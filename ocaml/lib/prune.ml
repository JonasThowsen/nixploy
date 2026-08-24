open Async
open Core

type route = Not_configured | Missing | Removed
[@@deriving compare, equal, sexp]

type t = {
  project : Project_name.t;
  target : Target_name.t;
  resource_key : Resource_key.t;
  containers_removed : int;
  secrets_removed : int;
  route : route;
}

type prepared = {
  authorization : Operation_receipt.prune;
  project : Project_name.t;
  target_name : Target_name.t;
  target : Configuration.Target.t;
  repository_identity : string;
  candidates : Resource_key.t list;
  cleanup : unit -> unit Deferred.t;
}

let project (t : t) = t.project
let target (t : t) = t.target
let resource_key (t : t) = t.resource_key
let containers_removed (t : t) = t.containers_removed
let secrets_removed (t : t) = t.secrets_removed
let route (t : t) = t.route
let cleanup_prepared prepared = prepared.cleanup ()

let validate_managed_capability authorization application intent commit =
  let open Or_error.Let_syntax in
  let%bind () = Deployment_intent.validate_application intent application in
  let%bind application_directory =
    Or_error.try_with (fun () ->
        Managed_application.working_directory application
        |> Filename_unix.realpath)
  in
  let application_key_matches =
    Option.value_map
      (Operation_receipt.prune_application_key authorization)
      ~default:false
      ~f:(String.equal (Managed_application.key application))
  in
  let project_matches =
    Option.value_map
      (Operation_receipt.prune_expected_project authorization)
      ~default:false
      ~f:(Project_name.equal (Managed_application.project application))
  in
  let repository_matches =
    Option.value_map
      (Operation_receipt.prune_repository_identity authorization)
      ~default:false
      ~f:(String.equal (Managed_application.repository_identity application))
  in
  if
    application_key_matches && project_matches && repository_matches
    && String.equal application_directory
         (Operation_receipt.prune_working_directory authorization)
    && Target_name.equal
         (Operation_receipt.prune_target authorization)
         (Managed_application.target application)
    && String.equal
         (Source.commit_revision commit)
         (Deployment_intent.revision intent)
  then Ok ()
  else
    Or_error.error_string
      "consumed prune capability does not match its application, source, or \
       target"

let prepare_managed ~authorization ~application ~intent ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    Deferred.return
      (validate_managed_capability authorization application intent commit)
  in
  let working_directory = Managed_application.working_directory application in
  let%bind source_authority =
    match Managed_application.production_destination application with
    | Some _ ->
        let%map authority =
          Source_authority.verify
            ~expected_revision:(Deployment_intent.revision intent)
            application
        in
        Some authority
    | None -> Deferred.Or_error.return None
  in
  let%bind source =
    match source_authority with
    | None ->
        Source.prepare ~working_directory ~selection:(Source.immutable commit)
    | Some authority ->
        let%bind protected_git =
          Deferred.return (Source_authority.protected_git authority)
        in
        Source.prepare_protected ~working_directory ~protected_git
          ~repository_identity:(Deployment_intent.repository_identity intent)
          ~commit
  in
  let validate () =
    let open Deferred.Or_error.Let_syntax in
    let%bind evaluated =
      Nix_configuration.load_evaluated
        ~offline:(Option.is_some source_authority)
        ~working_directory:(Source.nix_root source)
        ~flake:(Source.nix_flake source)
    in
    let configuration = Nix_configuration.configuration evaluated in
    let configuration_json = Nix_configuration.json evaluated in
    let%bind () =
      Deferred.return
        (Deployment_intent.validate_evaluated intent ~source_authority
           ~revision:(Source.revision source) ~configuration ~configuration_json)
    in
    let target_name = Managed_application.target application in
    let%map target =
      Deferred.return (Configuration.find_target configuration target_name)
    in
    {
      authorization;
      project = Configuration.project configuration;
      target_name;
      target;
      repository_identity = Deployment_intent.repository_identity intent;
      candidates = [ Deployment_intent.resource_key intent ];
      cleanup = (fun () -> Source.cleanup source);
    }
  in
  let%bind.Deferred result = Monitor.try_with_or_error validate in
  match Or_error.join result with
  | Ok prepared -> Deferred.Or_error.return prepared
  | Error error ->
      let%map.Deferred () = Source.cleanup source in
      Error error

let prepare_local ~authorization ?expected_project ?repository_identity
    ~working_directory ~target:target_name () =
  let open Deferred.Or_error.Let_syntax in
  let%bind working_directory =
    Deferred.return
      (Or_error.try_with (fun () -> Filename_unix.realpath working_directory))
  in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let project = Configuration.project configuration in
  let%bind () =
    match expected_project with
    | None -> Deferred.Or_error.return ()
    | Some expected when Project_name.equal expected project ->
        Deferred.Or_error.return ()
    | Some _ ->
        Deferred.Or_error.error_string
          "managed project mismatch: evaluated configuration project differs \
           from the allowlisted project"
  in
  let%bind target =
    Deferred.return (Configuration.find_target configuration target_name)
  in
  let managed_applications =
    if Sys_unix.file_exists_exn "/etc/nixploy/managed-applications.json" then
      Managed_application.load_authority_file () |> Or_error.ok_exn
    else []
  in
  let%bind _identity_policy =
    Deferred.return
      (Deployment_intent.authorize_local ~applications:managed_applications
         ~working_directory ~configuration ~target)
  in
  let%bind repository_identity =
    match repository_identity with
    | Some repository_identity -> Deferred.Or_error.return repository_identity
    | None -> Source.repository_identity ~working_directory
  in
  let%map candidates =
    Deferred.return
      (Resource_key.candidates ~project ~target:target_name ~repository_identity)
  in
  {
    authorization;
    project;
    target_name;
    target;
    repository_identity;
    candidates;
    cleanup = (fun () -> Deferred.unit);
  }

let prepare ~authorization =
  let open Deferred.Or_error.Let_syntax in
  let%bind () = Deferred.return (Operation_receipt.claim_prune authorization) in
  match
    ( Operation_receipt.prune_application authorization,
      Operation_receipt.prune_intent authorization,
      Operation_receipt.prune_commit authorization )
  with
  | Some application, Some intent, Some commit ->
      prepare_managed ~authorization ~application ~intent ~commit
  | None, None, None ->
      prepare_local ~authorization
        ?expected_project:
          (Operation_receipt.prune_expected_project authorization)
        ?repository_identity:
          (Operation_receipt.prune_repository_identity authorization)
        ~working_directory:
          (Operation_receipt.prune_working_directory authorization)
        ~target:(Operation_receipt.prune_target authorization)
        ()
  | _ ->
      Deferred.Or_error.error_string
        "prune capability has incomplete managed-operation bindings"

let validate_bound ~authorization prepared =
  if not (phys_equal authorization prepared.authorization) then
    Or_error.error_string
      "prepared prune belongs to a different consumed capability"
  else Operation_receipt.validate_prune authorization

let execute ~authorization:_ prepared =
  ignore
    ( prepared.project,
      prepared.target_name,
      prepared.target,
      prepared.repository_identity,
      prepared.candidates );
  Deferred.Or_error.error_string
    "prune is disabled in Production V1: durable prune operation lifecycle is \
     not implemented"

let prune ~authorization:_ () =
  Deferred.Or_error.error_string
    "prune is disabled in Production V1: durable prune operation lifecycle is \
     not implemented"

module For_testing = struct
  let result ~project ~target ~resource_key ~containers_removed ~secrets_removed
      ~route =
    {
      project;
      target;
      resource_key;
      containers_removed;
      secrets_removed;
      route;
    }
end
