{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  cfg = config.services.nixploy;

  publicApplications = lib.mapAttrs (_key: application: {
    inherit (application)
      project
      target
      repository
      repositoryIdentity
      subdirectory
      ;
  }) cfg.applications;

  credentialDefinitions = [
    {
      source = cfg.sshIdentityFile;
      name = "ssh-identity";
      environment = "NIXPLOY_SSH_IDENTITY_FILE";
    }
    {
      source = cfg.sshKnownHostsFile;
      name = "ssh-known-hosts";
      environment = "NIXPLOY_SSH_KNOWN_HOSTS_FILE";
    }
    {
      source = cfg.sopsAgeKeyFile;
      name = "sops-age-key";
      environment = "SOPS_AGE_KEY_FILE";
    }
    {
      source = cfg.sopsAgeSshKeyFile;
      name = "sops-age-ssh-key";
      environment = "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE";
    }
  ];

  configuredCredentials = lib.filter (credential: credential.source != null) credentialDefinitions;
  credentialEnvironment = lib.listToAttrs (
    map (credential: {
      name = credential.environment;
      value = "/run/credentials/nixploy.service/${credential.name}";
    }) configuredCredentials
  );

  moduleEnvironment = {
    NIXPLOY_AUTH_MODE = cfg.authMode;
    NIXPLOY_MANAGED_APPLICATIONS_JSON = builtins.toJSON publicApplications;
  }
  // lib.optionalAttrs (cfg.operatorEmail != null) {
    NIXPLOY_OPERATOR_EMAIL = cfg.operatorEmail;
  }
  // lib.optionalAttrs (cfg.allowedOrigin != null) {
    NIXPLOY_ALLOWED_ORIGIN = cfg.allowedOrigin;
  }
  // credentialEnvironment;

  protectedEnvironmentNames = [
    "NIXPLOY_AUTH_MODE"
    "NIXPLOY_OPERATOR_EMAIL"
    "NIXPLOY_ALLOWED_ORIGIN"
    "NIXPLOY_MANAGED_APPLICATIONS_JSON"
    "NIXPLOY_SSH_IDENTITY_FILE"
    "NIXPLOY_SSH_KNOWN_HOSTS_FILE"
    "SOPS_AGE_KEY_FILE"
    "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE"
    "SOPS_AGE_SSH_PRIVATE_KEY_FILE"
  ];

  setProtectedEnvironment = lib.concatMapStringsSep "\n" (
    name:
    if builtins.hasAttr name moduleEnvironment then
      "export ${name}=${lib.escapeShellArg moduleEnvironment.${name}}"
    else
      "unset ${name}"
  ) protectedEnvironmentNames;

  startScript = pkgs.writeShellScript "nixploy-start" ''
    set -eu
    # systemd EnvironmentFile entries override Environment entries. Re-apply
    # every module-owned security and credential value in the child process.
    ${setProtectedEnvironment}
    exec ${lib.escapeShellArg "${cfg.package}/bin/nixploy-web"} \
      --port ${lib.escapeShellArg (toString cfg.port)} \
      --state-db ${lib.escapeShellArg "/var/lib/nixploy/state.sqlite3"}
  '';

  validApplicationKey = key: builtins.match "[a-z0-9][a-z0-9_-]{0,62}" key != null;
  validSubdirectory =
    subdirectory:
    !(lib.hasPrefix "/" subdirectory) && !(lib.elem ".." (lib.splitString "/" subdirectory));
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "services" "nixploy-control-plane" ] [ "services" "nixploy" ])
  ];

  options.services.nixploy = {
    enable = lib.mkEnableOption "the OCaml nixploy deployment control plane";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "packages.nixploy";
      description = "Package containing bin/nixploy-web.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback-only HTTP and WebSocket listen port.";
    };

    applications = lib.mkOption {
      default = { };
      description = ''
        NixOS-owned managed application allowlist. Repositories are existing,
        absolute local Git checkout paths; deployment source selection remains
        constrained to commits in those checkouts.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            project = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Project name expected from the deployment flake.";
            };
            target = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Deployment target from the deployment flake.";
            };
            repository = lib.mkOption {
              type = lib.types.strMatching "^/.*";
              description = "Absolute path to the host-owned Git repository checkout.";
            };
            repositoryIdentity = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Stable repository identity used in managed-resource ownership.";
            };
            subdirectory = lib.mkOption {
              type = lib.types.str;
              default = ".";
              description = "Relative flake directory within repository; parent traversal is rejected.";
            };
          };
        }
      );
    };

    authMode = lib.mkOption {
      type = lib.types.enum [
        "unrestricted"
        "tailscale"
      ];
      default = "tailscale";
      description = ''
        HTTP and RPC operator authentication mode. Unrestricted is appropriate
        only for an explicitly trusted local or development boundary.
      '';
    };

    operatorEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      example = "operator@example.com";
      description = "Exact Tailscale-User-Login allowed in tailscale auth mode.";
    };

    allowedOrigin = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      example = "https://nixploy.example.com";
      description = ''
        Optional single exact browser origin for WebSocket RPC. The OCaml
        server rejects malformed values, paths, wildcards, and suffix matches.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional root-managed systemd EnvironmentFile for additional
        deployment-process configuration. A generated start wrapper reapplies
        or clears every module-owned auth, origin, application, SSH, and SOPS
        credential variable after this file is loaded.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixploy";
      description = "Long-lived Unix identity that owns state and Podman connection configuration.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nixploy";
      description = "Primary group for the nixploy Unix identity.";
    };

    manageUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the dedicated nixploy user and group.";
    };

    readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/etc/nixploy/git" ];
      description = ''
        Additional paths the sandbox may read, for example Git credential
        helper configuration. Unix ownership and mode must still grant the
        nixploy user access. Application repositories are included
        automatically.
      '';
    };

    sshIdentityFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-readable SSH private key copied into the service credential directory.";
    };

    sshKnownHostsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-readable strict SSH known_hosts file copied into service credentials.";
    };

    sopsAgeKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-readable SOPS age identity copied into service credentials.";
    };

    sopsAgeSshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Root-readable SSH private key used as a SOPS age identity.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.authMode != "tailscale" || cfg.operatorEmail != null;
        message = "services.nixploy.operatorEmail is required when authMode is tailscale";
      }
      {
        assertion = !cfg.manageUser || cfg.user != "root";
        message = "services.nixploy.manageUser cannot create root";
      }
      {
        assertion = cfg.manageUser || builtins.hasAttr cfg.user config.users.users;
        message = "services.nixploy.manageUser = false requires the configured user to exist";
      }
      {
        assertion = lib.all validApplicationKey (lib.attrNames cfg.applications);
        message = "services.nixploy application keys must match [a-z0-9][a-z0-9_-]{0,62}";
      }
      {
        assertion = lib.all (application: validSubdirectory application.subdirectory) (
          lib.attrValues cfg.applications
        );
        message = "services.nixploy application subdirectories must be relative and cannot traverse parents";
      }
    ];

    users.groups = lib.mkIf cfg.manageUser {
      "${cfg.group}" = { };
    };

    users.users = lib.mkIf cfg.manageUser {
      "${cfg.user}" = {
        isNormalUser = true;
        group = cfg.group;
        home = "/var/lib/nixploy";
        createHome = true;
        linger = true;
      };
    };

    systemd.services.nixploy = {
      description = "nixploy OCaml deployment control plane";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = "/var/lib/nixploy";
        XDG_CACHE_HOME = "/var/lib/nixploy/.cache";
        XDG_CONFIG_HOME = "/var/lib/nixploy/.config";
        XDG_DATA_HOME = "/var/lib/nixploy/.local/share";
      }
      // moduleEnvironment;

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = startScript;
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        LoadCredential = map (credential: "${credential.name}:${credential.source}") configuredCredentials;
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "nixploy";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/nixploy";
        UMask = "0077";

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ReadWritePaths = [ "/var/lib/nixploy" ];
        ReadOnlyPaths =
          (map (application: application.repository) (lib.attrValues cfg.applications)) ++ cfg.readOnlyPaths;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };
  };
}
