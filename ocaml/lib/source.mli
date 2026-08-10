open Async
open Core

type t
type commit

val preview_main : working_directory:string -> commit Deferred.Or_error.t

val find_commit :
  working_directory:string -> revision:string -> commit Deferred.Or_error.t

val prepare : working_directory:string -> commit:commit -> t Deferred.Or_error.t
val cleanup : t -> unit Deferred.t
val path : t -> string
val revision : t -> string
val repository : t -> string
val commit_revision : commit -> string
val commit_subject : commit -> string
val commit_timestamp_ms : commit -> int64

module For_testing : sig
  val commit :
    revision:string -> subject:string -> timestamp_ms:int64 -> commit Or_error.t
end
