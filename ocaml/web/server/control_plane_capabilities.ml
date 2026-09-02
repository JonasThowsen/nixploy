open Core

type t = {
  control_plane_id : string;
  package_revision : string;
  protocol_major : int;
  protocol_minor : int;
  deployment_config_schemas : string list;
  capabilities : string list;
}

let max_identifier_bytes = 128
let max_requested_capabilities = 16
let max_capability_bytes = 64
let supported_protocol_major = 1
let supported_protocol_minor = 0
let supported_deployment_config_schemas = [ "v0.2"; "v0.3"; "v0.4" ]

let supported_capabilities =
  [
    "managed-read-v1";
    "managed-deploy-v1";
    "managed-cancel-v1";
    "managed-prune-v1";
  ]

let valid_identifier value =
  (not (String.is_empty value))
  && String.length value <= max_identifier_bytes
  && String.equal value (String.strip value)
  && not (String.exists value ~f:Char.is_whitespace)

let create ~control_plane_id ~package_revision =
  if not (valid_identifier control_plane_id) then
    Or_error.error_string
      "control-plane capability descriptor has an invalid control-plane \
       identity"
  else if not (valid_identifier package_revision) then
    Or_error.error_string
      "control-plane capability descriptor has an invalid package revision"
  else
    Ok
      {
        control_plane_id;
        package_revision;
        protocol_major = supported_protocol_major;
        protocol_minor = supported_protocol_minor;
        deployment_config_schemas = supported_deployment_config_schemas;
        capabilities = supported_capabilities;
      }

let package_revision descriptor = descriptor.package_revision

let valid_requested_capability capability =
  (not (String.is_empty capability))
  && String.length capability <= max_capability_bytes
  && String.equal capability (String.strip capability)
  && not (String.exists capability ~f:Char.is_whitespace)

let validate_requested_capabilities capabilities =
  if List.length capabilities > max_requested_capabilities then
    Or_error.errorf
      "NIXPLOY_CAPABILITY_UNAVAILABLE: at most %d capabilities may be requested"
      max_requested_capabilities
  else if not (List.for_all capabilities ~f:valid_requested_capability) then
    Or_error.error_string
      "NIXPLOY_CAPABILITY_UNAVAILABLE: requested capability is invalid"
  else if List.contains_dup capabilities ~compare:String.compare then
    Or_error.error_string
      "NIXPLOY_CAPABILITY_UNAVAILABLE: requested capability is duplicated"
  else Ok ()

let negotiate_client_capabilities descriptor
    (request : Protocol.Control_plane_capabilities.Query.t) =
  let open Or_error.Let_syntax in
  let%bind () = validate_requested_capabilities request.required_capabilities in
  if not (Int.equal request.protocol_major descriptor.protocol_major) then
    Or_error.errorf
      "NIXPLOY_PROTOCOL_INCOMPATIBLE: server supports protocol major %d, \
       client requested %d"
      descriptor.protocol_major request.protocol_major
  else if request.protocol_minor > descriptor.protocol_minor then
    Or_error.errorf
      "NIXPLOY_PROTOCOL_INCOMPATIBLE: server supports protocol minor at most \
       %d, client requested %d"
      descriptor.protocol_minor request.protocol_minor
  else
    let%bind () =
      Or_error.all_unit
        (List.map request.required_capabilities ~f:(fun capability ->
             if List.mem descriptor.capabilities capability ~equal:String.equal
             then Ok ()
             else
               Or_error.errorf
                 "NIXPLOY_CAPABILITY_UNAVAILABLE: server does not provide %s"
                 capability))
    in
    Ok
      {
        Protocol.Control_plane_capabilities.control_plane_id =
          descriptor.control_plane_id;
        package_revision = descriptor.package_revision;
        protocol_major = descriptor.protocol_major;
        protocol_minor = descriptor.protocol_minor;
        deployment_config_schemas = descriptor.deployment_config_schemas;
        capabilities = descriptor.capabilities;
      }
