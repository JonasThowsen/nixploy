open Async

val open_unix_forward :
  target:Configuration.Target.t ->
  local_socket:string ->
  remote_socket:string ->
  unit Deferred.Or_error.t
(** Starts OpenSSH forwarding [local_socket] to [remote_socket] on the target
    (see {!Remote_command.unix_forward_args}) and resolves once the local socket
    exists, which OpenSSH creates only after it has verified the host key and
    authenticated. SSH exiting first is an [NIXPLOY_SSH_FAILED] error.

    The forward runs in its own process group, outside the termination handling
    of {!Process_runner}, so compensation after an interruption can still reach
    Podman. It is stopped at shutdown. *)
