{
  description = "Example consumer flake for nixploy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixploy.url = "path:..";
  };

  outputs = { self, nixploy, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      nixploy = nixploy.lib.makeConfig {
        project = "example-app";

        targets = {
          prod = import ./example.nix;

          staging = {
            image = "docker";
            ip = "203.0.113.20";
            user = "deploy";
            port = 2222;
          };
        };
      };
    };
}
