open Async
open Core
module Authority = Nixploy.Control_plane_authority
module Client = Nixploy_control_plane_client.Control_plane_client

let authority_record =
  {|
((version 1)
 (authorities
  (((alias netcup)
    (uri https://control.example.invalid)
    (pinned_server_spki_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
    (trusted_proxy_authority https://control.example.invalid)))))
|}

let () =
  let authorities = Authority.For_testing.parse authority_record |> Or_error.ok_exn in
  don't_wait_for
    (Client.For_testing.require_managed_transport ~authorities
       ~authority_alias:"netcup" ~managed_application_key:"sample-production"
     >>| function
     | Error error ->
         assert (
           String.is_substring (Error.to_string_hum error)
             ~substring:"NIXPLOY_PIN_UNSUPPORTED");
         Shutdown.shutdown 0
     | Ok () ->
         eprintf "managed transport unexpectedly bypassed SPKI verification\n";
         Shutdown.shutdown 1);
  never_returns (Scheduler.go ())
