open Core
module Grant = Nixploy_rpc_mapping.Capability_grant

let identity = Grant.Tailscale_login "operator@example.com"

let factory ?(now_ms = 1_000L) ?(entropy = String.make 32 'a') () =
  { Grant.now_ms = (fun () -> now_ms); random_bytes = (fun _ -> Ok entropy); ttl_ms = 500L }

let grant =
  Grant.create (factory ()) ~identity ~capabilities:[ "managed-read-v1" ]
    ~package_revision:"revision" ~protocol_major:1 ~protocol_minor:0
  |> Or_error.ok_exn

let valid () =
  Grant.validate grant ~token:(Grant.token grant) ~identity ~package_revision:"revision"
    ~protocol_major:1 ~protocol_minor:0 ~capability:"managed-read-v1" ~now_ms:1_499L

let () =
  assert (String.length (Grant.token grant) = 43);
  assert (Int64.equal (Grant.issued_at_ms grant) 1_000L);
  assert (Result.is_ok (valid ()));
  assert (Result.is_error (Grant.validate grant ~token:"not-a-grant"
    ~identity ~package_revision:"revision" ~protocol_major:1 ~protocol_minor:0
    ~capability:"managed-read-v1" ~now_ms:1_001L));
  assert (Result.is_error (Grant.validate grant ~token:(Grant.token grant)
    ~identity ~package_revision:"different" ~protocol_major:1 ~protocol_minor:0
    ~capability:"managed-read-v1" ~now_ms:1_001L));
  assert (Result.is_error (Grant.validate grant ~token:(Grant.token grant)
    ~identity ~package_revision:"revision" ~protocol_major:1 ~protocol_minor:0
    ~capability:"managed-deploy-v1" ~now_ms:1_001L));
  let expired =
    Grant.validate grant ~token:(Grant.token grant) ~identity
      ~package_revision:"revision" ~protocol_major:1 ~protocol_minor:0
      ~capability:"managed-read-v1" ~now_ms:1_500L
  in
  assert (
    match expired with
    | Error error ->
        String.is_substring (Error.to_string_hum error)
          ~substring:"NIXPLOY_CAPABILITY_GRANT_EXPIRED"
    | Ok () -> false);
  assert (Result.is_error (Grant.create (factory ~entropy:"short" ()) ~identity
    ~capabilities:[] ~package_revision:"revision" ~protocol_major:1 ~protocol_minor:0))
