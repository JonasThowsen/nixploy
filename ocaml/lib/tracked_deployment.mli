open Async

val deploy :
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  Store.deployment Deferred.Or_error.t
