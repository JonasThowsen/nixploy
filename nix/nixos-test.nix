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

    services.nixploy = {
      enable = true;
      package = nixployPackage;
      authMode = "unrestricted";
      port = 18080;
      environmentFile = "/etc/nixploy-test.env";
      sshIdentityFile = "/etc/nixploy-test-ssh";
      sshKnownHostsFile = "/etc/nixploy-test-known-hosts";
      sopsAgeKeyFile = "/etc/nixploy-test.age";
      sopsAgeSshKeyFile = "/etc/nixploy-test-sops-ssh";
      applications.example = {
        project = "example";
        target = "production";
        repository = "/var/lib/nixploy/repositories/example";
        repositoryIdentity = "owner/example";
        subdirectory = ".";
      };
    };

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
        install -d -m 0750 -o nixploy -g nixploy /var/lib/nixploy/repositories/example
        runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example init --initial-branch=main
        runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example config user.name "NixOS test"
        runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example config user.email "nixos-test@example.com"
        echo smoke > /var/lib/nixploy/repositories/example/README
        chown nixploy:nixploy /var/lib/nixploy/repositories/example/README
        runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example add README
        runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example commit -m smoke
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
    ];

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

    machine.wait_until_succeeds("test -s /var/lib/nixploy/state.sqlite3", timeout=120)
    machine.succeed("sqlite3 /var/lib/nixploy/state.sqlite3 \"select name from sqlite_master where type='table'\" | grep -Fx deployments")
    machine.succeed("nixploy-rpc-probe --uri http://127.0.0.1:18080 | grep -Fx 'example not-deployed'")

    service_environment = "tr '\\0' '\\n' < /proc/$(systemctl show --property MainPID --value nixploy.service)/environ"
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_AUTH_MODE=unrestricted")
    machine.fail(f"{service_environment} | grep -E '^NIXPLOY_(OPERATOR_EMAIL|ALLOWED_ORIGIN)='")
    machine.succeed(f"{service_environment} | sed -n 's/^NIXPLOY_MANAGED_APPLICATIONS_JSON=//p' | jq -e '.example.repository == \"/var/lib/nixploy/repositories/example\"'")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SSH_IDENTITY_FILE=/run/credentials/nixploy.service/ssh-identity")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SSH_KNOWN_HOSTS_FILE=/run/credentials/nixploy.service/ssh-known-hosts")
    machine.succeed(f"{service_environment} | grep -Fx SOPS_AGE_KEY_FILE=/run/credentials/nixploy.service/sops-age-key")
    machine.succeed(f"{service_environment} | grep -Fx NIXPLOY_SOPS_AGE_SSH_PRIVATE_KEY_FILE=/run/credentials/nixploy.service/sops-age-ssh-key")
    machine.fail(f"{service_environment} | grep -E '^SOPS_AGE_SSH_PRIVATE_KEY_FILE='")

    machine.succeed("pid=$(systemctl show --property MainPID --value nixploy.service); nsenter --target $pid --mount -- runuser -u nixploy -- git -C /var/lib/nixploy/repositories/example rev-parse --is-inside-work-tree | grep -Fx true")
    machine.succeed("test $(systemctl list-unit-files 'nixploy*' --no-legend | wc -l) -eq 1")
    machine.fail("systemctl list-unit-files --no-legend | grep -E 'nixploy.*worker|postgresql|ecto'")
    machine.succeed("systemctl is-active nixploy.service")
  '';
}
