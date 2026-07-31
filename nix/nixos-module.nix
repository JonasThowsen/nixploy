{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  cfg = config.services.nixploy-control-plane;

  startControlPlane = pkgs.writeShellScript "nixploy-control-plane-start" ''
    export XDG_RUNTIME_DIR="/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)"
    exec ${cfg.package}/bin/nixploy start
  '';

  commonServiceConfig = {
    Type = "exec";
    User = cfg.user;
    Group = cfg.group;
    EnvironmentFile = cfg.environmentFile;
    ExecStart = startControlPlane;
    Restart = "on-failure";
    RestartSec = 5;
    StateDirectory = "nixploy";
    WorkingDirectory = "/var/lib/nixploy";
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    # Rootless Podman needs the runtime user's home and /run/user state.
    ProtectHome = false;
    ReadWritePaths = [ "/var/lib/nixploy" ];
  };

  commonEnvironment = {
    NIXPLOY_AUTH_MODE = cfg.authMode;
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

    splitRoles = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run separate web and worker OS processes. Both retain the rootless
        Podman owner identity, but only the worker receives deployment
        credentials.
      '';
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
      default = true;
      description = "Enable Podman and expose this user's local workloads to the control plane.";
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

    users.users = lib.mkIf cfg.manageUser {
      "${cfg.user}" = {
        isNormalUser = true;
        group = cfg.group;
        home = "/var/lib/nixploy";
        createHome = true;
        linger = cfg.localPodman;
      };
    };

    users.groups = lib.mkIf cfg.manageUser { "${cfg.group}" = { }; };

    assertions = [
      {
        assertion = !cfg.manageUser || cfg.user != "root";
        message = "services.nixploy-control-plane.manageUser cannot create root";
      }
      {
        assertion = cfg.manageUser || builtins.hasAttr cfg.user config.users.users;
        message = "services.nixploy-control-plane.manageUser = false requires users.users.${cfg.user}";
      }
      {
        assertion = !cfg.splitRoles || cfg.role == "all";
        message = "services.nixploy-control-plane.role must remain all when splitRoles is enabled";
      }
      {
        assertion = !cfg.splitRoles || cfg.workerSopsAgeSshKeyFile != null;
        message = "splitRoles requires workerSopsAgeSshKeyFile for worker-only credential access";
      }
    ];

    systemd.services = {
      nixploy-control-plane = {
        description = "nixploy deployment control plane web service";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        environment = commonEnvironment // {
          NIXPLOY_ROLE = if cfg.splitRoles then "web" else cfg.role;
          PORT = toString cfg.port;
        };

        serviceConfig = commonServiceConfig // {
          ExecStartPre = lib.optional cfg.migrate "${cfg.package}/bin/nixploy eval Nixploy.Release.migrate\(\)";
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

        environment = commonEnvironment // {
          NIXPLOY_ROLE = "worker";
        };

        serviceConfig = commonServiceConfig // {
          LoadCredential = [
            "nixploy-sops-age-ssh-key:${cfg.workerSopsAgeSshKeyFile}"
          ];
        };
      };
    };
  };
}
