open Async
open Core

val identity_file : Configuration.Target.t -> string option

val unix_forward_args :
  Configuration.Target.t ->
  local_socket:string ->
  remote_socket:string ->
  string list
(** OpenSSH argv forwarding [local_socket] to [remote_socket] on the target,
    with the same strict, non-interactive options as {!run}: the system
    ssh_config (HostName, HostKeyAlias, ...), StrictHostKeyChecking=yes and
    [NIXPLOY_SSH_KNOWN_HOSTS_FILE] all apply. *)

val ssh_failure : Configuration.Target.t -> string -> Error.t
(** The [NIXPLOY_SSH_FAILED] error for ssh's own failure, from its stderr. *)

val failure_hint : Configuration.Target.t -> string -> string
(** An actionable explanation of an SSH or Podman-over-SSH connection failure
    from its stderr: no usable key (describing the ssh-agent socket and
    identity file this process can see), an untrusted host key, an unreachable
    network, or a refused connection. *)

val run :
  ?stdin:string ->
  ?ignore_termination:bool ->
  target:Configuration.Target.t ->
  timeout:Time_ns.Span.t ->
  max_output_bytes:int ->
  string list ->
  Process_runner.t Deferred.Or_error.t
(** Runs literal argv over strict, non-interactive SSH. SSH's own failure (exit
    255) is an [NIXPLOY_SSH_FAILED] error naming the destination, the last
    stderr lines, and {!failure_hint}; any other exit is returned as a result.
*)
