(** Makes the local SSH and Podman clients behave the same in a terminal and in
    a sandboxed agent: no writable home or runtime directory is required, and
    the user's ssh-agent is found even when [SSH_AUTH_SOCK] was not passed on. *)

val adopt_ssh_agent : unit -> string option
(** When [SSH_AUTH_SOCK] is unset, empty, or not a connectable socket, sets it
    to the first connectable standard per-user agent socket
    ([$XDG_RUNTIME_DIR/ssh-agent], [/run/user/UID/ssh-agent], GNOME keyring,
    gcr or gpg-agent) and returns that path. Returns [None] when nothing
    changed. *)

val ssh_agent_usable : unit -> bool
(** [SSH_AUTH_SOCK] names a socket this process can connect to. *)

val describe_ssh_agent : unit -> string
(** A short diagnostic of the ssh-agent this process can see. *)

val podman : unit -> Core_unix.env
(** Environment for every local Podman client process. Connection records and
    Podman's runtime directory live in a private per-process directory under
    [$TMPDIR], removed at shutdown, so a read-only [~/.config] or
    [/run/user/UID] cannot break deployment and the user's own connection list
    is never modified. *)
