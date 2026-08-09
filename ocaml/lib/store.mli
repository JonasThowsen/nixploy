open Async
open Core

type t

type state = Requested | Running | Succeeded | Failed
[@@deriving compare, equal, sexp]

type deployment

val open_ : path:string -> t Deferred.Or_error.t

val with_lease :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  (unit -> 'a Deferred.Or_error.t) ->
  'a Deferred.Or_error.t

val request :
  t ->
  working_directory:string ->
  target:Target_name.t ->
  deployment Deferred.Or_error.t

val record_stage :
  t ->
  id:string ->
  stage:Deployment.stage ->
  message:string ->
  unit Deferred.Or_error.t

val succeed : t -> id:string -> result:Deployment.t -> unit Deferred.Or_error.t
val fail : t -> id:string -> error:Error.t -> unit Deferred.Or_error.t
val list : t -> limit:int -> deployment list Deferred.Or_error.t
val find : t -> id:string -> deployment option Deferred.Or_error.t
val id : deployment -> string
val working_directory : deployment -> string
val target : deployment -> Target_name.t
val state : deployment -> state
val stage : deployment -> string
val message : deployment -> string
val revision : deployment -> string option
val container_name : deployment -> string option
val error : deployment -> string option
val requested_at_ms : deployment -> int64
val updated_at_ms : deployment -> int64
val state_name : state -> string
