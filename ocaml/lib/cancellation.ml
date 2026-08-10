open Async
open Core

type phase = Open | Requested | Acknowledged | Committed

type t = {
  mutable phase : phase;
  requested : unit Ivar.t;
  mutable cleanup_failed : bool;
}

type request = Accepted | Already_requested | Too_late
[@@deriving compare, equal, sexp]

type commit = Continue | Cancel [@@deriving compare, equal, sexp]

let key = Univ_map.Key.create ~name:"nixploy-cancellation" sexp_of_opaque

let create () =
  { phase = Open; requested = Ivar.create (); cleanup_failed = false }

let within t f = Scheduler.with_local key (Some t) ~f
let current () = Scheduler.find_local key

let request t =
  match t.phase with
  | Open ->
      t.phase <- Requested;
      Ivar.fill_if_empty t.requested ();
      Accepted
  | Requested | Acknowledged -> Already_requested
  | Committed -> Too_late

let requested t = Ivar.read t.requested

let acknowledge t =
  match t.phase with
  | Requested ->
      t.phase <- Acknowledged;
      true
  | Acknowledged -> true
  | Open | Committed -> false

let acknowledge_current () = current () |> Option.exists ~f:acknowledge

let commit_current () =
  match current () with
  | None -> Continue
  | Some t -> (
      match t.phase with
      | Open ->
          t.phase <- Committed;
          Continue
      | Requested | Acknowledged ->
          ignore (acknowledge t : bool);
          Cancel
      | Committed -> Continue)

let mark_cleanup_failed () =
  Option.iter (current ()) ~f:(fun t -> t.cleanup_failed <- true)

let was_acknowledged t =
  match t.phase with
  | Acknowledged -> true
  | Open | Requested | Committed -> false

let cleanup_failed t = t.cleanup_failed
