#!/usr/bin/env bash
set -euo pipefail
lib=$1
for module in application deployment deployment_request tracked_deployment source store direct_mode mutation_guard; do
  if grep -En '/etc/nixploy|Managed_application|Source_authority|Protected_git|Operation_receipt|Deployment_intent|Deployment_receipt_store|Host_metrics|Runtime_application|Control_plane_authority|Target_lease|NIXPLOY_APPLICATIONS' "$lib/$module.ml" "$lib/$module.mli"; then
    echo "service dependency leaked into daemonless core: $module" >&2
    exit 1
  fi
done
if grep -En '^val (preview_|managed_|admit_|application_metrics|application_logs)' "$lib/application.mli"; then
  echo 'service facade API survived cleanup' >&2
  exit 1
fi
printf 'daemonless core: no host registry, custody, receipts, broker, metrics or managed facade dependencies\n'
