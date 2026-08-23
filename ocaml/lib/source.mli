open Async
open Core

type t
type commit
type selection

val preview_main : working_directory:string -> commit Deferred.Or_error.t

val find_commit :
  working_directory:string -> revision:string -> commit Deferred.Or_error.t

val repository_identity : working_directory:string -> string Deferred.Or_error.t
(** Returns the configured [remote.origin.url], or the canonical working
    directory when the repository has no origin. *)

val repository_origin :
  working_directory:string -> string option Deferred.Or_error.t
(** Returns only an explicit Git origin. Production preview admission rejects
    the canonical-directory fallback used by local compatibility flows. *)

val local : working_directory:string -> selection Deferred.Or_error.t
val immutable : commit -> selection
val selection_commit : selection -> commit
val selection_is_local : selection -> bool

val prepare :
  working_directory:string -> selection:selection -> t Deferred.Or_error.t
(** Local and non-production compatibility materialization. Local selections
    snapshot tracked worktree bytes; immutable selections use ordinary Git
    checkout semantics and must not be used for protected production source. *)

val prepare_protected :
  working_directory:string ->
  protected_git:Protected_git.t ->
  repository_identity:string ->
  commit:commit ->
  t Deferred.Or_error.t
(** Materializes regular files directly from the admitted commit's blob objects,
    bypassing checkout attributes, filters, hooks, templates, replacement refs,
    and inherited configuration. Written bytes are read back and compared with
    the selected blob bytes. *)

val cleanup : t -> unit Deferred.t
val path : t -> string
val nix_root : t -> string
val nix_flake : t -> string
val revision : t -> string
val repository : t -> string
val is_local : t -> bool
val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64

val commit_of_git_show : string -> commit Or_error.t
(** Parses trusted [git show --format=%H%x00%s%x00%ct] output. The caller is
    responsible for the Git process custody boundary. *)

module For_testing : sig
  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t

  val local : working_directory:string -> commit -> selection
end
