open Async

type t

val prepare : working_directory:string -> t Deferred.Or_error.t
val cleanup : t -> unit Deferred.t
val path : t -> string
val revision : t -> string
val repository : t -> string
