open Core
module Grant_state = Nixploy_web_client_state.Capability_grant_state

let query state ~now_ms =
  {
    Protocol.List_applications.V1.Query.capability_grant =
      Grant_state.token_for_managed_rpc state ~now_ms;
  }

let () =
  let initial = Grant_state.empty in
  assert (String.is_empty (query initial ~now_ms:0L).capability_grant);
  let first =
    Grant_state.renewed initial ~capability_grant:"first-grant"
      ~grant_expires_at_ms:1_000L
  in
  assert (String.equal (query first ~now_ms:999L).capability_grant "first-grant");
  let refreshed =
    Grant_state.renewed first ~capability_grant:"refreshed-grant"
      ~grant_expires_at_ms:2_000L
  in
  assert (
    String.equal (query refreshed ~now_ms:1_001L).capability_grant
      "refreshed-grant");
  let failed_renewal = Grant_state.renewal_failed refreshed in
  assert (String.is_empty (query failed_renewal ~now_ms:1_002L).capability_grant);
  let reconnected = Grant_state.reconnected refreshed in
  assert (String.is_empty (query reconnected ~now_ms:1_002L).capability_grant);
  assert (String.is_empty (query refreshed ~now_ms:2_000L).capability_grant)
