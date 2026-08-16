open Core

type t =
  | Idle
  | Previewing of string
  | Submitting of string
  | Awaiting_observation of { key : string; operation_id : string }
[@@deriving equal, sexp]

let start_preview state ~key =
  match state with
  | Idle -> Previewing key
  | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let finish_preview state ~key =
  match state with
  | Previewing pending when String.equal pending key -> Idle
  | Idle | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let start_submission state ~key =
  match state with
  | Idle -> Submitting key
  | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let accept_submission state ~key ~operation_id =
  match state with
  | Submitting pending when String.equal pending key ->
      Awaiting_observation { key; operation_id }
  | Idle | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let finish_submission state ~key =
  match state with
  | Submitting pending when String.equal pending key -> Idle
  | Awaiting_observation pending when String.equal pending.key key -> Idle
  | Idle | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let observe_operation state ~key ~operation_id =
  match state with
  | Awaiting_observation pending
    when String.equal pending.key key
         && String.equal pending.operation_id operation_id ->
      Idle
  | Idle | Previewing _ | Submitting _ | Awaiting_observation _ -> state

let reset_for_route_change = function
  | Awaiting_observation _ as state -> state
  | Idle | Previewing _ | Submitting _ -> Idle

let awaiting_operation = function
  | Awaiting_observation pending -> Some (pending.key, pending.operation_id)
  | Idle | Previewing _ | Submitting _ -> None

let is_busy = function
  | Idle -> false
  | Previewing _ | Submitting _ | Awaiting_observation _ -> true

let is_previewing state ~key =
  match state with
  | Previewing pending -> String.equal pending key
  | Idle | Submitting _ | Awaiting_observation _ -> false

let is_pending = function
  | Submitting _ | Awaiting_observation _ -> true
  | Idle | Previewing _ -> false

let is_pending_for state ~key =
  match state with
  | Submitting pending -> String.equal pending key
  | Awaiting_observation pending -> String.equal pending.key key
  | Idle | Previewing _ -> false
