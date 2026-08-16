{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    {
      packages.x86_64-linux.default = import ./package.nix {
        pkgs = import nixpkgs { system = "x86_64-linux"; };
      };
    };
}
