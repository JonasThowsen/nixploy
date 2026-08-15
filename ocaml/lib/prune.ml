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

let project t = t.project
let target t = t.target
let resource_key t = t.resource_key
let containers_removed t = t.containers_removed
let secrets_removed t = t.secrets_removed
let route t = t.route

let prune ~working_directory ~target:target_name =
  let open Deferred.Or_error.Let_syntax in
  let%bind configuration = Nix_configuration.load ~working_directory in
  let%bind target =
    Deferred.return (Configuration.find_target configuration target_name)
  in
  let project = Configuration.project configuration in
  let%bind canonical =
    Deferred.return (Resource_key.derive ~project ~target:target_name)
  in
  let%bind repository = Source.repository_identity ~working_directory in
  let%bind legacy =
    Deferred.return
      (Resource_key.derive_legacy ~project ~target:target_name ~repository)
  in
  let%bind resource_key =
    Podman.select_resource_key ~project ~target ~canonical ~legacy
  in
  let%bind connection = Podman.ensure_connection ~target ~resource_key in
  let%bind podman_preflight =
    Podman.preflight_prune_owned_resources ~connection ~project ~target
      ~resource_key
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
