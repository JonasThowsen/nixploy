#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

for interface in \
  "$root/lib/application.mli" \
  "$root/lib/tracked_deployment.mli" \
  "$root/lib/process_runner.mli" \
  "$root/lib/deployment.mli" \
  "$root/lib/podman.mli"; do
  if grep -Eq '\bon_(stage|requested|progress|build_progress)\b|with_progress_heartbeats' "$interface"; then
    echo "obsolete callback injection remains public in $interface" >&2
    exit 1
  fi
done

if grep -q 'run_with_store_heartbeats' "$root/lib/process_runner.ml"; then
  echo "process runner must not retain a store heartbeat callback path" >&2
  exit 1
fi
