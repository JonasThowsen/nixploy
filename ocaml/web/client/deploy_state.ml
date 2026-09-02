open Core

type t =
  | Idle
  | Submitting of string
  | Awaiting_observation of { key : string; operation_id : string }
[@@deriving equal, sexp]

let start_submission state ~key =
  match state with
  | Idle -> Submitting key
  | Submitting _ | Awaiting_observation _ -> state

let accept_submission state ~key ~operation_id =
  match state with
  | Submitting pending when String.equal pending key ->
      Awaiting_observation { key; operation_id }
  | Idle | Submitting _ | Awaiting_observation _ -> state

let finish_submission state ~key =
  match state with
  | Submitting pending when String.equal pending key -> Idle
  | Awaiting_observation pending when String.equal pending.key key -> Idle
  | Idle | Submitting _ | Awaiting_observation _ -> state

let observe_operation state ~key ~operation_id =
  match state with
  | Awaiting_observation pending
    when String.equal pending.key key
         && String.equal pending.operation_id operation_id ->
      Idle
  | Idle | Submitting _ | Awaiting_observation _ -> state

let reset_for_route_change = function
  | Awaiting_observation _ as state -> state
  | Idle | Submitting _ -> Idle

let awaiting_operation = function
  | Awaiting_observation pending -> Some (pending.key, pending.operation_id)
  | Idle | Submitting _ -> None

let is_busy = function
  | Idle -> false
  | Submitting _ | Awaiting_observation _ -> true

let is_pending = function
  | Submitting _ | Awaiting_observation _ -> true
  | Idle -> false

let is_pending_for state ~key =
  match state with
  | Submitting pending -> String.equal pending key
  | Awaiting_observation pending -> String.equal pending.key key
  | Idle -> false
