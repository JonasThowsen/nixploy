{
  description = "No-secret nixploy native pre-start tracer fixture";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      fixtureServer = pkgs.writeShellScriptBin "fixture-server" ''
        set -eu
        ${pkgs.busybox}/bin/mkdir -p /tmp/nixploy-fixture-www
        printf 'healthy-slice-1-3\n' > /tmp/nixploy-fixture-www/health
        exec ${pkgs.busybox}/bin/httpd -f -p "$PORT" -h /tmp/nixploy-fixture-www
      '';

      fixturePreStart = pkgs.writeShellScriptBin "fixture-pre-start" ''
        set -eu
        test "''${1:-}" = "--prepare"
        printf 'fixture pre-start completed\n'
      '';

      fixtureRoot = pkgs.buildEnv {
        name = "nixploy-native-fixture-root";
        paths = [
          fixtureServer
          fixturePreStart
        ];
        pathsToLink = [ "/bin" ];
      };
    in
    {
      fixtureImage = pkgs.dockerTools.buildLayeredImage {
        name = "nixploy-native-fixture";
        tag = "slice-1-4";
        contents = [ fixtureRoot ];
        config.Cmd = [ "/bin/fixture-server" ];
      };

      nixploy = {
        __schema = "v0.2";
        project = "local-store-tracer";
        targets.production = {
          image = "fixtureImage";
          ip = "127.0.0.1";
          user = "nixploy";
          port = 22;
          identityFile = null;
          run = {
            command = null;
            environment = {
              PORT = "{port}";
              FIXTURE_REVISION = "slice-1-4";
            };
            preStart = [ [ "/bin/fixture-pre-start" "--prepare" ] ];
            network = "host";
            ports = [ ];
          };
          secrets = { };
          web = {
            domain = "fixture.nixploy.invalid";
            healthPath = "/health";
            slots = {
              blue = 18080;
              green = 18081;
            };
          };
        };
      };
    };
}
