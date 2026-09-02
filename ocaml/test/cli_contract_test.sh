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
printf '%s\n' "$$" > "$NIXPLOY_TEST_CHILD_PID"
touch "$NIXPLOY_TEST_EVAL_STARTED"
trap 'exit 130' INT TERM
while :; do sleep 1; done
EOF
chmod +x "$bin/nix"

TMPDIR="$runtime" NIXPLOY_TEST_CHILD_PID="$child_marker" \
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
"$executable" history --target staging --directory "$repo" \
  --state-db "$state_db" | grep -Fx 'No deployment history found.' >/dev/null
