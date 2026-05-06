{ lib, ... }:

with lib;

{
  options = {
    image = mkOption {
      type = types.str;
      example = "docker";
      description = "Flake output to build for this target's OCI image.";
    };

    ip = mkOption {
      type = types.str;
      example = "203.0.113.10";
      description = "IP address of the deployment target.";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "SSH user used for deployment.";
    };

    port = mkOption {
      type = types.port;
      default = 22;
      description = "SSH port used for deployment.";
    };

    identityFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "~/.ssh/id_ed25519";
      description = ''
        SSH private key path used when creating the local Podman connection.

        This is a string, not a Nix path, to avoid copying private keys into
        the Nix store. Passphrases should be handled by ssh-agent.
      '';
    };

    run = mkOption {
      default = { };
      description = "Container runtime configuration for this target.";
      type = types.submodule {
        options = {
          command = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            example = [ "/app/bin/server" ];
            description = ''
              Optional command for the long-running application container.

              When omitted, nixploy uses the image's default CMD/ENTRYPOINT.
            '';
          };

          environment = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = {
              ASPNETCORE_URLS = "http://0.0.0.0:{port}";
              PORT = "{port}";
            };
            description = ''
              Environment variables passed to pre-start and application
              containers. The placeholder {port} is replaced with the selected
              web slot port for blue/green deployments.
            '';
          };

          preStart = mkOption {
            type = types.listOf (types.listOf types.str);
            default = [ ];
            example = literalExpression ''
              [
                [ "/app/efbundle" ]
                [ "/app/bin/migrate" ]
              ]
            '';
            description = ''
              Commands to run in temporary containers before the long-running
              application container starts.

              Each command runs from the same loaded image and receives the
              same Podman env secrets as the application container. This is the
              container equivalent of systemd ExecStartPre and is intended for
              migrations or other release tasks.
            '';
          };

          network = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "host";
            description = ''
              Optional Podman network mode passed to podman run with --network.

              Use "host" when the container should share the host network,
              for example to reach PostgreSQL on 127.0.0.1.
            '';
          };

          ports = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "127.0.0.1:8080:8080" ];
            description = ''
              Port mappings passed to podman run with -p.

              Usually leave this empty when run.network = "host".
            '';
          };
        };
      };
    };

    web = mkOption {
      default = null;
      description = "HTTP routing and blue/green deployment configuration.";
      type = types.nullOr (types.submodule {
        options = {
          domain = mkOption {
            type = types.str;
            example = "app.example.com";
            description = "Public domain Caddy should route to this target.";
          };

          healthPath = mkOption {
            type = types.str;
            default = "/health";
            example = "/health";
            description = "HTTP path used to health-check a new slot before switching traffic.";
          };

          slots = mkOption {
            type = types.submodule {
              options = {
                blue = mkOption {
                  type = types.port;
                  default = 8080;
                  description = "Localhost port for the blue deployment slot.";
                };

                green = mkOption {
                  type = types.port;
                  default = 8081;
                  description = "Localhost port for the green deployment slot.";
                };
              };
            };
            default = { };
            description = "Blue/green localhost ports used behind Caddy.";
          };
        };
      });
    };

    secrets = mkOption {
      default = { };
      example = literalExpression ''
        {
          app = ./secrets/prod.env;
          database = ./secrets/database.env;
        }
      '';
      description = ''
        Local SOPS-encrypted dotenv files whose variables should be installed
        as remote Podman secrets and exposed as container environment variables.

        Each attribute value is a SOPS file. The attribute name is only a local
        label used to make the configuration readable. At deploy time nixploy
        decrypts each file locally, creates one Podman secret per dotenv
        variable, and injects each secret with type=env when starting the
        container.

        Secret values are intentionally not represented in the evaluated Nix
        configuration. Only local encrypted file paths are tracked.
      '';
      type = types.attrsOf types.path;
    };
  };
}
