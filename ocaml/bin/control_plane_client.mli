open Async

val require_managed_transport :
  authority_alias:string ->
  managed_application_key:string ->
  unit Deferred.Or_error.t
(** Resolves a named managed command only through the root-owned authority
    record, without evaluating caller-controlled Nix configuration. The
    application key is a server-side authorization input, not a URI or
    credential. This fails closed until the RPC WebSocket transport can verify
    the configured SPKI pin on its TLS connection. *)

val request_control_plane_capabilities :
  uri:string ->
  required_capabilities:string list ->
  Protocol.Control_plane_capabilities.t Deferred.Or_error.t
(** Requests the remote control-plane compatibility contract over the typed
    WebSocket RPC transport. This handshake performs no deployment operation. *)

module For_testing : sig
  val require_managed_transport :
    authorities:Nixploy.Control_plane_authority.t list ->
    authority_alias:string ->
    managed_application_key:string ->
    unit Deferred.Or_error.t
end
