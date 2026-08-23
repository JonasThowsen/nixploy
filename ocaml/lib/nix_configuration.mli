open Async

type evaluated

val load : working_directory:string -> Configuration.t Deferred.Or_error.t

val load_evaluated :
  offline:bool ->
  working_directory:string ->
  flake:string ->
  evaluated Deferred.Or_error.t

val configuration : evaluated -> Configuration.t
val json : evaluated -> string
