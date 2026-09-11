{
  description = "Example consumer flake for nixploy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixploy.url = "github:JonasThowsen/nixploy";
  };

  outputs =
    {
      nixploy,
      nixpkgs,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system}.docker = pkgs.dockerTools.buildLayeredImage {
        name = "nixploy-example";
        tag = "latest";
        contents = [ pkgs.busybox ];
        config = {
          Env = [ "PATH=/bin" ];
          Cmd = [
            "/bin/sh"
            "-ec"
            ''mkdir -p /tmp/www; printf healthy > /tmp/www/health; exec httpd -f -p "$PORT" -h /tmp/www''
          ];
        };
      };

      nixploy = nixploy.lib.makeConfig {
        project = "example-app";

        targets = {
          prod = import ./example.nix;

          staging = {
            image = "docker";
            ip = "203.0.113.20";
            user = "deploy";
            port = 2222;
            run = {
              network = "host";
              environment.PORT = "9000";
            };
            inherit (import ./example.nix) runbook;
          };
        };
      };
    };
}
