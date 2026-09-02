open Core

type t
(** Validated server identity and compatibility information for the mandatory
    control-plane capabilities handshake. *)

val create : control_plane_id:string -> package_revision:string -> t Or_error.t
(** Creates a bounded control-plane capability descriptor. The package revision
    is operator-visible build information and must never contain credentials. *)

val negotiate_client_capabilities :
  t ->
  Protocol.Control_plane_capabilities.Query.t ->
  Protocol.Control_plane_capabilities.t Or_error.t
(** Negotiates one client capability request. Unknown capabilities and an
    incompatible protocol major fail before an application operation is
    admitted. *)
