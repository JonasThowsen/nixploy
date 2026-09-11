open Async
open Core

val commands :
  list:
    (working_directory:string ->
    target:Nixploy.Target_name.t ->
    Nixploy.Configuration.Runbook_command.t list Deferred.Or_error.t) ->
  run:
    (on_selection:(Nixploy.Runbook.selection -> unit Deferred.t) ->
    working_directory:string ->
    target:Nixploy.Target_name.t ->
    name:string ->
    Nixploy.Runbook.outcome Deferred.Or_error.t) ->
  (string * Command.t) list
(** Parses only the fixed named runbook surface. Supply Application callbacks,
    with the daemonless mutation guard already installed in the run callback. *)
