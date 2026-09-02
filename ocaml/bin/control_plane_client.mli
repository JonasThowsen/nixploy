open Async

val request_control_plane_capabilities :
  uri:string ->
  required_capabilities:string list ->
  Protocol.Control_plane_capabilities.t Deferred.Or_error.t
(** Requests the remote control-plane compatibility contract over the typed
    WebSocket RPC transport. This handshake performs no deployment operation. *)
