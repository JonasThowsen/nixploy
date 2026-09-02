open Async
open Core

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
