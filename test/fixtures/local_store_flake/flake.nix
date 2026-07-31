{
  description = "No-secret nixploy native blue-green tracer fixture";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      fixtureServer = pkgs.writeShellScriptBin "fixture-server" ''
        set -eu
        mkdir -p /tmp/nixploy-fixture-www
        printf 'healthy\n' > /tmp/nixploy-fixture-www/health
        exec ${pkgs.busybox}/bin/httpd -f -p "$PORT" -h /tmp/nixploy-fixture-www
      '';

      fixtureRoot = pkgs.buildEnv {
        name = "nixploy-native-fixture-root";
        paths = [ fixtureServer ];
        pathsToLink = [ "/bin" ];
      };
    in
    {
      fixtureImage = pkgs.dockerTools.buildLayeredImage {
        name = "nixploy-native-fixture";
        tag = "slice-1-2";
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
            environment.PORT = "{port}";
            preStart = [ ];
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
