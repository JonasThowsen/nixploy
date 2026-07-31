{
  description = "Worker-only credential and pre-start tracer fixture";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      expectedTokenHash = "cb2514c4e8a24585cf90b3830a686facb39b85d87b63471e298ceb194c60d4b7";

      fixturePreStart = pkgs.writeShellScriptBin "fixture-pre-start" ''
        set -eu
        actual_hash="$(printf '%s' "$FIXTURE_TOKEN" | ${pkgs.busybox}/bin/sha256sum)"
        test "''${actual_hash%% *}" = "${expectedTokenHash}"
        printf 'worker credential verified before candidate startup\n'
      '';

      fixtureServer = pkgs.writeShellScriptBin "fixture-server" ''
        set -eu
        actual_hash="$(printf '%s' "$FIXTURE_TOKEN" | ${pkgs.busybox}/bin/sha256sum)"
        test "''${actual_hash%% *}" = "${expectedTokenHash}"
        ${pkgs.busybox}/bin/mkdir -p /tmp/nixploy-fixture-www
        printf 'healthy-worker-credential\n' > /tmp/nixploy-fixture-www/health
        exec ${pkgs.busybox}/bin/httpd -f -p "$PORT" -h /tmp/nixploy-fixture-www
      '';

      fixtureRoot = pkgs.buildEnv {
        name = "nixploy-native-credential-fixture-root";
        paths = [
          fixturePreStart
          fixtureServer
        ];
        pathsToLink = [ "/bin" ];
      };
    in
    {
      fixtureImage = pkgs.dockerTools.buildLayeredImage {
        name = "nixploy-native-fixture";
        tag = "slice-1-4-credential";
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
              FIXTURE_REVISION = "slice-1-4-credential";
            };
            preStart = [ [ "/bin/fixture-pre-start" ] ];
            network = "host";
            ports = [ ];
          };
          secrets = {
            fixture = ./secret.env;
          };
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
