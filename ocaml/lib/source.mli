open Async
open Core

type t
type commit
type selection

val main_commit : working_directory:string -> commit Deferred.Or_error.t

val find_commit :
  working_directory:string -> revision:string -> commit Deferred.Or_error.t

val repository_identity : working_directory:string -> string Deferred.Or_error.t
(** Returns the configured [remote.origin.url], or the canonical working
    directory when the repository has no origin. *)

val repository_origin :
  working_directory:string -> string option Deferred.Or_error.t
(** Returns only the explicit Git origin, without a local-path fallback. *)

val local : working_directory:string -> selection Deferred.Or_error.t
val immutable : commit -> selection
val selection_commit : selection -> commit
val selection_is_local : selection -> bool

val prepare :
  working_directory:string -> selection:selection -> t Deferred.Or_error.t
(** Local selections snapshot tracked worktree bytes; immutable selections use
    Git checkout semantics. Evaluation, builds, and secrets share this source.
*)

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
(** Parses [git show --format=%H%x00%s%x00%ct] output from the selected
    repository. *)

module For_testing : sig
  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t

  val local : working_directory:string -> commit -> selection
end
