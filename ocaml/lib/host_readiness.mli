open Async
open Core

(** Read-only checks that owned workloads come back after a host reboot.

    Server provisioning stays outside nixploy, so these checks only report. A
    failed probe is reported as [Unknown], never as a deployment failure. *)

type state = Ready | Not_ready | Unknown of string
[@@deriving compare, equal, sexp]

type check = { name : string; state : state; remedy : string }
[@@deriving compare, equal, sexp]

type t

val inspect : target:Configuration.Target.t -> t Deferred.t
(** Probes the SSH account's Podman mode, boot-time container restart, and, for
    web targets, whether Caddy resumes API-managed routes after a restart. *)

val checks : t -> check list

val warnings : t -> string list
(** One diagnostic per check that is not [Ready]. *)

module For_testing : sig
  type probe = Process_runner.t Or_error.t

  val assess :
    user:string ->
    web:bool ->
    uid:probe ->
    linger:probe ->
    restart_unit:probe ->
    caddy_exec_start:probe ->
    t
end
