open Async

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  store:Store.t ->
  working_directory:string ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t
