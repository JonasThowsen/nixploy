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

let prepare_managed ~application ~intent ~commit =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    Deferred.return (Deployment_intent.validate_application intent application)
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

let prepare_local ?expected_project ?repository_identity ~working_directory
    ~target:target_name () =
  let open Deferred.Or_error.Let_syntax in
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
    project;
    target_name;
    target;
    repository_identity;
    candidates;
    cleanup = (fun () -> Deferred.unit);
  }

let execute prepared =
  let open Deferred.Or_error.Let_syntax in
  let project = prepared.project in
  let target_name = prepared.target_name in
  let target = prepared.target in
  let repository_identity = prepared.repository_identity in
  let%bind resource_key =
    Podman.select_resource_key ~project ~target ~repository_identity
      ~candidates:prepared.candidates
  in
  let%bind connection = Podman.ensure_connection ~target ~resource_key in
  let%bind podman_preflight =
    Podman.preflight_prune_owned_resources ~connection ~project ~target
      ~resource_key ~repository_identity
  in
  let%bind caddy_preflight =
    match Configuration.Target.kind target with
    | Non_web -> Deferred.Or_error.return None
    | Web web ->
        let caddy = Caddy.create ~target ~resource_key ~web in
        Caddy.preflight_delete caddy >>| Option.some
  in
  let%bind route =
    match caddy_preflight with
    | None -> Deferred.Or_error.return Not_configured
    | Some deletion -> (
        Caddy.execute_delete deletion >>| function
        | true -> Removed
        | false -> Missing)
  in
  let%map containers_removed, secrets_removed =
    Podman.execute_prepared_prune podman_preflight
  in
  {
    project;
    target = target_name;
    resource_key;
    containers_removed;
    secrets_removed;
    route;
  }

let prune ?expected_project ?repository_identity ~working_directory ~target () =
  let open Deferred.Or_error.Let_syntax in
  let%bind prepared =
    prepare_local ?expected_project ?repository_identity ~working_directory
      ~target ()
  in
  Monitor.protect
    ~finally:(fun () -> cleanup_prepared prepared)
    (fun () -> execute prepared)

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
