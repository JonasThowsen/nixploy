{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  uuidType = lib.types.strMatching "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$";
  cfg = config.services.nixploy.targetLease;
  socketPath = "/run/nixploy-target-lease/target-lease.sock";
  brokerArguments = lib.concatStringsSep " " (
    [
      "--socket ${lib.escapeShellArg socketPath}"
      "--state-directory ${lib.escapeShellArg "/var/lib/nixploy-target-lease"}"
      "--authority ${lib.escapeShellArg cfg.authority}"
    ]
    ++ (map (scope: "--scope ${lib.escapeShellArg scope}") cfg.scopes)
    ++ (map (user: "--allow-user ${lib.escapeShellArg user}") cfg.allowedUsers)
  );
  startScript = pkgs.writeShellScript "nixploy-target-lease-start" ''
    set -eu
    exec ${lib.escapeShellArg "${cfg.package}/bin/nixploy-target-lease-broker"} ${brokerArguments}
  '';
in
{
  options.services.nixploy.targetLease = {
    enable = lib.mkEnableOption "the fail-closed target coordination lease broker";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "packages.nixploy";
      description = "Package containing bin/nixploy-target-lease-broker and its narrow client.";
    };

    authority = lib.mkOption {
      type = uuidType;
      description = "Fixed broker authority UUID. Clients must match exactly.";
    };

    scopes = lib.mkOption {
      type = lib.types.listOf uuidType;
      description = "Fixed allowlisted coordination-domain UUIDs; dynamic scopes are not supported.";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      description = "Unix users allowed by SO_PEERCRED to request configured scopes.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-target-lease";
      description = "Dedicated unprivileged broker Unix identity.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-target-lease";
      description = "Socket group granted read/write access; its members cannot write the socket parent.";
    };

    manageUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the dedicated broker user and socket group.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length cfg.scopes > 0 && lib.length cfg.scopes <= 32;
        message = "services.nixploy.targetLease.scopes must contain 1 to 32 fixed UUIDs";
      }
      {
        assertion = lib.length cfg.allowedUsers > 0 && lib.length cfg.allowedUsers <= 32;
        message = "services.nixploy.targetLease.allowedUsers must contain 1 to 32 Unix users";
      }
      {
        assertion = !cfg.manageUser || cfg.user != "root";
        message = "services.nixploy.targetLease.manageUser cannot create root";
      }
      {
        assertion = cfg.manageUser || builtins.hasAttr cfg.user config.users.users;
        message = "services.nixploy.targetLease.manageUser = false requires the broker user to exist";
      }
      {
        assertion = lib.all (
          user: builtins.hasAttr user config.users.users || user == cfg.user
        ) cfg.allowedUsers;
        message = "services.nixploy.targetLease.allowedUsers must name NixOS users resolved at startup";
      }
    ];

    users.groups = lib.mkIf cfg.manageUser {
      "${cfg.group}" = { };
    };

    users.users = lib.mkMerge [
      (lib.mkIf cfg.manageUser {
        "${cfg.user}" = {
          isSystemUser = true;
          group = cfg.group;
        };
      })
      (lib.genAttrs cfg.allowedUsers (_user: {
        extraGroups = [ cfg.group ];
      }))
    ];

    systemd.services.nixploy-target-lease = {
      description = "nixploy fail-closed target lease broker";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = startScript;
        Restart = "on-failure";
        RestartSec = 1;
        RuntimeDirectory = "nixploy-target-lease";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "nixploy-target-lease";
        StateDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        ReadWritePaths = [ "/var/lib/nixploy-target-lease" ];
      };
    };
  };
}
