#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture="$root/nix/test-fixtures/mix-expo"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/nixploy-mix-expo.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

repository="$workspace/repository"
deployment="$repository/deploy"
mkdir -p "$deployment"
cp -R "$fixture"/. "$deployment"/
printf '"tracked sibling"\n' > "$repository/shared.nix"

git -C "$repository" init -q -b main
git -C "$repository" config user.email test@nixploy.invalid
git -C "$repository" config user.name "Nixploy regression test"
git -C "$repository" add deploy shared.nix
git -C "$repository" commit -qm "Add nested Expo application"

# Tracked edits are intentional CLI deployment input. Ignored dependency output
# must not enter the Git-aware flake snapshot or collide with mixRelease staging.
source_module="$deployment/lib/nixploy_expo_fixture.ex"
source_contents=$(<"$source_module")
printf '%s\n' "${source_contents/:committed/:dirty}" > "$source_module"
mkdir -p "$deployment/deps/expo/src"
printf 'ignored working-tree dependency\n' > "$deployment/deps/expo/src/ignored.ex"
git -C "$deployment" check-ignore -q deps/expo/src/ignored.ex

cd "$deployment"
legacy_log="$workspace/legacy-path-build.log"
if nix build --no-update-lock-file --no-write-lock-file path:.#default \
  --print-build-logs --no-link >"$legacy_log" 2>&1; then
  echo "legacy path source unexpectedly built the contaminated Expo fixture" >&2
  exit 1
fi
grep -Fq "ln: failed to create symbolic link 'deps/expo/src': File exists" \
  "$legacy_log"

# The production prepared source must keep the repository root available to a
# nested flake without exposing Git metadata through path: source semantics.
cat > "$deployment/flake.nix" <<'EOF'
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      sibling = import ../shared.nix;
    in
    assert sibling == "tracked sibling";
    {
      packages.x86_64-linux.default = import ./package.nix {
        pkgs = import nixpkgs { system = "x86_64-linux"; };
      };
    };
}
EOF

dune exec --root "$root/ocaml" test/source_build_probe.exe -- "$deployment"
