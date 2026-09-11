{
  description = "Daemonless CLI for deploying Nix-built applications";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" ];
      pkgsFor = system: import nixpkgs { inherit system; };
      ocamlPackagesFor = pkgs: pkgs.ocaml-ng.ocamlPackages_5_2;
      targetModule = import ./nix/target.nix;
      nixployConfigLib = import ./nix/config.nix { inherit lib targetModule; };
      runtimeTools = pkgs: [
        pkgs.coreutils
        pkgs.curl
        pkgs.git
        pkgs.nix
        pkgs.openssh
        pkgs.podman
        pkgs.sops
        pkgs.ssh-to-age
        pkgs.util-linux
      ];
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
          ocamlPackages = ocamlPackagesFor pkgs;
          nixployPackage = ocamlPackages.buildDunePackage {
            pname = "nixploy";
            version = "0.1.0-ocaml";
            src = ./ocaml;
            duneVersion = "3";
            nativeBuildInputs = [
              pkgs.git
              pkgs.makeWrapper
            ];
            propagatedBuildInputs = with ocamlPackages; [
              async
              core
              core_unix
              digestif
              ocaml_sqlite3
              ppx_jane
              uri
              yojson
            ];
            doCheck = true;
            preCheck = ''
              export TZDIR=${pkgs.tzdata}/share/zoneinfo
            '';
            postFixup = ''
              wrapProgram "$out/bin/nixploy" \
                --set NIXPLOY_PACKAGE_REVISION ${lib.escapeShellArg (self.rev or "unknown")} \
                --prefix PATH : ${lib.makeBinPath (runtimeTools pkgs)}
            '';
          };
        in
        {
          nixploy = nixployPackage;
          default = nixployPackage;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          configContract = import ./nix/config-test.nix { nixployLib = self.lib; };
        in
        {
          nixploy = self.packages.${system}.nixploy;
          config-contract =
            assert configContract;
            pkgs.runCommand "nixploy-config-contract" { } "touch $out";
          mix-expo-source = import ./nix/test-fixtures/mix-expo/package.nix { inherit pkgs; };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = ocamlPackagesFor pkgs;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.nixploy ];
            packages = runtimeTools pkgs ++ [
              pkgs.jq
              ocamlPackages.dune_3
              ocamlPackages.ocaml
              ocamlPackages.ocaml-lsp
              ocamlPackages.ocamlformat
              ocamlPackages.utop
            ];
          };
        }
      );
    };
}
