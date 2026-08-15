open Core

type slot = Blue | Green [@@deriving compare, equal, sexp]

type placement = Single_container | Web_slot of { slot : slot; port : int }
[@@deriving compare, equal, sexp]

type t = { placement : placement; active_slot : slot option }

let create ~target_kind ~active_port =
  match (target_kind, active_port) with
  | Configuration.Target.Non_web, None ->
      Ok { placement = Single_container; active_slot = None }
  | Non_web, Some _ ->
      Or_error.error_string "non-web deployment cannot have an active web port"
  | Web web, active_port -> (
      let blue = Configuration.Web.blue_port web in
      let green = Configuration.Web.green_port web in
      match active_port with
      | None ->
          Ok
            {
              placement = Web_slot { slot = Blue; port = blue };
              active_slot = None;
            }
      | Some port when Int.equal port blue ->
          Ok
            {
              placement = Web_slot { slot = Green; port = green };
              active_slot = Some Blue;
            }
      | Some port when Int.equal port green ->
          Ok
            {
              placement = Web_slot { slot = Blue; port = blue };
              active_slot = Some Green;
            }
      | Some port -> Or_error.errorf "Caddy routes to undeclared port %d" port)

let placement t = t.placement

let web_placement t =
  match t.placement with
  | Web_slot { slot; port } -> Ok (slot, port)
  | Single_container ->
      Or_error.error_string "deployment plan is not a web placement"

let active_slot t = t.active_slot
let slot_name = function Blue -> "blue" | Green -> "green"

let web_container_name ~resource_key slot =
  Resource_key.to_string resource_key ^ "-" ^ slot_name slot

let container_name ~resource_key = function
  | Single_container -> Resource_key.to_string resource_key
  | Web_slot { slot; _ } -> web_container_name ~resource_key slot

let runtime_port = function
  | Single_container -> None
  | Web_slot { port; _ } -> Some port
