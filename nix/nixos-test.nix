{
  pkgs,
  nixployModule,
  nixployPackage,
  rpcProbe,
}:

pkgs.testers.runNixOSTest {
  name = "nixploy-ocaml-service";
  globalTimeout = 900;

  nodes.machine = {
    imports = [ nixployModule ];

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    services.nixploy = {
      enable = true;
      package = nixployPackage;
      authMode = "unrestricted";
      port = 18080;
      stateDatabasePath = "/var/lib/nixploy/test-state.sqlite3";
      environmentFile = "/etc/nixploy-test.env";
      sshIdentityFile = "/etc/nixploy-test-ssh";
      sshKnownHostsFile = "/etc/nixploy-test-known-hosts";
      sopsAgeKeyFile = "/etc/nixploy-test.age";
      sopsAgeSshKeyFile = "/etc/nixploy-test-sops-ssh";
      applications.example = {
        project = "example";
        target = "production";
        repository = "/var/lib/nixploy-custody/example";
        repositoryIdentity = "owner/example";
        repositoryProvenance = "ssh://git@example.invalid/example.git";
        repositoryReference = "refs/heads/main";
        repositoryEvidenceFile = "/var/lib/nixploy-custody/example.evidence.json";
        repositoryEvidenceMaxAgeSeconds = 3600;
        subdirectory = ".";
        production = {
          host = "production.example.invalid";
          user = "deploy";
          port = 2222;
          kind = "non-web";
          coordinationScope = "example-production";
        };
      };
    };

    # Prove private credential destinations follow the effective systemd
    # runtime directory rather than a module-hardcoded path.
    systemd.services.nixploy.serviceConfig.RuntimeDirectory = pkgs.lib.mkForce "nixploy-test-runtime";

    environment.etc = {
      "nixploy-test.env".text = ''
        NIXPLOY_AUTH_MODE=tailscale
        NIXPLOY_OPERATOR_EMAIL=attacker@example.com
        NIXPLOY_ALLOWED_ORIGIN=https://attacker.example.com
        NIXPLOY_MANAGED_APPLICATIONS_JSON={}
        NIXPLOY_SSH_IDENTITY_FILE=/tmp/attacker-ssh
        NIXPLOY_SSH_KNOWN_HOSTS_FILE=/tmp/attacker-known-hosts
        SOPS_AGE_KEY_FILE=/tmp/attacker.age
        NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE=/tmp/attacker-sops-ssh
        SOPS_AGE_SSH_PRIVATE_KEY_FILE=/tmp/attacker-generic-sops-ssh
        RUNTIME_DIRECTORY=/var/lib/nixploy/attacker-runtime
      '';
      "nixploy-test-ssh".text = "test ssh credential\n";
      "nixploy-test-known-hosts".text = "test known hosts credential\n";
      "nixploy-test.age".text = "test age credential\n";
      "nixploy-test-sops-ssh".text = "test sops ssh credential\n";
    };

    # ReadOnlyPaths requires the configured repository to exist before systemd
    # creates the service mount namespace. This also gives the smoke test a real
    # checkout with which to verify repository visibility through that namespace.
    systemd.services.test-repository = {
      description = "Create the nixploy VM smoke-test repository";
      requiredBy = [ "nixploy.service" ];
      before = [ "nixploy.service" ];
      path = [
        pkgs.coreutils
        pkgs.git
        pkgs.util-linux
      ];
      script = ''
        install -d -m 0700 -o nixploy -g nixploy /var/lib/nixploy
        install -d -m 0755 -o root -g root /var/lib/nixploy-custody/example
                git -C /var/lib/nixploy-custody/example init --initial-branch=main
        git -C /var/lib/nixploy-custody/example config user.name "NixOS test"
        git -C /var/lib/nixploy-custody/example config user.email "nixos-test@example.com"
        git -C /var/lib/nixploy-custody/example config remote.origin.url "ssh://git@example.invalid/example.git"
        cat > /var/lib/nixploy-custody/example/flake.nix <<'EOF'
        {
          outputs = _: {
            nixploy = {
              __schema = "v0.4";
              project = "example";
              targets.production = {
                image = "unused";
                ip = "production.example.invalid";
                user = "deploy";
                port = 2222;
                production.coordinationScope = "example-production";
              };
            };
          };
        }
        EOF
        cat > /var/lib/nixploy-custody/example/flake.lock <<'EOF'
        {"nodes":{"root":{}},"root":"root","version":7}
        EOF
        git -C /var/lib/nixploy-custody/example add flake.nix flake.lock
        git -C /var/lib/nixploy-custody/example commit -m smoke
        revision=$(git -C /var/lib/nixploy-custody/example rev-parse HEAD)
        observed=$(date +%s)
        printf '{"version":1,"provenance":"ssh://git@example.invalid/example.git","reference":"refs/heads/main","revision":"%s","observedAtUnixSeconds":%s}\n' "$revision" "$observed" > /var/lib/nixploy-custody/example.evidence.json
        chmod 0444 /var/lib/nixploy-custody/example.evidence.json
      '';
      serviceConfig.Type = "oneshot";
    };

    environment.systemPackages = [
      pkgs.curl
      pkgs.git
      pkgs.iproute2
      pkgs.jq
      pkgs.sqlite
      pkgs.util-linux
      rpcProbe
      nixployPackage
    ];

    security.unprivilegedUsernsClone = true;
    system.stateVersion = "26.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("nixploy.service", timeout=300)
    machine.wait_for_open_port(18080, timeout=120)

    machine.succeed("curl --fail --silent http://127.0.0.1:18080/healthz | grep -Fx ok")
    machine.succeed("curl --fail --silent http://127.0.0.1:18080/ | grep -F '<!doctype html>'")
    for path in ["apps", "apps/example", "telemetry"]:
        machine.succeed(f"curl --fail --silent http://127.0.0.1:18080/{path} | grep -F '<div id=\"app\"></div>'")
    machine.succeed("curl --silent --output /dev/null --write-out '%{http_code}\\n' http://127.0.0.1:18080/arbitrary-unknown-path | grep -Fx 404")
    machine.succeed("curl --fail --silent --output /tmp/nixploy-main.js http://127.0.0.1:18080/main.js && test -s /tmp/nixploy-main.js")
    machine.succeed("curl --fail --silent http://127.0.0.1:18080/app.css | grep -F ':root {'")
    for font in ["ibm-plex-mono-400.ttf", "ibm-plex-mono-600.ttf"]:
        machine.succeed(f"curl --fail --silent --dump-header /tmp/{font}.headers --output /tmp/{font} http://127.0.0.1:18080/fonts/{font} && test -s /tmp/{font} && grep -i '^content-type: font/ttf' /tmp/{font}.headers")
    machine.succeed("ss --listening --tcp --numeric | grep -E '127\\.0\\.0\\.1:18080([[:space:]]|$)'")
    machine.fail("ss --listening --tcp --numeric | grep -E '(^|[[:space:]])(0\\.0\\.0\\.0|\\[::\\]):18080([[:space:]]|$)'")

    machine.wait_until_succeeds("test -s /var/lib/nixploy/test-state.sqlite3", timeout=120)
    machine.succeed("sqlite3 /var/lib/nixploy/test-state.sqlite3 \"select name from sqlite_master where type='table'\" | grep -Fx deployments")
    machine.succeed("nixploy-rpc-probe --uri http://127.0.0.1:18080 | grep -Fx 'example not-deployed'")
    machine.fail("nixploy-rpc-probe --uri http://127.0.0.1:18080 --skip-capabilities")
    # These probes dispatch only the requested managed RPC after the handshake.
    # They must not evaluate the custody checkout or admit a deployment.
    machine.succeed("! nixploy-rpc-probe --uri http://127.0.0.1:18080 --preview example >/tmp/nixploy-preview.out 2>&1; grep -F NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE /tmp/nixploy-preview.out")
    machine.succeed("! nixploy-rpc-probe --uri http://127.0.0.1:18080 --deploy example >/tmp/nixploy-deploy.out 2>&1; grep -F NIXPLOY_MANAGED_DEPLOY_UNAVAILABLE /tmp/nixploy-deploy.out")
    machine.succeed("test $(sqlite3 /var/lib/nixploy/test-state.sqlite3 'select count(*) from deployments') -eq 0")
    machine.succeed("test $(sqlite3 /var/lib/nixploy/test-state.sqlite3 'select count(*) from resource_states') -eq 0")

    revision = machine.succeed("git -C /var/lib/nixploy-custody/example rev-parse HEAD").strip()
    flake_digest = machine.succeed("git -C /var/lib/nixploy-custody/example show HEAD:flake.nix | sha256sum | cut -d' ' -f1").strip()
    machine.succeed(f"runuser -u nixploy -- nixploy-source-authority-probe example | grep -Fx '{revision} {flake_digest}'")

    # A service-owned global attributes/filter configuration changes an ordinary
    # checkout, but protected materialization writes and verifies committed blob
    # bytes under a fully replaced Git environment.
    machine.succeed("install -m 0644 -o nixploy -g nixploy /dev/null /var/lib/nixploy/attacker.attributes && printf 'flake.nix filter=attacker\\n' > /var/lib/nixploy/attacker.attributes && chown nixploy:nixploy /var/lib/nixploy/attacker.attributes")
    machine.succeed("cat > /var/lib/nixploy/.gitconfig <<'EOF'\n[core]\n  attributesFile = /var/lib/nixploy/attacker.attributes\n[filter \"attacker\"]\n  smudge = sed s/example/FILTERED/g\n  required = true\nEOF\nchown nixploy:nixploy /var/lib/nixploy/.gitconfig")
    machine.succeed("rm -rf /tmp/filtered-checkout && runuser -u nixploy -- env HOME=/var/lib/nixploy git -c safe.directory='*' clone /var/lib/nixploy-custody/example /tmp/filtered-checkout && grep -F FILTERED /tmp/filtered-checkout/flake.nix")
    machine.succeed(f"runuser -u nixploy -- env HOME=/var/lib/nixploy nixploy-source-authority-probe example | grep -Fx '{revision} {flake_digest}'")
    machine.succeed("rm /var/lib/nixploy/.gitconfig /var/lib/nixploy/attacker.attributes")

    # Protected Git runs reject inherited object/config/work-tree authority
    # rather than merely hoping Git ignores it.
    for attack in [
        "GIT_OBJECT_DIRECTORY=/tmp/external-objects",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES=/tmp/external-objects",
        "GIT_DIR=/tmp/external-git-dir",
        "GIT_WORK_TREE=/tmp/external-work-tree",
        "GIT_CONFIG_GLOBAL=/tmp/attacker.gitconfig",
        "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.useReplaceRefs GIT_CONFIG_VALUE_0=true",
        "GIT_REPLACE_REF_BASE=refs/attacker-replace",
    ]:
        machine.fail(f"runuser -u nixploy -- env {attack} nixploy-source-authority-probe example")
    machine.succeed("test $(sqlite3 /var/lib/nixploy/test-state.sqlite3 'select count(*) from deployments') -eq 0")

    machine.succeed("mkdir -p /tmp/external-objects /var/lib/nixploy-custody/example/.git/objects/info && printf '/tmp/external-objects\\n' > /var/lib/nixploy-custody/example/.git/objects/info/alternates")
    machine.fail("runuser -u nixploy -- nixploy-source-authority-probe example")
    machine.succeed("rm /var/lib/nixploy-custody/example/.git/objects/info/alternates")
    machine.succeed("mkdir -p /var/lib/nixploy-custody/example/.git/refs/replace")
    machine.fail("runuser -u nixploy -- nixploy-source-authority-probe example")
    machine.succeed("rmdir /var/lib/nixploy-custody/example/.git/refs/replace")
    machine.succeed("printf '[include]\\n  path = /tmp/attacker.gitconfig\\n' >> /var/lib/nixploy-custody/example/.git/config")
    machine.fail("runuser -u nixploy -- nixploy-source-authority-probe example")
    machine.succeed("sed -i '/^\\[include\\]$/,+1d' /var/lib/nixploy-custody/example/.git/config")
    machine.succeed("mv /var/lib/nixploy-custody/example.evidence.json /var/lib/nixploy-custody/example.evidence.real && ln -s example.evidence.real /var/lib/nixploy-custody/example.evidence.json")
    machine.fail("runuser -u nixploy -- nixploy-source-authority-probe example")
    machine.succeed("rm /var/lib/nixploy-custody/example.evidence.json && mv /var/lib/nixploy-custody/example.evidence.real /var/lib/nixploy-custody/example.evidence.json")
    machine.succeed(f"runuser -u nixploy -- nixploy-source-authority-probe example | grep -Fx '{revision} {flake_digest}'")

    # A checked-out managed target never reaches the local state or deployment
    # path when the CLI rejects it before managed authority selection.
    machine.succeed("rm -rf /tmp/direct-production && runuser -u nixploy -- git -c 'safe.directory=*' clone /var/lib/nixploy-custody/example /tmp/direct-production")
    machine.fail("runuser -u nixploy -- nixploy deploy --directory /tmp/direct-production --target production --state-db /tmp/direct-production.sqlite")
    machine.succeed("test ! -e /tmp/direct-production.sqlite")

    service_environment = "tr '\\0' '\\n' < /proc/$(systemctl show --property MainPID --value nixploy.service)/environ"
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_AUTH_MODE=unrestricted")
    machine.succeed(f"{service_environment} | grep -Fx RUNTIME_DIRECTORY=/run/nixploy-test-runtime")
    machine.fail(f"{service_environment} | grep -E '^NIXPLOY_(OPERATOR_EMAIL|ALLOWED_ORIGIN)='")
    machine.fail(f"{service_environment} | grep -E '^NIXPLOY_MANAGED_APPLICATIONS_JSON='")
    machine.succeed("jq -e '.example.repository == \"/var/lib/nixploy-custody/example\"' /etc/nixploy/managed-applications.json")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SSH_IDENTITY_FILE=/run/nixploy-test-runtime/ssh-identity")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SSH_KNOWN_HOSTS_FILE=/run/credentials/nixploy.service/ssh-known-hosts")
    machine.succeed(f"{service_environment} | grep -Fx SOPS_AGE_KEY_FILE=/run/nixploy-test-runtime/sops-age-key")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE=/run/nixploy-test-runtime/sops-age-ssh-key")
    machine.fail(f"{service_environment} | grep -E '^SOPS_AGE_SSH_PRIVATE_KEY_FILE='")

    machine.succeed("test $(systemctl show --property RuntimeDirectory --value nixploy.service) = nixploy-test-runtime")
    machine.succeed("test $(stat --format='%a:%U:%G' /run/nixploy-test-runtime) = 700:nixploy:nixploy")
    for source, copied in [
        ("/etc/nixploy-test-ssh", "/run/nixploy-test-runtime/ssh-identity"),
        ("/etc/nixploy-test.age", "/run/nixploy-test-runtime/sops-age-key"),
        ("/etc/nixploy-test-sops-ssh", "/run/nixploy-test-runtime/sops-age-ssh-key"),
    ]:
        machine.succeed(f"cmp {source} {copied}")
        machine.succeed(f"test $(stat --format='%a:%U:%G' {copied}) = 600:nixploy:nixploy")

    machine.succeed("pid=$(systemctl show --property MainPID --value nixploy.service); nsenter --target $pid --mount -- runuser -u nixploy -- git -c 'safe.directory=*' -C /var/lib/nixploy-custody/example rev-parse --is-inside-work-tree | grep -Fx true")
    machine.succeed("test $(systemctl list-unit-files 'nixploy*' --no-legend | wc -l) -eq 1")
    machine.fail("systemctl list-unit-files --no-legend | grep -E 'nixploy.*worker|postgresql|ecto'")
    machine.succeed("systemctl is-active nixploy.service")
  '';
}
