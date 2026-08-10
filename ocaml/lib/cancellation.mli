open Async

type t

type request = Accepted | Already_requested | Too_late
[@@deriving compare, equal, sexp]

type commit = Continue | Cancel [@@deriving compare, equal, sexp]

val create : unit -> t
val within : t -> (unit -> 'a) -> 'a
val current : unit -> t option
val request : t -> request
val requested : t -> unit Deferred.t
val acknowledge_current : unit -> bool
val commit_current : unit -> commit
val mark_cleanup_failed : unit -> unit
val was_acknowledged : t -> bool
val cleanup_failed : t -> bool
