open Core
module Application = Nixploy.Application

type terminal_state =
  | Succeeded
  | Failed of string option
  | Cancelled
  | Incomplete
[@@deriving equal, sexp]

type t = {
  id : string;
  state_name : string;
  revision : string option;
  container_name : string option;
  terminal_state : terminal_state;
}

let of_deployment deployment =
  let state = Application.deployment_state deployment in
  let terminal_state =
    match state with
    | Application.Succeeded -> Succeeded
    | Failed -> Failed (Application.deployment_error deployment)
    | Cancelled -> Cancelled
    | Requested | Running -> Incomplete
  in
  {
    id = Application.deployment_id deployment;
    state_name = Application.deployment_state_name state;
    revision = Application.deployment_revision deployment;
    container_name = Application.deployment_container_name deployment;
    terminal_state;
  }

let id t = t.id
let state_name t = t.state_name
let revision t = t.revision
let container_name t = t.container_name
let terminal_state t = t.terminal_state
