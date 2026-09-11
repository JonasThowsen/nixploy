open Async

type prepared

type selection = {
  container_id : string;
  container_name : string;
  revision : string option;
}

type outcome = {
  selection : selection;
  exit_code : int;
  uncertainty : string option;
}

val list :
  working_directory:string ->
  target:Target_name.t ->
  Configuration.Runbook_command.t list Deferred.Or_error.t
(** Lists the selected local flake's commands; no SSH, build, or secrets. *)

val prepare :
  working_directory:string ->
  target:Target_name.t ->
  name:string ->
  prepared Deferred.Or_error.t
(** Validates the local definition and derives repository ownership without SSH.
*)

val target : prepared -> Configuration.Target.t
val project : prepared -> Project_name.t
val repository_identity : prepared -> string

val resource_key : prepared -> Resource_key.t
(** Canonical repository/project/target identity used to acquire the target
    guard. *)

val execute :
  with_guard:
    (prepared ->
    (unit -> outcome Deferred.Or_error.t) ->
    outcome Deferred.Or_error.t) ->
  on_selection:(selection -> unit Deferred.t) ->
  prepared ->
  outcome Deferred.Or_error.t
(** The mandatory guard callback MUST acquire the same remote target lock as
    deployment before invoking its thunk, and hold it until the thunk settles.
    Keep durable uncertainty evidence on Error or outcome.uncertainty <> None.
    Never replay the thunk. Resolution (including legacy ownership adoption) and
    exec happen inside it. on_selection must not retain command output. *)

val run :
  with_guard:
    (prepared ->
    (unit -> outcome Deferred.Or_error.t) ->
    outcome Deferred.Or_error.t) ->
  on_selection:(selection -> unit Deferred.t) ->
  working_directory:string ->
  target:Target_name.t ->
  name:string ->
  outcome Deferred.Or_error.t
(** Evaluates, selects and executes once, with no
    build/deploy/decryption/history. *)
