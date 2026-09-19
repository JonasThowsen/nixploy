open Async

val with_mutation :
  ?certainty:('a -> string option) ->
  project:Project_name.t ->
  target:Configuration.Target.t ->
  (unit -> 'a Deferred.Or_error.t) ->
  'a Deferred.Or_error.t
(** Serializes deploy, prune, and runbook operations across independent clients.
    An atomic remote directory is durable uncertainty evidence, not a lease:
    failure, cancellation, or owner loss never permits automatic takeover. Only
    a successful callback with a known outcome clears it. Operators must
    reconcile remote effects before manually removing a retained directory. The
    scope intentionally covers migration identities and repositories sharing the
    same project/target name. Evidence lives under .nixploy-mutations in the SSH
    login directory, never in temporary storage. Requires remote mkdir, sync,
    and rmdir; no helper service.

    [certainty value] returns an uncertainty diagnostic when a completed
    callback must retain evidence. The value (including its child exit code) is
    preserved. A known command failure returns [None]; a transport-uncertain
    exit returns [Some _]. *)

type marker = Absent | Present of string [@@deriving compare, equal, sexp]

val inspect :
  project:Project_name.t ->
  target:Configuration.Target.t ->
  marker Deferred.Or_error.t
(** Read-only: reports whether this project/target's marker directory exists
    (relative to the SSH login directory). Presence means an operation is
    running or left uncertainty evidence; it is never removed here. *)

module For_testing : sig
  val with_mutation :
    ?certainty:('a -> string option) ->
    run:(string list -> unit Deferred.Or_error.t) ->
    interrupted:(unit -> bool) ->
    project:Project_name.t ->
    target:Target_name.t ->
    (unit -> 'a Deferred.Or_error.t) ->
    'a Deferred.Or_error.t
end
