{ pkgs }:

let
  beamPackages = pkgs.beam28Packages;
  mixNixDeps = pkgs.callPackages ./deps.nix { inherit beamPackages; };
in
beamPackages.mixRelease {
  pname = "nixploy-expo-fixture";
  version = "0.1.0";
  src = ./.;
  inherit mixNixDeps;
}
