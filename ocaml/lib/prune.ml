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

type prepared = Disabled

let project (t : t) = t.project
let target (t : t) = t.target
let resource_key (t : t) = t.resource_key
let containers_removed (t : t) = t.containers_removed
let secrets_removed (t : t) = t.secrets_removed
let route (t : t) = t.route
let cleanup_prepared Disabled = Deferred.unit

let disabled_error () =
  Or_error.error_string
    "prune is disabled in Production V1: durable prune operation lifecycle is \
     not implemented"

let prepare ~authorization:_ = Deferred.return (disabled_error ())
let validate_bound ~authorization:_ Disabled = disabled_error ()
let execute ~authorization:_ Disabled = Deferred.return (disabled_error ())
let prune ~authorization:_ () = Deferred.return (disabled_error ())

module For_testing = struct
  let prepared = Disabled

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
