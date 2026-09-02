open Core
module Authority = Nixploy.Control_plane_authority

let valid =
  {|
((version 1)
 (authorities
  (((alias netcup)
    (uri https://control.example.invalid:443)
    (pinned_server_spki_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
    (trusted_proxy_authority https://control.example.invalid)))))
|}

let () =
  let authority =
    Authority.For_testing.parse valid |> Or_error.ok_exn |> List.hd_exn
  in
  assert (String.equal (Authority.alias authority) "netcup");
  assert (
    String.equal
      (Uri.to_string (Authority.uri authority))
      "https://control.example.invalid:443");
  assert (
    Result.is_error
      (Authority.For_testing.parse
         {|
((version 1)
 (authorities
  (((alias netcup)
    (uri http://control.example.invalid)
    (pinned_server_spki_sha256 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=)
    (trusted_proxy_authority https://control.example.invalid)))))
|}));
  assert (
    Result.is_error
      (Authority.For_testing.parse
         {|
((version 1)
 (authorities
  (((alias Netcup)
    (uri https://control.example.invalid)
    (pinned_server_spki_sha256 not-a-pin)
    (trusted_proxy_authority https://control.example.invalid)))))
|}));
  assert (
    Result.is_error
      (Authority.For_testing.parse {|
((version 2) (authorities ()))
|}));
  assert (Result.is_error (Authority.find [ authority ] ~alias:"unknown"));
  assert (
    Result.is_ok
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o644
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:1000 ~perm:0o644
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o664
         ~regular:true));
  assert (
    Result.is_error
      (Authority.For_testing.validate_file_metadata ~uid:0 ~perm:0o600
         ~regular:false))
