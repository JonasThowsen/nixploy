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
  scopeUsers = lib.concatMap (scope: map (user: { inherit (scope) scope; inherit user; }) scope.users) cfg.scopes;
  brokerArguments = lib.concatStringsSep " " (
    [
      "--socket ${lib.escapeShellArg socketPath}"
      "--state-directory ${lib.escapeShellArg "/var/lib/nixploy-target-lease"}"
      "--authority ${lib.escapeShellArg cfg.authority}"
      "--identity ${lib.escapeShellArg cfg.identity}"
    ]
    ++ (map (entry: "--scope-user ${lib.escapeShellArg "${entry.scope}:${entry.user}"}") scopeUsers)
  );
  startScript = pkgs.writeShellScript "nixploy-target-lease-start" ''
    set -eu
    exec ${lib.escapeShellArg "${cfg.package}/bin/nixploy-target-lease-broker"} ${brokerArguments}
  '';
  unique = values: lib.length values == lib.length (lib.unique values);
  configuredUser = user: builtins.hasAttr user config.users.users;
  explicitlyInSocketGroup = user:
    configuredUser user && builtins.elem cfg.group (config.users.users.${user}.extraGroups or [ ]);
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

    identity = lib.mkOption {
      type = uuidType;
      description = "Fixed broker build/config identity that READY binds exactly.";
    };

    scopes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          scope = lib.mkOption {
            type = uuidType;
            description = "Fixed coordination-domain UUID.";
          };
          users = lib.mkOption {
            type = lib.types.listOf lib.types.nonEmptyStr;
            description = "Existing host users allowed to acquire this exact scope.";
          };
        };
      });
      description = "Fixed per-scope peer ACLs; dynamic scopes and global grants are not supported.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-target-lease";
      description = "Dedicated unprivileged broker Unix identity.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nixploy-target-lease";
      description = "Socket group; peer users must be explicitly assigned to it by host configuration.";
    };

    manageUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create only the dedicated broker user and socket group.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length cfg.scopes > 0 && lib.length cfg.scopes <= 32;
        message = "services.nixploy.targetLease.scopes must contain 1 to 32 fixed ACLs";
      }
      {
        assertion = unique (map (entry: entry.scope) cfg.scopes);
        message = "services.nixploy.targetLease.scopes must not contain duplicate scopes";
      }
      {
        assertion = lib.all (entry: lib.length entry.users > 0 && lib.length entry.users <= 32 && unique entry.users) cfg.scopes;
        message = "each services.nixploy.targetLease scope must have 1 to 32 unique users";
      }
      {
        assertion = cfg.user != "root";
        message = "services.nixploy.targetLease.user must never be root";
      }
      {
        assertion = lib.all (entry: lib.all (user: user != cfg.user) entry.users) cfg.scopes;
        message = "services.nixploy.targetLease broker user cannot be an allowed peer";
      }
      {
        assertion = cfg.manageUser || (configuredUser cfg.user && builtins.hasAttr cfg.group config.users.groups);
        message = "services.nixploy.targetLease.manageUser = false requires externally defined broker user and group";
      }
      {
        assertion = lib.all (entry: lib.all configuredUser entry.users) cfg.scopes;
        message = "services.nixploy.targetLease scope users must already exist in host configuration";
      }
      {
        assertion = lib.all (entry: lib.all explicitlyInSocketGroup entry.users) cfg.scopes;
        message = "services.nixploy.targetLease scope users must be explicitly in the socket group";
      }
    ];

    users.groups = lib.mkIf cfg.manageUser {
      "${cfg.group}" = { };
    };

    users.users = lib.mkIf cfg.manageUser {
      "${cfg.user}" = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

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
