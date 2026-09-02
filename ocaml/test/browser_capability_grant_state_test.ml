open Core
module Grant_state = Nixploy_web_client_state.Capability_grant_state

let query state ~now_monotonic_ms =
  {
    Protocol.List_applications.V1.Query.capability_grant =
      Grant_state.token_for_managed_rpc state ~now_monotonic_ms;
  }

let renewed state ~capability_grant ~server_time_ms ~grant_expires_at_ms
    ~received_at_monotonic_ms =
  Grant_state.renewed state ~capability_grant ~server_time_ms
    ~grant_expires_at_ms ~received_at_monotonic_ms

let () =
  let initial = Grant_state.empty in
  assert (String.is_empty (query initial ~now_monotonic_ms:0L).capability_grant);
  (* A browser wall clock that is either far ahead or behind the server must
     not shorten or extend the negotiated lifetime.  Only elapsed monotonic
     time after response receipt is relevant. *)
  let server_ahead =
    renewed initial ~capability_grant:"server-ahead" ~server_time_ms:3_600_000L
      ~grant_expires_at_ms:3_601_000L ~received_at_monotonic_ms:500L
  in
  assert (
    String.equal (query server_ahead ~now_monotonic_ms:1_499L).capability_grant
      "server-ahead");
  assert (
    String.is_empty
      (query server_ahead ~now_monotonic_ms:1_500L).capability_grant);
  let server_behind =
    renewed initial ~capability_grant:"server-behind" ~server_time_ms:10L
      ~grant_expires_at_ms:1_010L ~received_at_monotonic_ms:9_000_000L
  in
  assert (
    String.equal
      (query server_behind ~now_monotonic_ms:9_000_999L).capability_grant
      "server-behind");
  assert (
    String.is_empty
      (query server_behind ~now_monotonic_ms:9_001_000L).capability_grant);
  let refreshed =
    renewed server_behind ~capability_grant:"refreshed-grant"
      ~server_time_ms:5_000L ~grant_expires_at_ms:6_000L
      ~received_at_monotonic_ms:9_001_000L
  in
  assert (
    String.equal (query refreshed ~now_monotonic_ms:9_001_999L).capability_grant
      "refreshed-grant");
  assert (
    String.is_empty
      (query
         (renewed initial ~capability_grant:"invalid" ~server_time_ms:5_000L
            ~grant_expires_at_ms:5_000L ~received_at_monotonic_ms:1L)
         ~now_monotonic_ms:1L)
        .capability_grant);
  assert (
    String.is_empty
      (query
         (renewed initial ~capability_grant:"oversized" ~server_time_ms:0L
            ~grant_expires_at_ms:300_001L ~received_at_monotonic_ms:1L)
         ~now_monotonic_ms:1L)
        .capability_grant);
  let failed_renewal = Grant_state.renewal_failed refreshed in
  assert (
    String.is_empty
      (query failed_renewal ~now_monotonic_ms:9_001_001L).capability_grant);
  let reconnected = Grant_state.reconnected refreshed in
  assert (
    String.is_empty
      (query reconnected ~now_monotonic_ms:9_001_001L).capability_grant)
