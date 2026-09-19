{ pkgs, nixployPackage }:

let
  image = pkgs.dockerTools.buildLayeredImage {
    name = "nixploy-cli-smoke";
    tag = "test";
    contents = [ pkgs.busybox ];
    config.Cmd = [
      "${pkgs.busybox}/bin/sh"
      "-c"
      ''mkdir -p /tmp/www; printf healthy > /tmp/www/health; printf 'nixploy-smoke-started\n'; exec ${pkgs.busybox}/bin/httpd -f -p "$PORT" -h /tmp/www''
    ];
  };
  fixture = pkgs.writeText "nixploy-cli-smoke-flake.nix" ''
    {
      outputs = _: {
        docker = builtins.appendContext "${image}" {
          "${image}" = { path = true; };
        };
        nixploy = {
          __schema = "v0.5";
          project = "cli-smoke";
          targets = let
            common = {
              image = "docker";
              ip = "127.0.0.1";
              user = "root";
              identityFile = "/root/.ssh/id_ed25519";
              secrets.app = "./runtime.env";
              runbook = {
                probe = {
                  description = "Verify literal arguments reach the application";
                  command = [ "${pkgs.busybox}/bin/printf" "%s\\n" "literal ; $HOME" ];
                };
                failure = {
                  description = "Return a known application exit code";
                  command = [ "${pkgs.busybox}/bin/sh" "-c" "exit 42" ];
                };
                secret = {
                  description = "Verify the deployed secret without printing it";
                  command = [ "${pkgs.busybox}/bin/sh" "-c" "test \"$SMOKE_SECRET\" = smoke-secret" ];
                };
                console = {
                  description = "Interactive application shell";
                  command = [ "${pkgs.busybox}/bin/sh" ];
                  interactive = true;
                };
                terminal = {
                  description = "Verify all standard descriptors are terminals";
                  command = [ "${pkgs.busybox}/bin/sh" "-c" "test -t 0 && test -t 1 && test -t 2 && printf '\\ntty-ok\\n'" ];
                  interactive = true;
                };
                mark = {
                  description = "Mark the selected application container";
                  command = [ "${pkgs.busybox}/bin/touch" "/tmp/runbook-selected" ];
                };
                pause = {
                  description = "Hold a runbook operation for the contention test";
                  command = [ "${pkgs.busybox}/bin/sh" "-c" "touch /tmp/runbook-ready; for i in $(seq 1 180); do test ! -f /tmp/runbook-release || exit 0; sleep 1; done; exit 1" ];
                };
              };
            };
          in {
            missing = common // {
              run = { network = "host"; environment.PORT = "18084"; };
            };
            worker = common // {
              run = {
                network = "host";
                environment.PORT = "18083";
                preStart = [ [ "${pkgs.busybox}/bin/sh" "-c" "test \"$SMOKE_SECRET\" = smoke-secret" ] ];
              };
            };
            web = common // {
              run = {
                network = "host";
                environment.PORT = "{port}";
                preStart = [ [ "${pkgs.busybox}/bin/sh" "-c" "test \"$SMOKE_SECRET\" = smoke-secret" ] ];
              };
              web = {
                domain = "app.test";
                healthPath = "/health";
                slots = { blue = 18081; green = 18082; };
              };
            };
          };
        };
      };
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "nixploy-daemonless-cli";
  globalTimeout = 2400;

  nodes.machine = {
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    nix.settings.substituters = pkgs.lib.mkForce [ ];
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    virtualisation.podman = {
      enable = true;
      autoPrune.enable = false;
    };
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "prohibit-password";
    };
    services.caddy = {
      enable = true;
      globalConfig = "auto_https off";
      extraConfig = ''
        :8088 {
          respond "unrelated application"
        }
      '';
    };
    environment.systemPackages = [
      nixployPackage
      pkgs.git
      pkgs.curl
      pkgs.jq
      pkgs.python3
      pkgs.util-linux
      pkgs.age
      pkgs.sops
    ];
    system.extraDependencies = [ image ];
    system.stateVersion = "26.05";
  };

  testScript = ''
    import json
    import shlex

    start_all()
    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("caddy.service")
    def setup(command):
        return machine.succeed("bash -euo pipefail -c " + shlex.quote(command))

    machine.succeed("curl --fail --silent --request PUT --json " + shlex.quote(json.dumps({"listen": [":80"], "routes": [], "automatic_https": {"disable": True}})) + " http://127.0.0.1:2019/config/apps/http/servers/nixploy")
    machine.succeed("systemctl start podman.socket")
    machine.succeed("install -d -m 0700 /root/.ssh")
    machine.succeed("ssh-keygen -q -t ed25519 -N " + shlex.quote("") + " -f /root/.ssh/id_ed25519")
    setup("cat /root/.ssh/id_ed25519.pub > /root/.ssh/authorized_keys; chmod 0600 /root/.ssh/authorized_keys")
    machine.succeed("ssh-keyscan -H 127.0.0.1 > /root/.ssh/known_hosts")
    machine.succeed("ssh -o BatchMode=yes -o StrictHostKeyChecking=yes root@127.0.0.1 true")
    setup("mkdir -p /srv/app; cp ${fixture} /srv/app/flake.nix; chmod u+w /srv/app/flake.nix")
    setup("install -d -m 0700 /root/.config/sops/age; age-keygen -o /root/.config/sops/age/keys.txt; chmod 0600 /root/.config/sops/age/keys.txt")
    setup("printf 'SMOKE_SECRET=smoke-secret\\n' > /tmp/runtime.env; sops --encrypt --age $(age-keygen -y /root/.config/sops/age/keys.txt) --input-type dotenv --output-type dotenv /tmp/runtime.env > /srv/app/runtime.env; rm /tmp/runtime.env")
    setup("git -C /srv/app init -b main; git -C /srv/app config user.email test@example.invalid; git -C /srv/app config user.name 'CLI smoke test'")
    machine.succeed("git -C /srv/app remote add origin https://example.invalid/cli-smoke.git")
    setup("git -C /srv/app add flake.nix runtime.env; git -C /srv/app commit -m fixture")

    cli = "nixploy --help"
    help_text = machine.succeed(cli)
    assert "control-plane" not in help_text
    machine.succeed("test ! -e /etc/nixploy")
    machine.fail("systemctl cat nixploy.service")
    machine.fail("command -v nixploy-web")

    def command(action, target, extra=""):
        return f"SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt nixploy {action} -C /srv/app -t {target} {extra}"

    def active_web_container():
        routes = json.loads(machine.succeed("curl --fail --silent http://127.0.0.1:2019/config/apps/http/servers/nixploy/routes"))
        owned = [r for r in routes if r.get("match") == [{"host": ["app.test"]}]]
        assert len(owned) == 1, routes
        proxy = owned[0]["handle"][0]["routes"][0]["handle"][0]
        port = proxy["upstreams"][0]["dial"].rsplit(":", 1)[1]
        ids = machine.succeed("podman ps --filter label=io.nixploy.target=web --filter label=io.nixploy.managed=true --format '{{.ID}}'").split()
        assert ids
        containers = json.loads(machine.succeed("podman inspect " + " ".join(shlex.quote(i) for i in ids)))
        active = [c for c in containers if "PORT=" + port in c["Config"]["Env"]]
        assert len(active) == 1, containers
        for container in containers:
            machine.succeed("podman exec " + shlex.quote(container["Id"]) + " ${pkgs.busybox}/bin/rm -f /tmp/runbook-selected")
        machine.succeed(command("run", "web", "mark"))
        for container in containers:
            code, output = machine.execute("podman exec " + shlex.quote(container["Id"]) + " ${pkgs.busybox}/bin/test -f /tmp/runbook-selected")
            assert (code == 0) == (container["Id"] == active[0]["Id"]), output
        return active[0]["Id"]

    with subtest("discover runbook without a running application"):
        output = machine.succeed(command("runbook", "worker"))
        assert "probe" in output and "Interactive application shell" in output
        code, output = machine.execute(command("run", "missing", "probe") + " 2>&1")
        assert code != 0 and "no such container" in output.lower(), output

    with subtest("non-web deployment and runbook"):
        machine.succeed(command("deploy", "worker"), timeout=300)
        machine.succeed("curl --fail http://127.0.0.1:18083/health | grep healthy")
        status = json.loads(machine.succeed(command("status", "worker", "--json")))
        assert status["project"] == "cli-smoke" and status["target"] == "worker", status
        assert status["resourceKey"] and len(status["containers"]) == 1, status
        assert status["containers"][0]["revision"], status
        assert status["containers"][0]["role"] == "app", status
        assert status["containers"][0]["restartPolicy"] == "always", status
        assert status["containers"][0]["memoryBytes"] > 0, status
        assert status["guard"]["state"] == "idle", status
        assert status["disk"]["availableBytes"] > 0, status
        owned = [r for i in status["images"] for r in i["references"]]
        assert owned and all(r.startswith("localhost/nixploy/") for r in owned), status
        assert "nixploy-cli-smoke:test" not in machine.succeed("podman images --format '{{.Repository}}:{{.Tag}}'")
        rendered = machine.succeed(command("status", "worker"))
        assert "Reboot:" in rendered and "running" in rendered, rendered
        history = json.loads(machine.succeed(command("history", "worker", "--json")))
        assert len(history) == 1 and history[0]["state"].lower() == "succeeded", history
        assert history[0]["revision"] == status["containers"][0]["revision"], history
        assert history[0]["finishedAtMs"] >= history[0]["requestedAtMs"], history
        output = machine.succeed(command("run", "worker", "probe"))
        assert "literal ; $HOME" in output
        machine.succeed(command("run", "worker", "secret"))
        code, output = machine.execute(command("run", "worker", "failure"))
        assert code == 42, (code, output)
        code, output = machine.execute(command("run", "worker", "console </dev/null") + " 2>&1")
        assert code != 0 and ("terminal" in output.lower() or "tty" in output.lower()), output
        assert "nixploy-smoke-started" in machine.succeed(command("logs", "worker"))

    with subtest("interactive console requires and works with a terminal"):
        terminal = shlex.quote(command("run", "worker", "terminal"))
        setup("script -qec " + terminal + " /dev/null </dev/null >/tmp/terminal.log")
        assert "tty-ok" in machine.succeed("cat /tmp/terminal.log")
        console = shlex.quote(command("run", "worker", "console"))
        setup("printf 'exit 0\\n' | script -qec " + console + " /dev/null >/tmp/console.log")

    with subtest("different checkouts and local databases cannot overlap mutations"):
        setup("git clone /srv/app /srv/other-app; git -C /srv/other-app remote set-url origin https://example.invalid/cli-smoke.git")
        container = machine.succeed("podman ps --filter label=io.nixploy.target=worker --format '{{.ID}}'").strip()
        assert container and "\\n" not in container
        execute = "podman exec " + shlex.quote(container) + " ${pkgs.busybox}/bin/"
        machine.succeed(execute + "rm -f /tmp/runbook-ready /tmp/runbook-release")
        machine.succeed("rm -f /tmp/runbook-exit")
        secrets_before = machine.succeed("podman secret ls --format '{{.Name}}' | sort")
        machine.succeed("(" + command("run", "worker", "pause") + "; echo $? > /tmp/runbook-exit) >/tmp/runbook-pause.log 2>&1 &")
        competing = "NIXPLOY_STATE_DB=/tmp/other-state.db nixploy run -C /srv/other-app -t worker probe"
        try:
            machine.wait_until_succeeds(execute + "test -f /tmp/runbook-ready")
            for attempt in [competing, command("prune", "worker", "--stale --yes")]:
                code, output = machine.execute(attempt + " 2>&1")
                assert code != 0 and "NIXPLOY_MUTATION_BLOCKED" in output, output
            machine.succeed("podman container exists " + shlex.quote(container))
            assert machine.succeed("podman secret ls --format '{{.Name}}' | sort") == secrets_before
        finally:
            machine.succeed(execute + "touch /tmp/runbook-release")
        machine.wait_until_succeeds("test -f /tmp/runbook-exit")
        machine.succeed("grep -Fx 0 /tmp/runbook-exit")
        machine.succeed(competing)

    with subtest("blue-green deployment and active runbook"):
        machine.succeed(command("deploy", "web"), timeout=300)
        machine.succeed("curl --fail -H 'Host: app.test' http://127.0.0.1/health | grep healthy")
        first = active_web_container()
        machine.succeed(command("run", "web", "probe"))
        machine.succeed(command("deploy", "web"), timeout=300)
        second = active_web_container()
        assert first and second and first != second
        machine.succeed("curl --fail -H 'Host: app.test' http://127.0.0.1/health | grep healthy")
        machine.succeed(command("run", "web", "probe"))
        machine.succeed("curl --fail http://127.0.0.1:8088 | grep 'unrelated application'")
        web_status = json.loads(machine.succeed(command("status", "web", "--json")))
        assert [c["role"] for c in web_status["containers"]] == ["active"], web_status
        assert web_status["route"]["state"] == "routed", web_status
        preview = json.loads(machine.succeed(command("prune", "web", "--stale --dry-run --json")))
        assert preview["dryRun"] and preview["containers"] == [], preview
        stale = json.loads(machine.succeed(command("prune", "web", "--stale --keep 1 --yes --json")))
        assert stale["route"] == "kept" and stale["containers"] == [], stale
        assert second == active_web_container()
        machine.succeed("curl --fail -H 'Host: app.test' http://127.0.0.1/health | grep healthy")

    with subtest("host inventory and orphaned target cleanup"):
        setup("sed -i 's/missing = common/retired = common/' /srv/other-app/flake.nix")
        machine.succeed("SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt nixploy deploy -C /srv/other-app -t retired", timeout=300)
        inventory = json.loads(machine.succeed(command("resources", "worker", "--json")))
        by_target = {r["target"]: r for r in inventory["resources"]}
        assert by_target["worker"]["classification"] == "current", inventory
        assert by_target["web"]["classification"] == "declared", inventory
        retired = by_target["retired"]
        assert retired["classification"] == "orphaned" and len(retired["containers"]) == 1, inventory
        assert retired["secrets"] and retired["images"], inventory
        assert "--orphan " + retired["resourceKey"] in machine.succeed(command("resources", "worker"))
        code, output = machine.execute(command("prune", "worker", "--orphan " + retired["resourceKey"] + " --dry-run") + " 2>&1")
        assert code != 0 and "NIXPLOY_PRUNE_ACTIVE" in output, output
        stopped = json.loads(machine.succeed(command("stop", "worker", "--orphan " + retired["resourceKey"] + " --json")))
        assert len(stopped["containers"]) == 1, stopped
        state = machine.succeed("podman inspect --format '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' " + shlex.quote(retired["containers"][0]["id"])).strip()
        assert state == "false no", state
        preview = json.loads(machine.succeed(command("prune", "worker", "--orphan " + retired["resourceKey"] + " --dry-run --json")))
        assert preview["dryRun"] and len(preview["containers"]) == 1, preview
        machine.succeed("podman container exists " + shlex.quote(retired["containers"][0]["id"]))
        code, output = machine.execute(command("prune", "worker", "--orphan " + by_target["web"]["resourceKey"] + " --yes") + " 2>&1")
        assert code != 0 and "declares" in output, output
        removed = json.loads(machine.succeed(command("prune", "worker", "--orphan " + retired["resourceKey"] + " --yes --json")))
        assert not removed["dryRun"] and removed["containers"] == preview["containers"], removed
        assert machine.succeed("podman ps -a --filter label=io.nixploy.target=retired --format '{{.ID}}'").strip() == ""
        assert retired["secrets"][0] not in machine.succeed("podman secret ls --format '{{.Name}}'")
        machine.succeed("curl --fail http://127.0.0.1:18083/health | grep healthy")
        machine.succeed("curl --fail -H 'Host: app.test' http://127.0.0.1/health | grep healthy")

    with subtest("explicit scoped cleanup"):
        machine.fail(command("prune", "worker"))
        code, output = machine.execute(command("prune", "worker", "--yes") + " 2>&1")
        assert code != 0 and "NIXPLOY_PRUNE_ACTIVE" in output, output
        machine.succeed(command("stop", "worker"))
        worker_status = json.loads(machine.succeed(command("status", "worker", "--json")))
        assert worker_status["stopped"], worker_status
        machine.succeed(command("prune", "worker", "--yes"))
        machine.fail(command("run", "worker", "probe"))
        machine.succeed(command("run", "web", "probe"))
        code, output = machine.execute(command("prune", "web", "--yes") + " 2>&1")
        assert code != 0 and "NIXPLOY_PRUNE_ACTIVE" in output, output
        machine.succeed("curl --fail -H 'Host: app.test' http://127.0.0.1/health | grep healthy")
        stopped = json.loads(machine.succeed(command("stop", "web", "--json")))
        assert stopped["routeRemoved"] and len(stopped["containers"]) == 1, stopped
        # Caddy answers unmatched hosts with an empty 200, so check the body.
        machine.fail("curl --silent -H 'Host: app.test' http://127.0.0.1/health | grep healthy")
        machine.succeed(command("prune", "web", "--yes"))
        machine.succeed("curl --fail http://127.0.0.1:8088 | grep 'unrelated application'")
        assert machine.succeed("podman ps --filter label=io.nixploy.managed=true --format '{{.ID}}'").strip() == ""
        assert "localhost/nixploy/" not in machine.succeed("podman images --format '{{.Repository}}'")
  '';
}
