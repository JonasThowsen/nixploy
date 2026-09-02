open Async

val require_managed_transport :
  Nixploy.Configuration.Control_plane.t -> unit Deferred.Or_error.t
(** Resolves the flake-selected authority only from the root-owned record, then
    fails closed until the RPC WebSocket transport can verify the configured
    SPKI pin on its TLS connection. *)

val request_control_plane_capabilities :
  uri:string ->
  required_capabilities:string list ->
  Protocol.Control_plane_capabilities.t Deferred.Or_error.t
(** Requests the remote control-plane compatibility contract over the typed
    WebSocket RPC transport. This handshake performs no deployment operation. *)
