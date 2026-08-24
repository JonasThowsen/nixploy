#!/usr/bin/env bash
set -euo pipefail

flake=$1
dune=$2

# Keep each Nix-built probe independently declared. A merge must not replace
# one executable stanza with another when both remain referenced by flake.nix.
while IFS= read -r executable; do
  if ! awk -v name="$executable" '
    /^\(executable/ { stanza = 1; next }
    stanza && $0 ~ "\\(name " name "\\)" { found = 1 }
    stanza && /^\)/ { stanza = 0 }
    END { exit !found }
  ' "$dune"; then
    echo "flake-referenced test executable lacks Dune stanza: $executable" >&2
    exit 1
  fi
done < <(grep -oE 'dune build test/[A-Za-z0-9_]+\.exe' "$flake" | sed -E 's#.*test/([^.]*)\.exe#\1#' | sort -u)

echo "all flake-referenced test executables have Dune stanzas"
