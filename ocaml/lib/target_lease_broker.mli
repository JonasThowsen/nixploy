open Core

(** Linux Unix-socket broker for the bounded target-lease tracer. *)

type configuration

val create_configuration :
  broker_uid:int ->
  socket_path:string ->
  state_directory:string ->
  authority:string ->
  identity:string ->
  scope_users:(string * string list) list ->
  configuration Or_error.t
(** [broker_uid] is the dedicated broker identity; callers pass the real
    effective UID. Each configuration carries a fresh stop flag; raising it
    makes a running [run] return [Ok ()] after closing every connection. *)

val stop_flag : configuration -> bool ref
(** Rejects root peers, peers resolving to UID 0 or the broker identity, and a
    broker that itself runs as root. *)

val run : configuration -> unit Or_error.t
(** Serves lease sessions until an operational or durable-state failure.

    Startup first validates the durable state directory (see
    [Target_lease_state]); any unexpected entry, malformed contents, or
    ambiguous dirty-marker-plus-clean-receipt pair refuses to start. Scopes with
    only a durable dirty marker are served [V1 DIRTY] until an operator resolves
    the evidence; they are never cleared automatically.

    While serving, any durability error during acquire or release is fatal in
    the same select-loop cycle: no further accepts or dispatch happen, all
    connections close, and the process exits nonzero. A fixed per-cycle accept
    budget keeps connection floods from starving existing clients. *)
