open Async
open Core

type t

type state = Requested | Running | Succeeded | Failed | Cancelled
[@@deriving compare, equal, sexp]

type resource_state = Unknown | Present | Absent
[@@deriving compare, equal, sexp]

type deployment

val open_ : path:string -> t Deferred.Or_error.t

val with_reconciled_lease :
  t ->
  application_key:string option ->
  working_directory:string ->
  target:Target_name.t ->
  ?exclude_id:string ->
  (unit -> 'a Deferred.Or_error.t) ->
  'a Deferred.Or_error.t
(** Acquires the exact-scope local flock, marks active history left by a dead
    local process as failed with an unknown remote outcome, and only then runs
    [operation]. The callback receives no lease authority, so it cannot
    reconcile after this function releases the flock. A managed application
    includes matching unkeyed CLI history but never history keyed to another
    application. *)

val request :
  t ->
  application_key:string option ->
  working_directory:string ->
  target:Target_name.t ->
  commit:Source.commit ->
  deployment Deferred.Or_error.t

val request_prune :
  t ->
  application_key:string option ->
  working_directory:string ->
  target:Target_name.t ->
  canonical_intent:string ->
  candidate_snapshot:string ->
  deployment Deferred.Or_error.t
(** Durably admits one prune request before the target lease. The canonical
    candidate snapshot is immutable and must be bound before cleanup. *)

val bind_prune_operation :
  t ->
  id:string ->
  application_key:string option ->
  working_directory:string ->
  target:Target_name.t ->
  canonical_intent:string ->
  candidate_snapshot:string ->
  unit Deferred.Or_error.t
(** Atomically binds the exact admitted prune operation once. *)

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

val review : t -> id:string -> error:Error.t -> unit Deferred.Or_error.t
(** Terminal error after a remote prune may have taken effect. This is a
    non-replayable review outcome, represented as a failed operation with a
    durable [review] stage. *)

val succeed_prune : t -> id:string -> message:string -> unit Deferred.Or_error.t
val cancel : t -> id:string -> unit Deferred.Or_error.t
val list : t -> limit:int -> deployment list Deferred.Or_error.t

val list_for_application :
  t ->
  application_key:string ->
  working_directory:string ->
  target:Target_name.t ->
  limit:int ->
  deployment list Deferred.Or_error.t

val list_for_scope :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  limit:int ->
  deployment list Deferred.Or_error.t

val latest_successful_for_application :
  t ->
  application_key:string ->
  working_directory:string ->
  target:Target_name.t ->
  deployment option Deferred.Or_error.t
(** Returns the newest successful deployment for the exact managed application
    identity. Unkeyed local CLI history and later non-successful rows are not
    considered. *)

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
val application_key : deployment -> string option
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
