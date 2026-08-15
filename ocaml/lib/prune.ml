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
let query_timeout = Time_ns.Span.of_sec 30.
let max_git_output = 65_536

let repository_identity ~working_directory =
  let open Deferred.Or_error.Let_syntax in
  let%bind canonical_directory =
    Deferred.return
      (Or_error.try_with (fun () -> Filename_unix.realpath working_directory))
  in
  let%bind.Deferred result =
    Process_runner.run ~working_directory:canonical_directory
      ~timeout:query_timeout ~max_output_bytes:max_git_output ~prog:"git"
      ~args:[ "remote"; "get-url"; "origin" ]
      ()
  in
  match result with
  | Error _ as error -> Deferred.return error
  | Ok { exit_status = Ok (); stdout; _ }
    when not (String.is_empty (String.strip stdout)) ->
      Deferred.Or_error.return (String.strip stdout)
  | Ok _ -> Deferred.Or_error.return canonical_directory

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
  let%bind repository = repository_identity ~working_directory in
  let%bind legacy =
    Deferred.return
      (Resource_key.derive_legacy ~project ~target:target_name ~repository)
  in
  let%bind resource_key =
    Podman.select_resource_key ~project ~target ~canonical ~legacy
  in
  let%bind connection = Podman.ensure_connection ~target ~resource_key in
  let plan = Prune_plan.create ~resource_key in
  let%bind containers_removed, secrets_removed =
    Podman.prune_owned_resources ~connection ~project ~target ~resource_key
      ~plan
  in
  let%map route =
    match Configuration.Target.kind target with
    | Non_web -> Deferred.Or_error.return Not_configured
    | Web web -> (
        let caddy = Caddy.create ~target ~resource_key ~web in
        Caddy.delete caddy >>| function true -> Removed | false -> Missing)
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
