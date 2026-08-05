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

          nixploy = pkgs.buildDotnetModule {
            pname = "nixploy";
            version = "0.1.0";
            src = ./.;

            projectFile = "nixploy.csproj";
            nugetDeps = ./deps.json;
            executables = [ "nixploy" ];

            dotnet-sdk = pkgs.dotnet-sdk_10;
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

            nativeBuildInputs = [ pkgs.file pkgs.patchelf pkgs.gnutar pkgs.gzip ];

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
                --set-default NIXPLOY_LEGACY_EXECUTABLE ${nixploy}/bin/nixploy \
                --set-default NIXPLOY_REMOTE_CLI_EXECUTABLE ${nixploy}/bin/nixploy \
                --prefix PATH : ${
                  lib.makeBinPath [
                    nixploy
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
          inherit nixploy control-plane moonbitPolicy;
          default = nixploy;
          fetch-deps = nixploy.fetch-deps;
        }
      );

      checks = forAllSystems (system: {
        control-plane = self.packages.${system}.control-plane;
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
                  splitRoles = true;
                  workerSopsAgeSshKeyFile = "/etc/ssh/ssh_host_ed25519_key";
                  environmentFile = "/run/keys/nixploy.env";
                };
              }
            ];
          }).config.system.build.toplevel;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
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
            ];

            env = commonEnv pkgs;
          };
        }
      );
    };
}
