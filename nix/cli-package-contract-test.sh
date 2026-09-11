#!/usr/bin/env bash
set -euo pipefail

# Inspect the installed product without evaluating an application or contacting a host.
package=${1:?usage: cli-package-contract-test.sh PACKAGE}
cli="$package/bin/nixploy"
test -x "$cli"

for removed in nixploy-web nixploy-target-lease-broker nixploy-target-lease-client; do
  if test -e "$package/bin/$removed"; then
    printf 'Unexpected service executable in CLI package: %s\n' "$removed" >&2
    exit 1
  fi
done

help=$("$cli" --help)
for command in deploy status logs history prune runbook run; do
  if ! grep -Eq "^[[:space:]]+$command[[:space:]]" <<<"$help"; then
    printf 'Missing CLI command: %s\n' "$command" >&2
    exit 1
  fi
done
if grep -q 'control-plane' <<<"$help"; then
  printf 'Obsolete control-plane command is still exposed\n' >&2
  exit 1
fi

for command in deploy status logs history prune runbook; do
  command_help=$("$cli" "$command" --help)
  grep -q -- '-target' <<<"$command_help"
  grep -q -- '-json' <<<"$command_help"
  if grep -Eq -- '(^|[[:space:]]|\[)--?(authority-alias|managed-application-key|direct)([[:space:]=]|\]|$)' <<<"$command_help"; then
    printf 'Obsolete execution mode flag exposed by %s\n' "$command" >&2
    exit 1
  fi
done
"$cli" prune --help | grep -q -- '-yes'
"$cli" run --help | grep -q -- '-target'
if "$cli" run --help | grep -Eq -- '(^|[[:space:]]|\[)--?(authority-alias|managed-application-key|direct)([[:space:]=]|\]|$)'; then
  printf 'Obsolete execution mode flag exposed by run\n' >&2
  exit 1
fi
"$cli" --version

printf 'CLI package contract passed\n'
