open Async

val deploy :
  ?on_stage:(Deployment.stage -> string -> unit Deferred.t) ->
  ?on_requested:(Store.deployment -> unit) ->
  ?application_key:string ->
  store:Store.t ->
  working_directory:string ->
  commit:Source.commit ->
  target:Target_name.t ->
  unit ->
  Store.deployment Deferred.Or_error.t
