open Core

type t = Idle | Previewing of string | Submitting of string
[@@deriving equal, sexp]

let start_preview state ~key =
  match state with
  | Idle -> Previewing key
  | Previewing _ | Submitting _ -> state

let finish_preview state ~key =
  match state with
  | Previewing pending when String.equal pending key -> Idle
  | Idle | Previewing _ | Submitting _ -> state

let start_submission state ~key =
  match state with
  | Idle -> Submitting key
  | Previewing _ | Submitting _ -> state

let finish_submission state ~key =
  match state with
  | Submitting pending when String.equal pending key -> Idle
  | Idle | Previewing _ | Submitting _ -> state

let is_busy = function Idle -> false | Previewing _ | Submitting _ -> true

let is_previewing state ~key =
  match state with
  | Previewing pending -> String.equal pending key
  | Idle | Submitting _ -> false

let is_pending = function Submitting _ -> true | Idle | Previewing _ -> false

let is_pending_for state ~key =
  match state with
  | Submitting pending -> String.equal pending key
  | Idle | Previewing _ -> false
