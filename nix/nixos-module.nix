{
  config,
  lib,
  pkgs,
  defaultPackage,
  ...
}:

let
  cfg = config.services.nixploy;
  runtimeDirectoryPath = "/run/${config.systemd.services.nixploy.serviceConfig.RuntimeDirectory}";

  publicApplications = lib.mapAttrs (_key: application: {
    inherit (application)
      project
      target
      repository
      repositoryIdentity
      repositoryProvenance
      repositoryReference
      repositoryEvidenceFile
      repositoryEvidenceMaxAgeSeconds
      subdirectory
      production
      nonProduction
      ;
  }) cfg.applications;

  managedApplicationsFile = pkgs.writeText "nixploy-managed-applications.json" (
    builtins.toJSON publicApplications
  );

  credentialDefinitions = [
    {
      source = cfg.sshIdentityFile;
      name = "ssh-identity";
      environment = "NIXPLOY_SSH_IDENTITY_FILE";
      private = true;
    }
    {
      source = cfg.sshKnownHostsFile;
      name = "ssh-known-hosts";
      environment = "NIXPLOY_SSH_KNOWN_HOSTS_FILE";
      private = false;
    }
    {
      source = cfg.sopsAgeKeyFile;
      name = "sops-age-key";
      environment = "SOPS_AGE_KEY_FILE";
      private = true;
    }
    {
      source = cfg.sopsAgeSshKeyFile;
      name = "sops-age-ssh-key";
      environment = "NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE";
      private = true;
    }
  ];

  configuredCredentials = lib.filter (credential: credential.source != null) credentialDefinitions;
  configuredPrivateCredentials = lib.filter (credential: credential.private) configuredCredentials;
  credentialEnvironment = lib.listToAttrs (
    map (credential: {
      name = credential.environment;
      value = "/run/credentials/nixploy.service/${credential.name}";
    }) configuredCredentials
  );

  moduleEnvironment = {
    NIXPLOY_AUTH_MODE = cfg.authMode;
    RUNTIME_DIRECTORY = runtimeDirectoryPath;
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
    "RUNTIME_DIRECTORY"
  ];

  setProtectedEnvironment = lib.concatMapStringsSep "\n" (
    name:
    if builtins.hasAttr name moduleEnvironment then
      "export ${name}=${lib.escapeShellArg moduleEnvironment.${name}}"
    else
      "unset ${name}"
  ) protectedEnvironmentNames;

  installPrivateCredentials = lib.concatMapStringsSep "\n" (credential: ''
    ${pkgs.coreutils}/bin/install --mode=0600 --no-target-directory -- \
      ${lib.escapeShellArg "/run/credentials/nixploy.service/${credential.name}"} \
      "$RUNTIME_DIRECTORY/${credential.name}"
    export ${credential.environment}="$RUNTIME_DIRECTORY/${credential.name}"
  '') configuredPrivateCredentials;

  startScript = pkgs.writeShellScript "nixploy-start" ''
    set -eu
    # systemd EnvironmentFile entries override Environment entries. Re-apply
    # every module-owned security and credential value in the child process.
    ${setProtectedEnvironment}
    # LoadCredential files are root-owned mode 0440. Copy private values into
    # the ephemeral service-owned directory before strict identity validation.
    ${installPrivateCredentials}
    exec ${lib.escapeShellArg "${cfg.package}/bin/nixploy-web"} \
      --port ${lib.escapeShellArg (toString cfg.port)} \
      --state-db ${lib.escapeShellArg cfg.stateDatabasePath}
  '';

  safeIdentityValue =
    value: builtins.match ".*[[:space:]/@].*" value == null && !(lib.hasSuffix ".." value);
  stripLeadingZeros =
    value:
    if builtins.stringLength value > 1 && lib.hasPrefix "0" value then
      stripLeadingZeros (builtins.substring 1 (builtins.stringLength value - 1) value)
    else
      value;
  canonicalIpv4Octet =
    value:
    if builtins.match "[0-9]+" value == null then
      null
    else
      let
        number = builtins.fromJSON (stripLeadingZeros value);
      in
      if number <= 255 then toString number else null;
  canonicalEndpoint =
    value:
    let
      lowered = lib.toLower value;
      dns = lib.removeSuffix "." lowered;
      ipv4Parts = lib.splitString "." lowered;
      ipv4Octets = map canonicalIpv4Octet ipv4Parts;
    in
    if lib.hasSuffix ".." lowered then
      null
    else if builtins.match "[0-9.]+" lowered != null then
      if builtins.length ipv4Parts == 4 && lib.all (octet: octet != null) ipv4Octets then
        lib.concatStringsSep "." ipv4Octets
      else
        null
    else if lib.hasInfix ":" lowered then
      null
    else if builtins.match "[a-z0-9.-]+" dns == null then
      null
    else
      dns;
  endpointsIntersect =
    left: right:
    let
      canonicalLeft = canonicalEndpoint left;
      canonicalRight = canonicalEndpoint right;
    in
    canonicalLeft == null || canonicalRight == null || canonicalLeft == canonicalRight;
  destinationIntersection =
    productionApplication: nonProductionApplication:
    let
      production = productionApplication.production;
      nonProduction = nonProductionApplication.nonProduction;
      domainIntersection =
        production.domain != null
        && nonProduction.domain != null
        && endpointsIntersect production.domain nonProduction.domain;
    in
    (
      productionApplication.project == nonProductionApplication.project
      && productionApplication.target == nonProductionApplication.target
    )
    || endpointsIntersect production.host nonProduction.host
    || domainIntersection
    || lib.toLower production.coordinationScope == lib.toLower nonProduction.coordinationScope;
  productionApplications = lib.filter (application: application.production != null) (
    lib.attrValues cfg.applications
  );
  nonProductionApplications = lib.filter (application: application.nonProduction != null) (
    lib.attrValues cfg.applications
  );
  noCrossProfileIntersections = lib.all (
    productionApplication:
    lib.all (
      nonProductionApplication: !(destinationIntersection productionApplication nonProductionApplication)
    ) nonProductionApplications
  ) productionApplications;

  validApplicationKey = key: builtins.match "[a-z0-9][a-z0-9_-]{0,62}" key != null;
  validSubdirectory =
    subdirectory:
    !(lib.hasPrefix "/" subdirectory) && !(lib.elem ".." (lib.splitString "/" subdirectory));
  validProductionDestination =
    application:
    (application.production == null || application.nonProduction == null)
    && (
      application.production == null
      || (
        safeIdentityValue application.production.host
        && safeIdentityValue application.production.coordinationScope
        && (application.production.domain == null || safeIdentityValue application.production.domain)
      )
    )
    && (
      application.nonProduction == null
      || (
        safeIdentityValue application.nonProduction.host
        && safeIdentityValue application.nonProduction.coordinationScope
        && (application.nonProduction.domain == null || safeIdentityValue application.nonProduction.domain)
      )
    )
    && (
      application.production == null
      || (application.repositoryReference != null && application.repositoryEvidenceFile != null)
    )
    && (
      application.production == null
      || (
        application.production.user != "root"
        && (
          (application.production.kind == "web" && application.production.domain != null)
          || (application.production.kind == "non-web" && application.production.domain == null)
        )
      )
    )
    && (
      application.nonProduction == null
      || (
        application.nonProduction.user != "root"
        && (
          (application.nonProduction.kind == "web" && application.nonProduction.domain != null)
          || (application.nonProduction.kind == "non-web" && application.nonProduction.domain == null)
        )
      )
    );
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "services" "nixploy-control-plane" ] [ "services" "nixploy" ])
    (import ./target-lease-module.nix {
      inherit
        config
        lib
        pkgs
        defaultPackage
        ;
    })
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

    stateDatabasePath = lib.mkOption {
      type = lib.types.strMatching "^/.*";
      default = "/var/lib/nixploy/state.sqlite3";
      description = ''
        Absolute SQLite state database path. Its parent directory must be
        writable inside the service sandbox.
      '';
    };

    applications = lib.mkOption {
      default = { };
      description = ''
        NixOS-owned machine mutation authority shared by CLI and web.
        Production repositories are existing root-protected Git custody paths;
        deployment source selection is constrained by their fresh evidence
        manifests, protected refs, and exact commit objects.
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
              description = "Absolute path to the host-owned Git custody checkout.";
            };
            repositoryIdentity = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Stable repository identity used in managed-resource ownership.";
            };
            repositoryProvenance = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Root-owned provenance identifier attested by source freshness evidence.";
            };
            repositoryReference = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "^refs/heads/.+");
              default = null;
              description = "Protected full Git ref used for production source admission.";
            };
            repositoryEvidenceFile = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "^/.*");
              default = null;
              description = "Root-owned fresh ref/object evidence manifest for production source admission.";
            };
            repositoryEvidenceMaxAgeSeconds = lib.mkOption {
              type = lib.types.ints.between 1 3600;
              default = 900;
              description = "Maximum accepted source evidence age.";
            };
            subdirectory = lib.mkOption {
              type = lib.types.str;
              default = ".";
              description = "Relative flake directory within repository; parent traversal is rejected.";
            };
            production = lib.mkOption {
              default = null;
              description = ''
                Root-owned exact production destination intent. It must match
                the evaluated target before a preview receipt can authorize
                deployment.
              '';
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    host = lib.mkOption { type = lib.types.nonEmptyStr; };
                    user = lib.mkOption { type = lib.types.nonEmptyStr; };
                    port = lib.mkOption {
                      type = lib.types.port;
                      default = 22;
                    };
                    kind = lib.mkOption {
                      type = lib.types.enum [
                        "non-web"
                        "web"
                      ];
                    };
                    domain = lib.mkOption {
                      type = lib.types.nullOr lib.types.nonEmptyStr;
                      default = null;
                    };
                    coordinationScope = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                    };
                  };
                }
              );
            };
            nonProduction = lib.mkOption {
              default = null;
              description = "Root-owned exact destination permitted for local development or staging deployment.";
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    host = lib.mkOption { type = lib.types.nonEmptyStr; };
                    user = lib.mkOption { type = lib.types.nonEmptyStr; };
                    port = lib.mkOption {
                      type = lib.types.port;
                      default = 22;
                    };
                    kind = lib.mkOption {
                      type = lib.types.enum [
                        "non-web"
                        "web"
                      ];
                    };
                    domain = lib.mkOption {
                      type = lib.types.nullOr lib.types.nonEmptyStr;
                      default = null;
                    };
                    coordinationScope = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      default = "non-production";
                    };
                  };
                }
              );
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
      {
        assertion = lib.all validProductionDestination (lib.attrValues cfg.applications);
        message = "services.nixploy production destinations require a non-root SSH user and kind-matched domain";
      }
      {
        assertion = noCrossProfileIntersections;
        message = "services.nixploy production and nonProduction applications must not intersect by project/target, SSH host, domain, or coordination scope";
      }
    ];

    environment.etc."nixploy/managed-applications.json".source = managedApplicationsFile;

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
        TimeoutStopSec = 30;
        StateDirectory = "nixploy";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "nixploy";
        RuntimeDirectoryMode = "0700";
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
          (map (application: application.repository) (lib.attrValues cfg.applications))
          ++ (lib.filter (path: path != null) (
            map (application: application.repositoryEvidenceFile) (lib.attrValues cfg.applications)
          ))
          ++ cfg.readOnlyPaths;
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
