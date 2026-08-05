{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  cfg = config.services.nixploy-control-plane;

  startControlPlane =
    role:
    pkgs.writeShellScript "nixploy-control-plane-${role}-start" ''
      export XDG_RUNTIME_DIR="/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)"
      # Export after EnvironmentFile is loaded so a legacy NIXPLOY_ROLE entry
      # cannot collapse split services back into the combined process.
      export NIXPLOY_ROLE="${role}"
      exec ${cfg.package}/bin/nixploy start
    '';

  roleUser = role: if cfg.splitRoles then (if role == "web" then cfg.webUser else cfg.workerUser) else cfg.user;
  roleGroup = role: if cfg.splitRoles then (if role == "web" then cfg.webGroup else cfg.workerGroup) else cfg.group;
  roleState = role: if cfg.splitRoles then "nixploy-${role}" else "nixploy";

  commonServiceConfig = role: {
    Type = "exec";
    User = roleUser role;
    Group = roleGroup role;
    EnvironmentFile = cfg.environmentFile;
    Restart = "on-failure";
    RestartSec = 5;
    StateDirectory = roleState role;
    WorkingDirectory = "/var/lib/${roleState role}";
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateMounts = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "/var/lib/${roleState role}" ];
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    LockPersonality = true;
    RestrictSUIDSGID = true;
  };

  backupScript = pkgs.writeShellApplication {
    name = "nixploy-backup";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.postgresql_18 ];
    text = ''
      set -euo pipefail
      umask 0077
      : "''${DATABASE_URL:?DATABASE_URL is required}"
      backup_dir=/var/lib/nixploy-backups
      timestamp=$(date -u +%Y%m%dT%H%M%SZ)
      partial="$backup_dir/nixploy-$timestamp.dump.partial"
      final="$backup_dir/nixploy-$timestamp.dump"
      manifest="$backup_dir/nixploy-$timestamp.manifest"
      checksum="$backup_dir/nixploy-$timestamp.sha256"
      cleanup() { rm -f "$partial"; }
      trap cleanup EXIT
      pg_dump --format=custom --no-owner --no-privileges --dbname="$DATABASE_URL" --file="$partial"
      test -s "$partial"
      pg_restore --list "$partial" > "$manifest.partial"
      test -s "$manifest.partial"
      mv "$partial" "$final"
      mv "$manifest.partial" "$manifest"
      sha256sum "$final" > "$checksum.partial"
      mv "$checksum.partial" "$checksum"
      find "$backup_dir" -type f -mtime +${toString cfg.backup.retentionDays} -delete
      trap - EXIT
    '';
  };

  credentialName = key: "git-${key}";

  publicApplications = lib.mapAttrs (
    _key: application: {
      inherit (application) project target repository repositoryIdentity subdirectory;
    }
  ) cfg.applications;

  workerCredentialPaths = lib.mapAttrs (
    key: application:
    if application.credentialFile == null then
      null
    else
      "/run/credentials/nixploy-control-plane-worker.service/${credentialName key}"
  ) cfg.applications;

  commonEnvironment = {
    NIXPLOY_AUTH_MODE = cfg.authMode;
    NIXPLOY_RUNTIME_MODE = cfg.runtimeMode;
    NIXPLOY_MANAGED_APPLICATIONS_JSON = builtins.toJSON publicApplications;
    RELEASE_DISTRIBUTION = "none";
  };
in
{
  options.services.nixploy-control-plane = {
    enable = lib.mkEnableOption "the nixploy deployment control plane";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Packaged nixploy Phoenix release.";
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "all"
        "web"
        "worker"
      ];
      default = "all";
      description = "Runtime role used when splitRoles is disabled.";
    };

    runtimeMode = lib.mkOption {
      type = lib.types.enum [ "remote_control_plane" "local_recovery" ];
      default = "remote_control_plane";
      description = "Production application effects use named remote targets; local recovery must be explicit.";
    };

    splitRoles = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run separate web and worker OS processes. Both retain the rootless
        Podman owner identity, but only the worker receives deployment
        credentials.
      '';
    };

    applications = lib.mkOption {
      default = { };
      description = ''
        Bounded NixOS-owned application source mappings. The source ref is
        always refs/heads/main; deployment intent remains in each project flake.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            project = lib.mkOption { type = lib.types.str; };
            target = lib.mkOption { type = lib.types.str; };
            repository = lib.mkOption {
              type = lib.types.str;
              description = "Worker Git clone location; never accepted from the UI.";
            };
            repositoryIdentity = lib.mkOption {
              type = lib.types.strMatching "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$";
              description = "Operator-safe owner/repository identity persisted with releases.";
            };
            subdirectory = lib.mkOption {
              type = lib.types.str;
              default = ".";
            };
            credentialFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Optional worker-only Git credential file.";
            };
          };
        }
      );
    };

    workerSopsAgeKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Worker-only age identity file consumed by the packaged remote CLI.";
    };

    workerSshIdentityFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Worker-only SSH identity for strict remote Podman and Caddy access.";
    };

    workerSshKnownHostsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Worker-only fixed known_hosts file; host-key relaxation is never enabled.";
    };

    workerSopsAgeSshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/ssh/ssh_host_ed25519_key";
      description = ''
        Runtime path to an SSH private key accepted by SOPS age recipients.
        With splitRoles enabled, systemd exposes it only to the worker through
        LoadCredential; the web process never receives the credential path.
      '';
    };

    releaseRegistrationTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Root-readable file containing the bearer token for bounded CI release
        registration. systemd exposes it only to the web service through
        LoadCredential.
      '';
    };

    releaseRegistrationProject = lib.mkOption {
      type = lib.types.str;
      default = "jomat";
      description = "Single project authorized by the CI release registration tracer.";
    };

    releaseRegistrationTarget = lib.mkOption {
      type = lib.types.str;
      default = "production";
      description = "Single target authorized by the CI release registration tracer.";
    };

    releaseRegistrationRepository = lib.mkOption {
      type = lib.types.str;
      default = "JonasThowsen/jomat";
      description = "Single source repository authorized by the CI release registration tracer.";
    };

    authMode = lib.mkOption {
      type = lib.types.enum [
        "tailscale"
        "password"
      ];
      default = "tailscale";
      description = ''
        Operator authentication boundary. Packaged self-hosted services default
        to trusted Tailscale Serve identity headers; password mode is intended
        for local development and explicit recovery workflows.
      '';
    };

    webUser = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-web";
      description = "Credential-free web process identity when splitRoles is enabled.";
    };

    webGroup = lib.mkOption {
      type = lib.types.str;
      default = cfg.webUser;
    };

    workerUser = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-worker";
      description = "Deployment worker identity when splitRoles is enabled.";
    };

    workerGroup = lib.mkOption {
      type = lib.types.str;
      default = cfg.workerUser;
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixploy";
      description = "User that runs nixploy and owns the visible rootless Podman workloads.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Primary group for the nixploy runtime user.";
    };

    manageUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the dedicated rootless Podman user and enable lingering for it.";
    };

    localPodman = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Podman and expose this user's local workloads to the control plane.";
    };

    backup = lib.mkOption {
      default = { };
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "verified PostgreSQL custom-format backups";
          schedule = lib.mkOption {
            type = lib.types.str;
            default = "daily";
          };
          retentionDays = lib.mkOption {
            type = lib.types.ints.between 1 3650;
            default = 30;
          };
        };
      };
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Root-readable environment file containing DATABASE_URL and RELEASE_COOKIE.
        Web roles also require SECRET_KEY_BASE and should set PHX_HOST.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "Internal HTTP port for web-capable roles.";
    };

    migrate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run all pending Ecto migrations before startup.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = lib.mkIf cfg.localPodman true;
    users.manageLingering = lib.mkIf (cfg.localPodman && cfg.manageUser) true;

    users.users = lib.mkIf cfg.manageUser (
      if cfg.splitRoles then
        {
          "${cfg.webUser}" = {
            isSystemUser = true;
            group = cfg.webGroup;
            home = "/var/lib/nixploy-web";
          };
          "${cfg.workerUser}" = {
            isSystemUser = true;
            group = cfg.workerGroup;
            home = "/var/lib/nixploy-worker";
          };
        }
      else
        {
          "${cfg.user}" = {
            isNormalUser = true;
            group = cfg.group;
            home = "/var/lib/nixploy";
            createHome = true;
            linger = cfg.localPodman;
          };
        }
    );

    users.groups = lib.mkIf cfg.manageUser (
      if cfg.splitRoles then
        {
          "${cfg.webGroup}" = { };
          "${cfg.workerGroup}" = { };
        }
      else
        { "${cfg.group}" = { }; }
    );

    assertions = [
      {
        assertion =
          !cfg.manageUser
          || (if cfg.splitRoles then cfg.webUser != "root" && cfg.workerUser != "root" else cfg.user != "root");
        message = "services.nixploy-control-plane.manageUser cannot create root";
      }
      {
        assertion = !cfg.splitRoles || cfg.webUser != cfg.workerUser;
        message = "splitRoles requires distinct webUser and workerUser identities";
      }
      {
        assertion =
          cfg.manageUser
          || (if cfg.splitRoles then
            builtins.hasAttr cfg.webUser config.users.users && builtins.hasAttr cfg.workerUser config.users.users
          else
            builtins.hasAttr cfg.user config.users.users);
        message = "manageUser = false requires every configured runtime identity to exist";
      }
      {
        assertion = !cfg.splitRoles || cfg.role == "all";
        message = "services.nixploy-control-plane.role must remain all when splitRoles is enabled";
      }
      {
        assertion =
          !cfg.splitRoles || cfg.workerSopsAgeKeyFile != null || cfg.workerSopsAgeSshKeyFile != null;
        message = "splitRoles requires a worker-only SOPS age or age-compatible SSH identity";
      }
      {
        assertion = !cfg.splitRoles || cfg.workerSshIdentityFile != null;
        message = "splitRoles requires workerSshIdentityFile for durable remote access";
      }
      {
        assertion = !cfg.splitRoles || cfg.workerSshKnownHostsFile != null;
        message = "splitRoles requires workerSshKnownHostsFile for strict host verification";
      }
      {
        assertion = !cfg.splitRoles || !cfg.localPodman;
        message = "split remote-control-plane roles cannot depend on local Podman";
      }
      {
        assertion =
          !cfg.splitRoles
          || lib.all (application: lib.hasPrefix "/var/lib/nixploy-worker/" application.repository)
            (lib.attrValues cfg.applications);
        message = "splitRoles requires managed repositories under worker-owned /var/lib/nixploy-worker";
      }
    ];

    systemd.services = {
      nixploy-control-plane = {
        description = "nixploy deployment control plane web service";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        environment =
          commonEnvironment
          // {
            PORT = toString cfg.port;
          }
          // lib.optionalAttrs (cfg.releaseRegistrationTokenFile != null) {
            NIXPLOY_RELEASE_REGISTRATION_TOKEN_FILE =
              "/run/credentials/nixploy-control-plane.service/release-registration-token";
            NIXPLOY_RELEASE_REGISTRATION_PROJECT = cfg.releaseRegistrationProject;
            NIXPLOY_RELEASE_REGISTRATION_TARGET = cfg.releaseRegistrationTarget;
            NIXPLOY_RELEASE_REGISTRATION_REPOSITORY = cfg.releaseRegistrationRepository;
          };

        serviceConfig = commonServiceConfig "web" // {
          ExecStart = startControlPlane (if cfg.splitRoles then "web" else cfg.role);
          ExecStartPre = lib.optional cfg.migrate "${cfg.package}/bin/nixploy eval Nixploy.Release.migrate\(\)";
          LoadCredential = lib.optional (cfg.releaseRegistrationTokenFile != null)
            "release-registration-token:${cfg.releaseRegistrationTokenFile}";
        };
      };
    }
    // lib.optionalAttrs cfg.splitRoles {
      nixploy-control-plane-worker = {
        description = "nixploy deployment control plane worker";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "nixploy-control-plane.service"
        ];
        wants = [ "network-online.target" ];
        requires = [ "nixploy-control-plane.service" ];

        environment =
          commonEnvironment
          // {
            NIXPLOY_MANAGED_APPLICATION_CREDENTIALS_JSON = builtins.toJSON workerCredentialPaths;
            NIXPLOY_SSH_IDENTITY_FILE = "/run/credentials/nixploy-control-plane-worker.service/nixploy-ssh-identity";
            NIXPLOY_SSH_KNOWN_HOSTS_FILE = "/run/credentials/nixploy-control-plane-worker.service/nixploy-ssh-known-hosts";
          }
          // lib.optionalAttrs (cfg.workerSopsAgeKeyFile != null) {
            SOPS_AGE_KEY_FILE = "/run/credentials/nixploy-control-plane-worker.service/nixploy-sops-age-key";
          }
          // lib.optionalAttrs (cfg.workerSopsAgeSshKeyFile != null) {
            SOPS_AGE_SSH_PRIVATE_KEY_FILE =
              "/run/credentials/nixploy-control-plane-worker.service/nixploy-sops-age-ssh-key";
          };

        serviceConfig = commonServiceConfig "worker" // {
          ExecStart = startControlPlane "worker";
          LoadCredential =
            [
              "nixploy-ssh-identity:${cfg.workerSshIdentityFile}"
              "nixploy-ssh-known-hosts:${cfg.workerSshKnownHostsFile}"
            ]
            ++ lib.optional (cfg.workerSopsAgeKeyFile != null)
              "nixploy-sops-age-key:${cfg.workerSopsAgeKeyFile}"
            ++ lib.optional (cfg.workerSopsAgeSshKeyFile != null)
              "nixploy-sops-age-ssh-key:${cfg.workerSopsAgeSshKeyFile}"
            ++ lib.mapAttrsToList (
              key: application: "${credentialName key}:${application.credentialFile}"
            ) (lib.filterAttrs (_key: application: application.credentialFile != null) cfg.applications);
        };
      };
    }
    // lib.optionalAttrs cfg.backup.enable {
      nixploy-backup = {
        description = "Verified nixploy PostgreSQL backup";
        after = [ "postgresql.service" ];
        environment = { HOME = "/var/lib/nixploy-backups"; };
        serviceConfig = {
          Type = "oneshot";
          User = if cfg.splitRoles then cfg.workerUser else cfg.user;
          Group = if cfg.splitRoles then cfg.workerGroup else cfg.group;
          EnvironmentFile = cfg.environmentFile;
          StateDirectory = "nixploy-backups";
          WorkingDirectory = "/var/lib/nixploy-backups";
          UMask = "0077";
          PrivateTmp = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ "/var/lib/nixploy-backups" ];
          ExecStart = lib.getExe backupScript;
        };
      };
    };

    systemd.timers = lib.optionalAttrs cfg.backup.enable {
      nixploy-backup = {
        description = "Schedule verified nixploy PostgreSQL backups";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
          Unit = "nixploy-backup.service";
        };
      };
    };
  };
}
