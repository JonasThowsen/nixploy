open Core

type slot = Blue | Green [@@deriving compare, equal, sexp]

type t = {
  active_slot : slot option;
  candidate_slot : slot;
  candidate_port : int;
  previous_port : int option;
}

let create ~web ~active_port =
  let blue = Configuration.Web.blue_port web in
  let green = Configuration.Web.green_port web in
  match active_port with
  | None ->
      Ok
        {
          active_slot = None;
          candidate_slot = Blue;
          candidate_port = blue;
          previous_port = None;
        }
  | Some port when Int.equal port blue ->
      Ok
        {
          active_slot = Some Blue;
          candidate_slot = Green;
          candidate_port = green;
          previous_port = Some blue;
        }
  | Some port when Int.equal port green ->
      Ok
        {
          active_slot = Some Green;
          candidate_slot = Blue;
          candidate_port = blue;
          previous_port = Some green;
        }
  | Some port -> Or_error.errorf "Caddy routes to undeclared port %d" port

let active_slot t = t.active_slot
let candidate_slot t = t.candidate_slot
let candidate_port t = t.candidate_port
let previous_port t = t.previous_port
let slot_name = function Blue -> "blue" | Green -> "green"

let container_name ~resource_key slot =
  Resource_key.to_string resource_key ^ "-" ^ slot_name slot
