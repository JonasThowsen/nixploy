open Async
open Core

let require_managed_transport_with ~authorities ~authority_alias
    ~managed_application_key =
  let open Deferred.Or_error.Let_syntax in
  let%bind () =
    if String.is_empty (String.strip managed_application_key) then
      Deferred.Or_error.error_string
        "NIXPLOY_MANAGED_SELECTION_REQUIRED: managed application key is empty"
    else Deferred.Or_error.return ()
  in
  let%bind _authority =
    Nixploy.Control_plane_authority.find authorities ~alias:authority_alias
    |> Deferred.return
  in
  Deferred.Or_error.error_string
    "NIXPLOY_PIN_UNSUPPORTED: managed control-plane transport cannot verify \
     the configured server SPKI pin"

let require_managed_transport ~authority_alias ~managed_application_key =
  let open Deferred.Or_error.Let_syntax in
  let%bind authorities =
    Nixploy.Control_plane_authority.load () |> Deferred.return
  in
  require_managed_transport_with ~authorities ~authority_alias
    ~managed_application_key

module For_testing = struct
  let require_managed_transport = require_managed_transport_with
end

let origin_of_control_plane_uri uri_value =
  let open Or_error.Let_syntax in
  let uri = Uri.of_string uri_value in
  let%bind scheme =
    Uri.scheme uri
    |> Or_error.of_option
         ~error:
           (Error.of_string
              "NIXPLOY_CONTROL_PLANE_URI_INVALID: URI has no scheme")
  in
  let%bind host =
    Uri.host uri
    |> Or_error.of_option
         ~error:
           (Error.of_string "NIXPLOY_CONTROL_PLANE_URI_INVALID: URI has no host")
  in
  if not (String.equal scheme "http" || String.equal scheme "https") then
    Or_error.errorf
      "NIXPLOY_CONTROL_PLANE_URI_INVALID: unsupported URI scheme %S" scheme
  else if Option.is_some (Uri.userinfo uri) then
    Or_error.error_string
      "NIXPLOY_CONTROL_PLANE_URI_INVALID: URI must not contain user information"
  else if
    (not (String.is_empty (Uri.path uri) || String.equal (Uri.path uri) "/"))
    || (not (List.is_empty (Uri.query uri)))
    || Option.is_some (Uri.fragment uri)
  then
    Or_error.error_string
      "NIXPLOY_CONTROL_PLANE_URI_INVALID: URI must contain only an authority"
  else
    let origin = Uri.make ~scheme ~host ?port:(Uri.port uri) () in
    Ok (uri, Uri.to_string origin)

let request_control_plane_capabilities ~uri ~required_capabilities =
  let open Deferred.Or_error.Let_syntax in
  let%bind uri, origin = origin_of_control_plane_uri uri |> Deferred.return in
  let headers = Cohttp.Header.init_with "Origin" origin in
  let%bind connection = Rpc_websocket.Rpc.client ~headers uri in
  let%bind response =
    Rpc.Rpc.dispatch Protocol.Control_plane_capabilities.t connection
      {
        Protocol.Control_plane_capabilities.Query.protocol_major = 1;
        protocol_minor = 0;
        required_capabilities;
      }
  in
  Deferred.return response

(* TODO(tracer): Replace the explicit URI argument with a protected local
   authority alias before managed CLI commands use this transport. The narrow
   capabilities command is read-only and does not send operator credentials. *)
