#!/usr/bin/env bash
set -euo pipefail

executable=$1
root_help=$($executable --help 2>&1)
prune_help=$($executable prune --help 2>&1)
history_help=$($executable history --help 2>&1)
deploy_help=$($executable deploy --help 2>&1)
control_plane_help=$($executable control-plane capabilities --help 2>&1)

for expected in "control-plane" "prune" "deploy" "history" "status"; do
  grep -F -- "$expected" <<<"$root_help" >/dev/null
done
for expected in "--target TARGET" "-t" "--directory DIRECTORY" "-C" "--state-db PATH"; do
  grep -F -- "$expected" <<<"$prune_help" >/dev/null
  grep -F -- "$expected" <<<"$history_help" >/dev/null
  grep -F -- "$expected" <<<"$deploy_help" >/dev/null
done
grep -F -- "--limit COUNT" <<<"$history_help" >/dev/null
grep -F -- "--uri URI" <<<"$control_plane_help" >/dev/null
grep -F -- "--require CAPABILITY" <<<"$control_plane_help" >/dev/null

set +e
missing_output=$($executable prune 2>&1)
missing_status=$?
set -e
[ "$missing_status" -ne 0 ]
grep -F -- "missing required flag: --target" <<<"$missing_output" >/dev/null

set +e
invalid_target_output=$($executable deploy --target "" --directory /tmp --state-db /tmp/nixploy-contract.sqlite 2>&1)
invalid_target_status=$?
set -e
[ "$invalid_target_status" -eq 2 ]
grep -F -- "target name must not be empty" <<<"$invalid_target_output" >/dev/null
if grep -F -- "protected mutation authority\|unknown flag" <<<"$invalid_target_output" >/dev/null; then
  exit 1
fi

# A direct deployment must report pre-admission source/evaluation work and
# SIGINT must terminate its child process without creating a deployment row.
root=$(mktemp -d)
cli_pid=""
child_pid=""
cleanup() {
  if [[ -n "$cli_pid" ]] && kill -0 "$cli_pid" 2>/dev/null; then
    kill -TERM "$cli_pid" 2>/dev/null || true
    wait "$cli_pid" 2>/dev/null || true
  fi
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  rm -rf -- "$root"
}
trap cleanup EXIT

repo="$root/repository"
bin="$root/bin"
runtime="$root/runtime"
marker="$root/eval-started"
child_marker="$root/eval-pid"
state_db="$root/state.sqlite"
mkdir -p "$repo" "$bin" "$runtime"
git init -b main "$repo" >/dev/null
git -C "$repo" config user.email test@nixploy.invalid
git -C "$repo" config user.name Nixploy
printf '{ outputs = _: {}; }\n' > "$repo/flake.nix"
printf '{}\n' > "$repo/flake.lock"
git -C "$repo" add flake.nix flake.lock
git -C "$repo" commit -m fixture >/dev/null
cat > "$bin/nix" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${NIXPLOY_TEST_CONFIGURATION_MARKER:-}" ]; then
  touch "$NIXPLOY_TEST_CONFIGURATION_MARKER"
fi
if [ "${NIXPLOY_TEST_CONFIG_ONLY:-}" = 1 ] || {
  [ -n "${NIXPLOY_TEST_DIRECT_CONFIG_ONCE:-}" ] &&
    [ ! -e "$NIXPLOY_TEST_DIRECT_CONFIG_ONCE" ];
}; then
  if [ -n "${NIXPLOY_TEST_DIRECT_CONFIG_ONCE:-}" ]; then
    touch "$NIXPLOY_TEST_DIRECT_CONFIG_ONCE"
  fi
  if [ "${NIXPLOY_TEST_MANAGED:-}" = 1 ]; then
    printf '%s\n' '{"__schema":"v0.4","project":"fixture","controlPlane":{"authorityAlias":"netcup","managedApplicationKey":"fixture-production"},"targets":{"production":{"image":"fixture-image","ip":"target.example.invalid"}}}'
  else
    printf '%s\n' '{"__schema":"v0.4","project":"fixture","targets":{"staging":{"image":"fixture-image","ip":"target.example.invalid","nonProduction":{"coordinationScope":"fixture-staging"}}}}'
  fi
  exit 0
fi
if [ -n "${NIXPLOY_TEST_EVAL_STARTED:-}" ]; then
  touch "$NIXPLOY_TEST_EVAL_STARTED"
fi
printf '%s\n' "$$" > "$NIXPLOY_TEST_CHILD_PID"
touch "$NIXPLOY_TEST_EVAL_STARTED"
trap 'exit 130' INT TERM
while :; do sleep 1; done
EOF
chmod +x "$bin/nix"

TMPDIR="$runtime" NIXPLOY_TEST_CHILD_PID="$child_marker" \
  NIXPLOY_TEST_DIRECT_CONFIG_ONCE="$root/direct-config-loaded" \
  NIXPLOY_TEST_EVAL_STARTED="$marker" PATH="$bin:$PATH" \
  "$executable" deploy --target staging --directory "$repo" \
  --state-db "$state_db" >"$root/stdout" 2>"$root/stderr" &
cli_pid=$!
for _ in $(seq 1 100); do
  [[ -e "$marker" ]] && break
  sleep 0.05
done
[[ -e "$marker" ]]
child_pid=$(cat "$child_marker")
grep -F -- "Preparing local source snapshot and evaluating target staging..." \
  "$root/stderr" >/dev/null
kill -INT "$cli_pid"
for _ in $(seq 1 100); do
  ! kill -0 "$cli_pid" 2>/dev/null && break
  sleep 0.05
done
if kill -0 "$cli_pid" 2>/dev/null; then
  echo "direct CLI did not exit after SIGINT" >&2
  exit 1
fi
set +e
wait "$cli_pid"
cli_status=$?
set -e
[[ "$cli_status" -ne 0 ]]
! kill -0 "$child_pid" 2>/dev/null
! find "$runtime" -maxdepth 1 -type d -name 'nixploy-local-*' | grep -q .
NIXPLOY_TEST_CONFIG_ONLY=1 PATH="$bin:$PATH" \
  "$executable" history --target staging --directory "$repo" \
  --state-db "$state_db" | grep -Fx 'No deployment history found.' >/dev/null

# A flake-declared managed control plane selects remote transport by default.
# The configuration evaluation needed to discover the protected alias is allowed,
# but no local state, source snapshot, or deployment work may start.
managed_default_marker="$root/managed-default-nix-started"
managed_default_state="$root/managed-default-state.sqlite"
set +e
managed_default_output=$(NIXPLOY_TEST_CONFIG_ONLY=1 NIXPLOY_TEST_MANAGED=1 \
  NIXPLOY_TEST_CONFIGURATION_MARKER="$managed_default_marker" PATH="$bin:$PATH" \
  "$executable" deploy --target production --directory "$repo" \
  --state-db "$managed_default_state" 2>&1)
managed_default_status=$?
set -e
[ "$managed_default_status" -ne 0 ]
grep -F -- 'NIXPLOY_UNTRUSTED_CONTROL_PLANE' <<<"$managed_default_output" >/dev/null
! grep -F -- 'Preparing local source snapshot' <<<"$managed_default_output" >/dev/null
[ -e "$managed_default_marker" ]
[ ! -e "$managed_default_state" ]

# --direct remains a local-only escape hatch and therefore rejects a flake that
# declares managed control-plane identity before opening local state.
managed_direct_marker="$root/managed-direct-nix-started"
managed_direct_state="$root/managed-direct-state.sqlite"
set +e
managed_direct_output=$(NIXPLOY_TEST_CONFIG_ONLY=1 NIXPLOY_TEST_MANAGED=1 \
  NIXPLOY_TEST_CONFIGURATION_MARKER="$managed_direct_marker" PATH="$bin:$PATH" \
  "$executable" deploy --direct --target production --directory "$repo" \
  --state-db "$managed_direct_state" 2>&1)
managed_direct_status=$?
set -e
[ "$managed_direct_status" -ne 0 ]
grep -F -- 'NIXPLOY_DIRECT_MANAGED_DECLARATION' <<<"$managed_direct_output" >/dev/null
[ -e "$managed_direct_marker" ]
[ ! -e "$managed_direct_state" ]

set +e
invalid_mode_output=$("$executable" deploy --direct --authority-alias netcup \
  --managed-application-key fixture-production --target staging 2>&1)
invalid_mode_status=$?
set -e
[ "$invalid_mode_status" -ne 0 ]
grep -F -- 'NIXPLOY_EXECUTION_MODE_INVALID' <<<"$invalid_mode_output" >/dev/null

# Managed commands resolve their protected authority before any caller-controlled
# Nix evaluation, local state access, deployment preparation, or signal setup.
# The missing protected record is therefore a fail-closed error with no nix trace.
for managed_command in status history deploy; do
  managed_marker="$root/$managed_command-nix-started"
  managed_state="$root/$managed_command-state.sqlite"
  set +e
  managed_output=$(NIXPLOY_TEST_CONFIG_ONLY=1 NIXPLOY_TEST_MANAGED=1 \
    NIXPLOY_TEST_EVAL_STARTED="$managed_marker" PATH="$bin:$PATH" \
    "$executable" "$managed_command" --target staging --directory "$repo" \
    --state-db "$managed_state" --authority-alias netcup \
    --managed-application-key fixture-production 2>&1)
  managed_status=$?
  set -e
  [ "$managed_status" -ne 0 ]
  grep -F -- 'NIXPLOY_UNTRUSTED_CONTROL_PLANE' <<<"$managed_output" >/dev/null
  [ ! -e "$managed_marker" ]
  [ ! -e "$managed_state" ]
done
