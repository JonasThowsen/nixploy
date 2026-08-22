{
  pkgs,
  nixployModule,
  nixployPackage,
}:

pkgs.testers.runNixOSTest {
  name = "nixploy-target-lease-broker";
  globalTimeout = 600;

  nodes.machine = {
    imports = [ nixployModule ];

    users.users = {
      deploy = {
        isNormalUser = true;
        createHome = false;
      };
      backup = {
        isNormalUser = true;
        createHome = false;
      };
      intruder = {
        isNormalUser = true;
        createHome = false;
        # This identity can connect but is absent from the broker allowlist,
        # proving the SO_PEERCRED decision rather than only filesystem denial.
        extraGroups = [ "nixploy-target-lease" ];
      };
    };

    services.nixploy.targetLease = {
      enable = true;
      package = nixployPackage;
      authority = "11111111-2222-3333-4444-555555555555";
      scopes = [
        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
      ];
      allowedUsers = [
        "deploy"
        "backup"
      ];
    };

    environment.systemPackages = [
      nixployPackage
      pkgs.coreutils
      pkgs.util-linux
    ];
    system.stateVersion = "26.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("nixploy-target-lease.service", timeout=120)

    authority = "11111111-2222-3333-4444-555555555555"
    scope_one = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    scope_two = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
    socket = "/run/nixploy-target-lease/target-lease.sock"
    client = "/run/current-system/sw/bin/nixploy-target-lease-client"

    machine.succeed("test $(stat --format='%a:%U:%G' /run/nixploy-target-lease) = 750:nixploy-target-lease:nixploy-target-lease")
    machine.succeed("test $(stat --format='%a:%U:%G' /var/lib/nixploy-target-lease) = 700:nixploy-target-lease:nixploy-target-lease")
    machine.succeed(f"test $(stat --format='%a:%U:%G' {socket}) = 660:nixploy-target-lease:nixploy-target-lease")
    machine.fail("runuser -u deploy -- touch /run/nixploy-target-lease/client-created")
    machine.fail("runuser -u deploy -- touch /var/lib/nixploy-target-lease/client-created")
    machine.succeed("test ! -e /run/nixploy-target-lease/client-created && test ! -e /var/lib/nixploy-target-lease/client-created")
    machine.succeed("id -nG deploy | grep -w nixploy-target-lease && id -nG backup | grep -w nixploy-target-lease")
    clean_probe = f"runuser -u deploy -- {client} --socket {socket} --authority {authority} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555556 --release"
    machine.succeed(f"sh -c '{clean_probe} > /tmp/clean-probe 2>&1; code=$?; cat /tmp/clean-probe; exit $code'")
    machine.succeed("grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555556' /tmp/clean-probe && grep -Fx 'V1 RELEASED' /tmp/clean-probe")

    deploy_hold = f"runuser -u deploy -- {client} --socket {socket} --authority {authority} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555555 --hold-seconds 20 --release"
    machine.succeed(f"sh -c '{deploy_hold} > /tmp/deploy-hold 2>&1 & echo $! > /tmp/deploy-hold.pid'")
    machine.wait_until_succeeds("grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555555' /tmp/deploy-hold", timeout=30)
    backup_busy = f"runuser -u backup -- {client} --socket {socket} --authority {authority} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555554"
    machine.succeed(f"sh -c '{backup_busy} > /tmp/backup-busy 2>&1; test $? -eq 1'")
    machine.succeed("cat /tmp/backup-busy; grep -Fx 'V1 BUSY' /tmp/backup-busy")
    other_scope = f"runuser -u backup -- {client} --socket {socket} --authority {authority} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555553 --release"
    machine.succeed(f"{other_scope} | grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555553'")
    machine.wait_until_succeeds("grep -Fx 'V1 RELEASED' /tmp/deploy-hold", timeout=30)
    machine.succeed(f"{backup_busy} --release | grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555554'")

    intruder = f"runuser -u intruder -- {client} --socket {socket} --authority {authority} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555552"
    machine.succeed(f"sh -c '{intruder} > /tmp/intruder 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 DENIED' /tmp/intruder")

    dirty_holder = f"runuser -u deploy -- {client} --socket {socket} --authority {authority} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555551 --hold-seconds 60"
    machine.succeed(f"sh -c '{dirty_holder} > /tmp/dirty-holder 2>&1 & echo $! > /tmp/dirty-holder.pid'")
    machine.wait_until_succeeds("grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555551' /tmp/dirty-holder", timeout=30)
    machine.succeed("kill -9 $(cat /tmp/dirty-holder.pid) || true; pkill -9 -u deploy -f nixploy-target-lease-client")
    machine.wait_until_succeeds(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty", timeout=30)
    machine.succeed(f"sh -c '{backup_busy} > /tmp/dirty 2>&1; test $? -eq 1'")
    machine.succeed("cat /tmp/dirty; grep -Fx 'V1 DIRTY' /tmp/dirty")

    restart_holder = f"runuser -u deploy -- {client} --socket {socket} --authority {authority} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555550 --hold-seconds 60"
    machine.succeed(f"sh -c '{restart_holder} > /tmp/restart-holder 2>&1 & echo $! > /tmp/restart-holder.pid'")
    machine.wait_until_succeeds("grep -Fx 'V1 READY 99999999-8888-7777-6666-555555555550' /tmp/restart-holder", timeout=30)
    machine.succeed("systemctl restart nixploy-target-lease.service")
    machine.wait_for_unit("nixploy-target-lease.service", timeout=60)
    machine.wait_until_succeeds(f"test -S {socket}", timeout=30)
    machine.succeed(f"test -f /var/lib/nixploy-target-lease/scope-{scope_two}.dirty")
    after_restart = f"runuser -u backup -- {client} --socket {socket} --authority {authority} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555549"
    machine.succeed(f"sh -c '{after_restart} > /tmp/after-restart 2>&1; test $? -eq 1'")
    machine.succeed("cat /tmp/after-restart; grep -Fx 'V1 DIRTY' /tmp/after-restart")
  '';
}
