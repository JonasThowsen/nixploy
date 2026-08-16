open Core

type t =
  | Idle
  | Confirming of { key : string; error : string option }
  | Pending of string
[@@deriving equal, sexp]

let confirm state ~key =
  match state with Idle -> Confirming { key; error = None } | _ -> state

let start state ~key =
  match state with
  | Confirming confirmation when String.equal confirmation.key key ->
      Pending key
  | _ -> state

let fail state ~key ~error =
  match state with
  | Pending pending when String.equal pending key ->
      Confirming { key; error = Some error }
  | _ -> state

let succeed state ~key =
  match state with
  | Pending pending when String.equal pending key -> Idle
  | _ -> state

let keep state ~key =
  match state with
  | Confirming confirmation when String.equal confirmation.key key -> Idle
  | _ -> state

let is_pending = function Pending _ -> true | Idle | Confirming _ -> false
let is_busy = function Idle -> false | Confirming _ | Pending _ -> true

let confirmation = function
  | Confirming { key; error } -> Some (key, error)
  | Idle | Pending _ -> None
