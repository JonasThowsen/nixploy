#!/usr/bin/env bash
set -euo pipefail

app=$1

# Managed browser reads must use the grant-bearing capability/RPC versions only.
grep -Fq 'Protocol.Control_plane_capabilities.V1.t' "$app"
grep -Fq 'Protocol.List_applications.V1.t' "$app"
grep -Fq 'Protocol.List_deployments.V1.t' "$app"
grep -Fq 'Protocol.Get_application_logs.V1.t' "$app"
grep -Fq 'Protocol.Get_metrics.V1.t' "$app"

# Renew well before the server's fixed five-minute TTL. The executable
# browser_capability_grant_state_test covers failed renewal, reconnect, expiry,
# and V1 query token selection.
grep -Fq '~every:(Time_ns.Span.of_sec 30.) capabilities_query' "$app"
grep -Fq 'Capability_grant_state.token_for_managed_rpc' "$app"
grep -Fq 'Capability_grant_state.renewal_failed' "$app"
grep -Fq 'possibly expired' "$app"

if grep -Fq 'dispatcher Protocol.Control_plane_capabilities.V1.t' "$app"; then
  echo 'browser capability handshake must be renewable polling, not one-shot dispatch' >&2
  exit 1
fi

echo 'browser renews typed capability grants and clears them on renewal failure'
