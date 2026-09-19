#!/usr/bin/env bash
set -euo pipefail
executable=$(realpath "$1")
root_help=$($executable --help 2>&1)
for command in deploy status history logs prune; do
  grep -F -- "$command" <<<"$root_help" >/dev/null
  help=$($executable "$command" --help 2>&1)
  for flag in '--target TARGET' '--directory DIRECTORY' '--state-db PATH' '--json'; do
    grep -F -- "$flag" <<<"$help" >/dev/null
  done
  for obsolete in '--direct' '--authority-alias' '--managed-application-key'; do
    ! grep -F -- "$obsolete" <<<"$help" >/dev/null
  done
done
! grep -F 'control-plane' <<<"$root_help" >/dev/null
$executable prune --help | grep -F -- '--yes' >/dev/null
for flag in '--dry-run' '--stale' '--keep COUNT' '--orphan RESOURCE_KEY'; do
  $executable prune --help | grep -F -- "$flag" >/dev/null
done
grep -F -- 'resources' <<<"$root_help" >/dev/null
resources_help=$($executable resources --help 2>&1)
for flag in '--target TARGET' '--directory DIRECTORY' '--json'; do
  grep -F -- "$flag" <<<"$resources_help" >/dev/null
done
! grep -F -- '--state-db' <<<"$resources_help" >/dev/null

root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir "$root/repository" "$root/bin"
repo="$root/repository"
git init -b main "$repo" >/dev/null
git -C "$repo" config user.email test@nixploy.invalid
git -C "$repo" config user.name Nixploy
printf '{ outputs = _: {}; }\n' > "$repo/flake.nix"
printf '{}\n' > "$repo/flake.lock"
git -C "$repo" add flake.nix flake.lock
git -C "$repo" commit -m fixture >/dev/null
cat > "$root/bin/nix" <<'EOF'
#!/bin/sh
set -eu
if [ "${OBSOLETE:-}" = 1 ]; then
  printf '%s\n' '{"__schema":"v0.4","project":"fixture","controlPlane":{"authorityAlias":"old","managedApplicationKey":"fixture"},"targets":{"test":{"image":"image","ip":"test.invalid"}}}'
else
  printf '%s\n' '{"__schema":"v0.4","project":"fixture","targets":{"test":{"image":"image","ip":"test.invalid"}}}'
fi
EOF
cat > "$root/bin/ssh" <<'EOF'
#!/bin/sh
case "$*" in
  *"'podman' 'ps'"*) printf '[]\n'; exit 0 ;;
  *"'true'"*) exit 0 ;;
esac
echo 'unexpected remote access' >&2
exit 99
EOF
cat > "$root/bin/podman" <<'EOF'
#!/bin/sh
case "$*" in
  'system connection list --format json'|*' ps --all '*) printf '[]\n' ;;
  'system connection add '*|*' info') exit 0 ;;
  *) echo 'unexpected podman command' >&2; exit 99 ;;
esac
EOF
chmod +x "$root/bin/nix" "$root/bin/ssh" "$root/bin/podman"
export PATH="$root/bin:$PATH"

set +e
$executable deploy --target '' --directory "$repo" >"$root/out" 2>"$root/err"
code=$?
set -e
test "$code" = 2
test ! -s "$root/out"
grep -F 'target name must not be empty' "$root/err" >/dev/null

set +e
$executable prune -t test -C "$repo" --state-db "$root/not-created.sqlite" >"$root/out" 2>"$root/err"
code=$?
set -e
test "$code" = 2
test ! -e "$root/not-created.sqlite"
test ! -s "$root/out"
grep -F 'NIXPLOY_PRUNE_CONFIRMATION_REQUIRED' "$root/err" >/dev/null

for arguments in '--keep 2 --yes' '--stale --keep 0 --dry-run' '--yes --dry-run' '--stale --orphan nixploy-x --yes'; do
  set +e
  # shellcheck disable=SC2086
  $executable prune -t test -C "$repo" --state-db "$root/not-created.sqlite" $arguments >"$root/out" 2>"$root/err"
  code=$?
  set -e
  test "$code" = 2
  test ! -e "$root/not-created.sqlite"
  test ! -s "$root/out"
done

$executable history -t test -C "$repo" --state-db "$root/state.sqlite" --json >"$root/out" 2>"$root/err"
test "$(cat "$root/out")" = '[]'
test ! -s "$root/err"

$executable status -t test -C "$repo" --state-db "$root/state.sqlite" --json >"$root/out" 2>"$root/err"
grep -F '"project":"fixture"' "$root/out" >/dev/null
grep -F '"target":"test"' "$root/out" >/dev/null
grep -F '"containers":[]' "$root/out" >/dev/null
test ! -s "$root/err"

set +e
OBSOLETE=1 $executable deploy -t test -C "$repo" --state-db "$root/state.sqlite" --json >"$root/out" 2>"$root/err"
code=$?
set -e
test "$code" = 1
test ! -s "$root/out"
grep -F 'controlPlane' "$root/err" >/dev/null
! grep -F 'unexpected remote access' "$root/err" >/dev/null
printf 'CLI contract: direct-only help, confirmation, JSON history, migration rejection, separated diagnostics passed\n'
