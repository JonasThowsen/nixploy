open Core

(** Durable per-scope ownership evidence for the target-lease broker.

    State machine for one coordination scope:

    {e Absent --clear_clean_receipt--> Absent' --mark_dirty--> Dirty
       --write_clean_receipt--> Receipted --retire_dirty--> Clean}

    Filesystem encoding inside the broker-private, 0700 state directory:

    - [scope-<scope>.dirty] contains exactly "dirty <generation>\n"
    - [scope-<scope>.clean] contains exactly "clean <generation>\n"

    Invariants:

    - The dirty marker is created before a lease is granted and is never removed
      or overwritten except by [retire_dirty] with the exact matching
      generation, after an independently durable clean receipt exists.
    - Acquiring a scope first durably retires any stale clean receipt from the
      previous completed lease ([clear_clean_receipt]); removing clean evidence
      is always safe because it is never the only evidence of possibly unclean
      ownership.
    - Every creation step is file-fsynced and directory-fsynced before the next
      step begins. Any failure reports an error and leaves all existing files
      untouched; no code path ever deletes or rewrites the only evidence of
      possibly unclean ownership.
    - After a crash the observable states are exactly: neither file = Unused (no
      lease was durably granted); dirty only = Dirty (unclean owner; acquire is
      refused); clean only = Clean (release completed durably); both files =
      Blocked (uncertain mid-release; the broker must refuse to start). A lost
      directory fsync can only converge between these states; none of them
      misrepresents uncertainty as clean.
    - Startup ([scan_directory]) rejects any unexpected filename, any
      non-regular or foreign-owned entry, any malformed or partial contents, and
      any Blocked scope. The broker refuses to start in those cases. *)

type scope_evidence =
  | Unused
  | Clean
  | Dirty of Target_lease.uuid (* generation *)
  | Blocked

type pair = {
  dirty : Target_lease.uuid option;
  clean : Target_lease.uuid option;
}

type kind = Dirty_file | Clean_file

val max_entry_bytes : int
val dirty_marker_name : Target_lease.uuid -> string
val clean_receipt_name : Target_lease.uuid -> string

val parse_evidence_line : string -> (kind * Target_lease.uuid) Or_error.t
(** Pure parser for one durable-state line: kind plus generation UUID. *)

val classify_scope :
  dirty:Target_lease.uuid option ->
  clean:Target_lease.uuid option ->
  scope_evidence
(** Pure classification over optional validated generations. *)

val scan_directory :
  state_directory:string ->
  (string, scope_evidence, String.comparator_witness) Map.t Or_error.t
(** Reads and validates every entry of the state directory. Returns an error on
    any unexpected filename, unreadable or malformed entry, or kind/content
    mismatch. *)

val dirty_scopes :
  (string, scope_evidence, String.comparator_witness) Map.t ->
  Target_lease.uuid list

val has_blocked :
  (string, scope_evidence, String.comparator_witness) Map.t -> bool

(** Durable primitives. Each returns an error on any fsync/write/unlink/close
    failure and leaves existing evidence untouched. *)

val dirty_marker_exists :
  state_directory:string -> scope:Target_lease.uuid -> bool Or_error.t
(** Live check used at acquire time so evidence created after broker start still
    blocks the scope. *)

val clear_clean_receipt :
  state_directory:string -> scope:Target_lease.uuid -> unit Or_error.t
(** Retires a stale clean receipt from a previous completed lease (ENOENT is
    success). Removing clean evidence is always safe; removing unclean evidence
    never happens. *)

val mark_dirty :
  state_directory:string ->
  scope:Target_lease.uuid ->
  generation:Target_lease.uuid ->
  unit Or_error.t

val write_clean_receipt :
  state_directory:string ->
  scope:Target_lease.uuid ->
  generation:Target_lease.uuid ->
  unit Or_error.t

val retire_dirty :
  state_directory:string ->
  scope:Target_lease.uuid ->
  generation:Target_lease.uuid ->
  unit Or_error.t

val inject_failure_after : int -> unit
(** Test-only deterministic fault injection. Counts down over every counted
    write/fsync/unlink attempt made by the primitives above, in call order; the
    operation that reaches zero fails once with EIO and injection disables
    itself. A negative value disables injection. *)
