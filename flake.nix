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
            defaultPackage = self.packages.${pkgs.system}.control-plane;
          }
        );

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = ocamlPackagesFor pkgs;

          legacyNixploy = pkgs.buildDotnetModule {
            pname = "nixploy";
            version = "0.1.0";
            src = ./.;

            projectFile = "nixploy.csproj";
            nugetDeps = ./deps.json;
            executables = [ "nixploy" ];

            dotnet-sdk = pkgs.dotnet-sdk_10;
          };

          ocamlNixploy = ocamlPackages.buildDunePackage {
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
              ++ [ pkgs.makeWrapper ];

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

          moonbitPolicy = pkgs.stdenvNoCC.mkDerivation {
            pname = "nixploy-deployment-policy";
            version = "0.1.20260803";
            src = ./policy;

            moonbitToolchain = pkgs.fetchurl {
              url = "https://cli.moonbitlang.com/binaries/latest/moonbit-linux-x86_64.tar.gz";
              hash = "sha256-xnrU4xMgpbDM44juxRpMk4S3+QLo0n50efJhJJGxO28=";
            };

            moonbitCore = pkgs.fetchurl {
              url = "https://cli.moonbitlang.com/cores/core-latest.tar.gz";
              hash = "sha256-o8pynyUXt8YXCiZFq6mq55FUs9cfEzAkcMmVMxE5gXQ=";
            };

            nativeBuildInputs = [
              pkgs.file
              pkgs.patchelf
              pkgs.gnutar
              pkgs.gzip
            ];

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR/home
              export MOON_HOME=$TMPDIR/moon
              mkdir -p "$HOME" "$MOON_HOME/lib"
              tar -xzf "$moonbitToolchain" -C "$MOON_HOME"
              tar -xzf "$moonbitCore" -C "$MOON_HOME/lib"
              chmod -R u+rwX "$MOON_HOME"
              find "$MOON_HOME/bin" -type f -print0 | while IFS= read -r -d "" executable; do
                if file "$executable" | grep -q ELF; then
                  chmod +x "$executable"
                  if patchelf --print-interpreter "$executable" >/dev/null 2>&1; then
                    patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} "$executable"
                  fi
                fi
              done
              export PATH="$MOON_HOME/bin:$PATH"
              moon -C "$MOON_HOME/lib/core" bundle --warn-list -a --all
              moon build --target wasm --release --frozen --deny-warn
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm444 _build/wasm/release/build/cmd/main/main.wasm \
                $out/lib/nixploy/policy/deployment-policy.wasm
              runHook postInstall
            '';
          };

          control-plane = (beamPackages pkgs).mixRelease {
            pname = "nixploy-control-plane";
            version = "0.1.0";
            src = ./.;
            elixir = (beamPackages pkgs).elixir_1_20;

            mixFodDeps = (beamPackages pkgs).fetchMixDeps {
              pname = "nixploy-control-plane-mix-deps";
              version = "0.1.0";
              src = ./.;
              hash = "sha256-h/RiXWF6Zfa0G9NvrPPjU/nkjqcbh++YtVVVkZ7LsMg=";
            };

            env = commonEnv pkgs;

            nativeBuildInputs = [
              pkgs.makeWrapper
              pkgs.tailwindcss_4
              pkgs.esbuild
              pkgs.gcc
              pkgs.gnumake
            ];

            postBuild = ''
              mix do deps.loadpaths --no-deps-check, tailwind nixploy --minify + esbuild nixploy --minify + phx.digest
            '';

            postInstall = ''
              wrapProgram $out/bin/nixploy \
                --set-default NIXPLOY_LEGACY_EXECUTABLE ${legacyNixploy}/bin/nixploy \
                --set-default NIXPLOY_REMOTE_CLI_EXECUTABLE ${legacyNixploy}/bin/nixploy \
                --prefix PATH : ${
                  lib.makeBinPath [
                    legacyNixploy
                    pkgs.git
                    pkgs.nix
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.util-linux
                    pkgs.openssh
                    pkgs.curl
                    pkgs.podman
                    pkgs.sops
                    pkgs.ssh-to-age
                    pkgs.wasmtime
                  ]
                } \
                --set-default NIXPLOY_POLICY_COMPONENT ${moonbitPolicy}/lib/nixploy/policy/deployment-policy.wasm \
                --set-default NIXPLOY_WASMTIME_EXECUTABLE ${pkgs.wasmtime}/bin/wasmtime
            '';
          };
        in
        {
          inherit control-plane moonbitPolicy;
          nixploy = ocamlNixploy;
          ocaml-nixploy = ocamlNixploy;
          legacy-nixploy = legacyNixploy;
          default = ocamlNixploy;
          fetch-deps = legacyNixploy.fetch-deps;
        }
      );

      checks = forAllSystems (system: {
        control-plane = self.packages.${system}.control-plane;
        nixploy = self.packages.${system}.nixploy;
        ocaml-nixploy = self.packages.${system}.ocaml-nixploy;
        nixos-module =
          (lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                system.stateVersion = "26.05";
                boot.loader.grub.devices = [ "/dev/vda" ];
                fileSystems."/" = {
                  device = "/dev/vda";
                  fsType = "ext4";
                };
                services.nixploy-control-plane = {
                  enable = true;
                  environmentFile = "/run/keys/nixploy.env";
                };
              }
            ];
          }).config.system.build.toplevel;
        nixos-module-split =
          let
            split = lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.devices = [ "/dev/vda" ];
                  fileSystems."/" = {
                    device = "/dev/vda";
                    fsType = "ext4";
                  };
                  services.nixploy-control-plane = {
                    enable = true;
                    splitRoles = true;
                    workerSopsAgeKeyFile = "/run/keys/nixploy.age";
                    workerSopsAgeSshKeyFile = "/etc/ssh/ssh_host_ed25519_key";
                    workerSshIdentityFile = "/run/keys/nixploy-ssh";
                    workerSshKnownHostsFile = "/run/keys/nixploy-known-hosts";
                    backup.enable = true;
                    environmentFile = "/run/keys/nixploy.env";
                  };
                }
              ];
            };
            web = split.config.systemd.services.nixploy-control-plane.serviceConfig;
            workerService = split.config.systemd.services.nixploy-control-plane-worker;
            worker = workerService.serviceConfig;
          in
          assert
            workerService.environment.NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE
            == "/run/credentials/nixploy-control-plane-worker.service/nixploy-sops-age-ssh-key";
          assert !(workerService.environment ? SOPS_AGE_SSH_PRIVATE_KEY_FILE);
          assert web.RuntimeDirectory == "nixploy-web";
          assert worker.RuntimeDirectory == "nixploy-worker";
          assert web.RuntimeDirectoryMode == "0700";
          assert worker.RuntimeDirectoryMode == "0700";
          assert web.User == "nixploy-web";
          assert worker.User == "nixploy-worker";
          assert split.config.virtualisation.podman.enable == false;
          split.config.system.build.toplevel;
        nixos-module-staged =
          let
            staged = lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  system.stateVersion = "26.05";
                  boot.loader.grub.devices = [ "/dev/vda" ];
                  fileSystems."/" = {
                    device = "/dev/vda";
                    fsType = "ext4";
                  };
                  services.nixploy-control-plane = {
                    enable = true;
                    splitRoles = true;
                    workerEnabled = false;
                    workerSopsAgeKeyFile = "/run/keys/nixploy.age";
                    workerSopsAgeSshKeyFile = "/etc/ssh/ssh_host_ed25519_key";
                    workerSshIdentityFile = "/run/keys/nixploy-ssh";
                    workerSshKnownHostsFile = "/run/keys/nixploy-known-hosts";
                    environmentFile = "/run/keys/nixploy.env";
                  };
                }
              ];
            };
          in
          assert staged.config.systemd.services ? nixploy-control-plane-worker;
          assert staged.config.systemd.services.nixploy-control-plane-worker.wantedBy == [ ];
          staged.config.system.build.toplevel;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          ocamlPackages = ocamlPackagesFor pkgs;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.ocaml-nixploy ];

            packages = [
              (beamPackages pkgs).elixir_1_20
              pkgs.bash
              pkgs.coreutils
              pkgs.util-linux
              pkgs.postgresql_17
              pkgs.tailwindcss_4
              pkgs.esbuild
              pkgs.inotify-tools
              pkgs.watchman
              pkgs.dotnet-sdk_10
              pkgs.roslyn-ls
              pkgs.sops
              pkgs.ssh-to-age
              pkgs.just
              pkgs.podman
              pkgs.jq
              ocamlPackages.dune_3
              ocamlPackages.ocaml
              ocamlPackages.ocaml-lsp
              ocamlPackages.ocamlformat
              ocamlPackages.utop
            ];

            env = commonEnv pkgs;
          };
        }
      );
    };
}
