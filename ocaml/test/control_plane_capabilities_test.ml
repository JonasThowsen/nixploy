open Core
module Capabilities = Nixploy_rpc_mapping.Control_plane_capabilities

let descriptor =
  Capabilities.create ~control_plane_id:"netcup-control-plane"
    ~package_revision:"test-revision"
  |> Or_error.ok_exn

let request ?(protocol_major = 1) ?(protocol_minor = 0)
    ?(required_capabilities = []) () =
  {
    Protocol.Control_plane_capabilities.Query.protocol_major;
    protocol_minor;
    required_capabilities;
  }

let () =
  let accepted =
    Capabilities.negotiate_client_capabilities descriptor
      (request ~required_capabilities:[ "managed-read-v1" ] ())
    |> Or_error.ok_exn
  in
  assert (String.equal accepted.control_plane_id "netcup-control-plane");
  assert (String.equal accepted.package_revision "test-revision");
  assert (Int.equal accepted.protocol_major 1);
  assert (List.mem accepted.capabilities "managed-read-v1" ~equal:String.equal);
  assert (
    Result.is_error
      (Capabilities.negotiate_client_capabilities descriptor
         (request ~protocol_major:2 ())));
  assert (
    Result.is_error
      (Capabilities.negotiate_client_capabilities descriptor
         (request ~protocol_minor:1 ())));
  assert (
    Result.is_error
      (Capabilities.negotiate_client_capabilities descriptor
         (request ~required_capabilities:[ "unknown-capability" ] ())));
  assert (
    Result.is_error
      (Capabilities.negotiate_client_capabilities descriptor
         (request
            ~required_capabilities:[ "managed-read-v1"; "managed-read-v1" ]
            ())))
