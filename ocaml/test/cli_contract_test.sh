#!/usr/bin/env bash
set -euo pipefail

executable=$1
root_help=$($executable --help 2>&1)
prune_help=$($executable prune --help 2>&1)
history_help=$($executable history --help 2>&1)

for expected in "prune" "deploy" "history" "status"; do
  grep -F -- "$expected" <<<"$root_help" >/dev/null
done
for expected in "--target TARGET" "-t" "--directory DIRECTORY" "-C" "--state-db PATH"; do
  grep -F -- "$expected" <<<"$prune_help" >/dev/null
  grep -F -- "$expected" <<<"$history_help" >/dev/null
done
grep -F -- "--limit COUNT" <<<"$history_help" >/dev/null

set +e
missing_output=$($executable prune 2>&1)
missing_status=$?
set -e
[ "$missing_status" -ne 0 ]
grep -F -- "missing required flag: --target" <<<"$missing_output" >/dev/null

set +e
parsed_output=$($executable prune --target "" --directory /tmp --state-db /tmp/nixploy-contract.sqlite 2>&1)
parsed_status=$?
set -e
[ "$parsed_status" -eq 2 ]
if grep -F -- "unknown flag" <<<"$parsed_output" >/dev/null; then
  exit 1
fi
