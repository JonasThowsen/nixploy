open Core

type slot = Blue | Green [@@deriving compare, equal, sexp]

type placement = Single_container | Web_slot of { slot : slot; port : int }
[@@deriving compare, equal, sexp]

type t = {
  target_kind : Configuration.Target.kind;
  placement : placement;
  active_slot : slot option;
  previous_port : int option;
}

let create ~target_kind ~active_port =
  match (target_kind, active_port) with
  | Configuration.Target.Non_web, None ->
      Ok
        {
          target_kind;
          placement = Single_container;
          active_slot = None;
          previous_port = None;
        }
  | Non_web, Some _ ->
      Or_error.error_string "non-web deployment cannot have an active web port"
  | Web web, active_port -> (
      let blue = Configuration.Web.blue_port web in
      let green = Configuration.Web.green_port web in
      match active_port with
      | None ->
          Ok
            {
              target_kind;
              placement = Web_slot { slot = Blue; port = blue };
              active_slot = None;
              previous_port = None;
            }
      | Some port when Int.equal port blue ->
          Ok
            {
              target_kind;
              placement = Web_slot { slot = Green; port = green };
              active_slot = Some Blue;
              previous_port = Some blue;
            }
      | Some port when Int.equal port green ->
          Ok
            {
              target_kind;
              placement = Web_slot { slot = Blue; port = blue };
              active_slot = Some Green;
              previous_port = Some green;
            }
      | Some port -> Or_error.errorf "Caddy routes to undeclared port %d" port)

let target_kind t = t.target_kind
let placement t = t.placement
let active_slot t = t.active_slot
let previous_port t = t.previous_port
let slot_name = function Blue -> "blue" | Green -> "green"

let web_container_name ~resource_key slot =
  Resource_key.to_string resource_key ^ "-" ^ slot_name slot

let container_name ~resource_key = function
  | Single_container -> Resource_key.to_string resource_key
  | Web_slot { slot; _ } -> web_container_name ~resource_key slot
