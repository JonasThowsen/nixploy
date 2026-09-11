open Async
open Core

type t

type state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

type deployment

val open_ : path:string -> t Deferred.Or_error.t

val record_prune_event :
  t ->
  operation_id:string ->
  working_directory:string ->
  target:Target_name.t ->
  message:string ->
  unit Deferred.Or_error.t
(** Appends durable, secret-free scoped prune progress before and after effects.
    An unfinished event sequence is uncertainty, never permission to retry. *)

val with_reconciled_lease :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  (unit -> 'a Deferred.Or_error.t) ->
  'a Deferred.Or_error.t
(** Acquires the exact-scope local flock, marks active history left by a dead
    local process as failed with an unknown remote outcome, and only then runs
    [operation]. The callback receives no lease authority, so it cannot
    reconcile after this function releases the flock. Historical keyed service
    rows are preserved but never claimed as CLI operations. The remote guard,
    not this local flock, coordinates independent clients. *)

val request :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  commit:Source.commit ->
  deployment Deferred.Or_error.t

val record_stage :
  t -> id:string -> stage:string -> message:string -> unit Deferred.Or_error.t
(** Writes trusted durable progress while the operation remains active. Terminal
    compare-and-set transitions reject every later heartbeat or stage update. *)

val request_cancellation : t -> id:string -> unit Deferred.Or_error.t

val succeed :
  t ->
  id:string ->
  container_name:string ->
  message:string ->
  unit Deferred.Or_error.t

val fail : t -> id:string -> error:Error.t -> unit Deferred.Or_error.t
val cancel : t -> id:string -> unit Deferred.Or_error.t
val list : t -> limit:int -> deployment list Deferred.Or_error.t

val list_for_scope :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  limit:int ->
  deployment list Deferred.Or_error.t

val resource_state :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_state Deferred.Or_error.t

val set_resource_state :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  resource_state ->
  unit Deferred.Or_error.t

val find : t -> id:string -> deployment option Deferred.Or_error.t
val id : deployment -> string

val legacy_application_key : deployment -> string option
(** Read-only migration discriminator; new CLI requests always store NULL. *)

val working_directory : deployment -> string
val target : deployment -> Target_name.t
val state : deployment -> state
val stage : deployment -> string
val message : deployment -> string
val revision : deployment -> string option
val commit_subject : deployment -> string option
val commit_timestamp_ms : deployment -> int64 option
val container_name : deployment -> string option
val error : deployment -> string option
val requested_at_ms : deployment -> int64
val started_at_ms : deployment -> int64 option
val finished_at_ms : deployment -> int64 option
val cancel_requested_at_ms : deployment -> int64 option
val updated_at_ms : deployment -> int64
val state_name : state -> string
