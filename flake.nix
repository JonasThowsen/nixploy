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
      ocamlPackagesFor =
        pkgs:
        let
          base = pkgs.ocaml-ng.ocamlPackages_5_2;
          ppxCssSedlexPatch = pkgs.fetchurl {
            url = "https://raw.githubusercontent.com/NixOS/nixpkgs/0ac41707663949ba068cd71462a0c31cfe6b6348/pkgs/development/ocaml-modules/janestreet/ppx_css_sedlex_3_5.patch";
            hash = "sha256-B4X6YfmhsUIsYDRv4pYAieNlUZ1GWOZrTUHrheZ8R44=";
          };
        in
        base.overrideScope (
          final: previous: {
            js_of_ocaml-compiler_5_9 = previous.js_of_ocaml-compiler.override {
              version = "5.9.1";
            };

            ppx_css = previous.ppx_css.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ppxCssSedlexPatch ];
              meta = old.meta // {
                broken = false;
              };
            });

            bonsai = previous.bonsai.overrideAttrs (old: {
              propagatedBuildInputs =
                builtins.filter (dependency: dependency != previous.cohttp-async) old.propagatedBuildInputs
                ++ [ final.cohttp-async_5_3 ];
            });
          }
        );
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

      nixosModules.default =
        { pkgs, ... }@args:
        import ./nix/nixos-module.nix (
          args
          // {
            defaultPackage = self.packages.${pkgs.system}.nixploy;
          }
        );

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

            nativeBuildInputs =
              with ocamlPackages;
              [
                js_of_ocaml-compiler_5_9
                ocaml-embed-file
              ]
              ++ [
                pkgs.git
                pkgs.makeWrapper
              ];

            propagatedBuildInputs = with ocamlPackages; [
              async
              async_kernel
              async_rpc_kernel
              async_rpc_websocket
              bonsai
              cohttp-async_5_3
              core
              core_unix
              digestif
              ocaml_sqlite3
              ppx_jane
              ppx_pattern_bind
              uri
              yojson
            ];

            doCheck = true;

            postFixup = ''
              for executable in $out/bin/nixploy $out/bin/nixploy-web; do
                wrapProgram "$executable" --prefix PATH : ${
                  lib.makeBinPath [
                    pkgs.coreutils
                    pkgs.curl
                    pkgs.git
                    pkgs.nix
                    pkgs.openssh
                    pkgs.podman
                    pkgs.sops
                    pkgs.ssh-to-age
                    pkgs.util-linux
                  ]
                }
              done
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
          ocamlPackages = ocamlPackagesFor pkgs;
          rpcProbe = ocamlPackages.buildDunePackage {
            pname = "nixploy-rpc-probe";
            version = "0.1.0-ocaml";
            src = ./ocaml;
            duneVersion = "3";
            nativeBuildInputs = with ocamlPackages; [
              ocaml-embed-file
              ppx_jane
            ];
            propagatedBuildInputs = with ocamlPackages; [
              async
              async_rpc_kernel
              async_rpc_websocket
              core
              core_unix
              ppx_jane
            ];
            doCheck = false;
            buildPhase = ''
              runHook preBuild
              dune build test/rpc_probe.exe
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 _build/default/test/rpc_probe.exe $out/bin/nixploy-rpc-probe
              runHook postInstall
            '';
          };
          evaluated = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                system.stateVersion = "26.05";
                services.nixploy = {
                  enable = true;
                  authMode = "tailscale";
                  operatorEmail = "operator@example.com";
                  port = 9090;
                  allowedOrigin = "https://nixploy.example.com";
                  environmentFile = "/run/keys/nixploy.env";
                  sshIdentityFile = "/run/keys/nixploy-ssh";
                  sshKnownHostsFile = "/run/keys/nixploy-known-hosts";
                  sopsAgeKeyFile = "/run/keys/nixploy.age";
                  sopsAgeSshKeyFile = "/run/keys/nixploy-sops-ssh";
                  applications.example = {
                    project = "example";
                    target = "production";
                    repository = "/srv/nixploy/example";
                    repositoryIdentity = "owner/example";
                    subdirectory = "deploy";
                  };
                };
              }
            ];
          };
          service = evaluated.config.systemd.services.nixploy;
          expectedApplications = builtins.toJSON {
            example = {
              project = "example";
              target = "production";
              repository = "/srv/nixploy/example";
              repositoryIdentity = "owner/example";
              subdirectory = "deploy";
            };
          };
          renamed = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                system.stateVersion = "26.05";
                services.nixploy-control-plane = {
                  enable = true;
                  authMode = "unrestricted";
                };
              }
            ];
          };
        in
        {
          nixploy = self.packages.${system}.nixploy;
          nixos-module =
            assert lib.hasSuffix "-nixploy-start" service.serviceConfig.ExecStart;
            assert service.serviceConfig.EnvironmentFile == [ "/run/keys/nixploy.env" ];
            assert service.serviceConfig.User == "nixploy";
            assert service.serviceConfig.Group == "nixploy";
            assert service.serviceConfig.StateDirectory == "nixploy";
            assert service.serviceConfig.WorkingDirectory == "/var/lib/nixploy";
            assert service.serviceConfig.TimeoutStopSec == 30;
            assert service.serviceConfig.ProtectSystem == "strict";
            assert builtins.elem "/srv/nixploy/example" service.serviceConfig.ReadOnlyPaths;
            assert service.environment.HOME == "/var/lib/nixploy";
            assert service.environment.NIXPLOY_AUTH_MODE == "tailscale";
            assert service.environment.NIXPLOY_OPERATOR_EMAIL == "operator@example.com";
            assert service.environment.NIXPLOY_ALLOWED_ORIGIN == "https://nixploy.example.com";
            assert service.environment.NIXPLOY_MANAGED_APPLICATIONS_JSON == expectedApplications;
            assert
              service.environment.NIXPLOY_SSH_IDENTITY_FILE == "/run/credentials/nixploy.service/ssh-identity";
            assert
              service.environment.NIXPLOY_SSH_KNOWN_HOSTS_FILE
              == "/run/credentials/nixploy.service/ssh-known-hosts";
            assert service.environment.SOPS_AGE_KEY_FILE == "/run/credentials/nixploy.service/sops-age-key";
            assert
              service.environment.NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE
              == "/run/credentials/nixploy.service/sops-age-ssh-key";
            assert !(builtins.hasAttr "nixploy-control-plane-worker" evaluated.config.systemd.services);
            assert !evaluated.config.services.postgresql.enable;
            assert renamed.config.services.nixploy.enable;
            pkgs.runCommand "nixploy-nixos-module-evaluation" { } "touch $out";
          nixos-vm-smoke = import ./nix/nixos-test.nix {
            inherit pkgs rpcProbe;
            nixployModule = self.nixosModules.default;
            nixployPackage = self.packages.${system}.nixploy;
          };
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

            packages = [
              pkgs.curl
              pkgs.git
              pkgs.jq
              pkgs.nix
              pkgs.openssh
              pkgs.podman
              pkgs.sops
              pkgs.ssh-to-age
              pkgs.util-linux
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
