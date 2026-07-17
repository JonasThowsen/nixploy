{
  description = "Flake for nixploy application";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
      beamPackages = pkgs: pkgs.beam28Packages;
      commonEnv = pkgs: {
        MIX_ESBUILD_PATH = pkgs.lib.getExe pkgs.esbuild;
        MIX_TAILWIND_PATH = pkgs.lib.getExe pkgs.tailwindcss_4;
      };
      targetModule = import ./nix/target.nix;
      nixployConfigLib = import ./nix/config.nix {
        inherit lib targetModule;
      };
    in
    {
      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      lib = nixployConfigLib // {
        evalConfiguration =
          {
            modules ? [ ],
            specialArgs ? { },
          }:
          lib.evalModules {
            inherit specialArgs;
            modules = [ targetModule ] ++ modules;
          };

        evalDeployment =
          {
            deployment,
            specialArgs ? { },
          }:
          self.lib.evalConfiguration {
            inherit specialArgs;
            modules = [ deployment ];
          };
      };

      nixployModules.default = targetModule;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;

          nixploy = pkgs.buildDotnetModule {
            pname = "nixploy";
            version = "0.1.0";
            src = ./.;

            projectFile = "nixploy.csproj";
            nugetDeps = ./deps.json;
            executables = [ "nixploy" ];

            dotnet-sdk = pkgs.dotnet-sdk_10;
          };
        in
        {
          inherit nixploy;
          default = nixploy;
          fetch-deps = nixploy.fetch-deps;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              (beamPackages pkgs).elixir_1_20
              pkgs.postgresql_17
              pkgs.tailwindcss_4
              pkgs.esbuild
              pkgs.inotify-tools
              pkgs.watchman
              pkgs.dotnet-sdk_10
              pkgs.roslyn-ls
              pkgs.sops
              pkgs.podman
              pkgs.jq
            ];

            env = commonEnv pkgs;
          };
        }
      );
    };
}
