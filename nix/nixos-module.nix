{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  cfg = config.services.nixploy-control-plane;
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
      description = "Runtime role. The MVP profile supports one all-role service.";
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
    users.users.nixploy = {
      isSystemUser = true;
      group = "nixploy";
      home = "/var/lib/nixploy";
      createHome = true;
    };
    users.groups.nixploy = { };

    systemd.services.nixploy-control-plane = {
      description = "nixploy deployment control plane";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        NIXPLOY_ROLE = cfg.role;
        PORT = toString cfg.port;
        HOME = "/var/lib/nixploy";
        RELEASE_DISTRIBUTION = "none";
      };

      serviceConfig = {
        Type = "exec";
        User = "nixploy";
        Group = "nixploy";
        EnvironmentFile = cfg.environmentFile;
        ExecStart = "${cfg.package}/bin/nixploy start";
        ExecStartPre = lib.optional cfg.migrate "${cfg.package}/bin/nixploy eval Nixploy.Release.migrate\(\)";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "nixploy";
        WorkingDirectory = "/var/lib/nixploy";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/nixploy" ];
      };
    };
  };
}
