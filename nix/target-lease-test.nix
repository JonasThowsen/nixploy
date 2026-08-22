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
      deploy = { isNormalUser = true; createHome = false; extraGroups = [ "nixploy-target-lease" ]; };
      backup = { isNormalUser = true; createHome = false; extraGroups = [ "nixploy-target-lease" ]; };
      second-only = { isNormalUser = true; createHome = false; extraGroups = [ "nixploy-target-lease" ]; };
      intruder = {
        isNormalUser = true;
        createHome = false;
        # Can connect but is absent from every broker ACL, proving SO_PEERCRED.
        extraGroups = [ "nixploy-target-lease" ];
      };
    };

    services.nixploy.targetLease = {
      enable = true;
      package = nixployPackage;
      authority = "11111111-2222-3333-4444-555555555555";
      identity = "12345678-1234-4234-9234-123456789abc";
      scopes = [
        { scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; users = [ "deploy" "backup" ]; }
        { scope = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"; users = [ "backup" "second-only" ]; }
      ];
    };

    environment.systemPackages = [ nixployPackage pkgs.coreutils pkgs.util-linux pkgs.socat ];
    system.stateVersion = "26.05";
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("nixploy-target-lease.service", timeout=120)

    authority = "11111111-2222-3333-4444-555555555555"
    identity = "12345678-1234-4234-9234-123456789abc"
    scope_one = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    scope_two = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
    socket = "/run/nixploy-target-lease/target-lease.sock"
    client = "/run/current-system/sw/bin/nixploy-target-lease-client"
    args = f"--socket {socket} --authority {authority} --identity {identity}"

    machine.succeed("test $(stat --format='%a:%U:%G' /run/nixploy-target-lease) = 750:nixploy-target-lease:nixploy-target-lease")
    machine.succeed("test $(stat --format='%a:%U:%G' /var/lib/nixploy-target-lease) = 700:nixploy-target-lease:nixploy-target-lease")
    machine.succeed(f"test $(stat --format='%a:%U:%G' {socket}) = 660:nixploy-target-lease:nixploy-target-lease")
    machine.fail("runuser -u deploy -- touch /run/nixploy-target-lease/client-created")
    machine.fail("runuser -u deploy -- touch /var/lib/nixploy-target-lease/client-created")
    machine.succeed("id -nG deploy | grep -w nixploy-target-lease && id -nG backup | grep -w nixploy-target-lease")

    clean_probe = f"runuser -u deploy -- {client} {args} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555556"
    machine.succeed(f"sh -c '{clean_probe} > /tmp/clean-probe 2>&1; code=$?; cat /tmp/clean-probe; exit $code'")
    machine.succeed(f"grep -E '^V1 READY {authority} {scope_one} 99999999-8888-7777-6666-555555555556 [0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}} {identity}$' /tmp/clean-probe")
    machine.succeed("! grep -F '99999999-8888-7777-6666-555555555556 99999999-8888-7777-6666-555555555556' /tmp/clean-probe && grep -Fx 'V1 RELEASED' /tmp/clean-probe")

    deploy_hold = f"runuser -u deploy -- {client} {args} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555555 --hold-seconds 20"
    machine.succeed(f"sh -c '{deploy_hold} > /tmp/deploy-hold 2>&1 & echo $! > /tmp/deploy-hold.pid'")
    machine.wait_until_succeeds(f"grep -E '^V1 READY {authority} {scope_one} 99999999-8888-7777-6666-555555555555 ' /tmp/deploy-hold", timeout=30)
    backup_busy = f"runuser -u backup -- {client} {args} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555554"
    machine.succeed(f"sh -c '{backup_busy} > /tmp/backup-busy 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 BUSY' /tmp/backup-busy")
    other_scope = f"runuser -u backup -- {client} {args} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555553"
    machine.succeed(f"sh -c '{other_scope} > /tmp/other-scope 2>&1; code=$?; cat /tmp/other-scope; exit $code'")
    machine.succeed(f"grep -E '^V1 READY {authority} {scope_two} 99999999-8888-7777-6666-555555555553 ' /tmp/other-scope && grep -Fx 'V1 RELEASED' /tmp/other-scope")
    machine.wait_until_succeeds("grep -Fx 'V1 RELEASED' /tmp/deploy-hold", timeout=30)

    second_denied = f"runuser -u second-only -- {client} {args} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555552"
    machine.succeed(f"sh -c '{second_denied} > /tmp/second-denied 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 DENIED' /tmp/second-denied")
    second_scope = f"runuser -u second-only -- {client} {args} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555552"
    machine.succeed(f"sh -c '{second_scope} > /tmp/second-scope 2>&1; code=$?; cat /tmp/second-scope; exit $code'")
    machine.succeed("grep -Fx 'V1 RELEASED' /tmp/second-scope")

    intruder = f"runuser -u intruder -- {client} {args} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555551"
    machine.succeed(f"sh -c '{intruder} > /tmp/intruder 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 DENIED' /tmp/intruder")

    # Default clients cleanly release; killing this long-held default client
    # before release leaves a durable dirty marker.  This is not a power-loss claim.
    dirty_holder = f"runuser -u deploy -- {client} {args} --scope {scope_one} --operation 99999999-8888-7777-6666-555555555550 --hold-seconds 60"
    machine.succeed(f"sh -c '{dirty_holder} > /tmp/dirty-holder 2>&1 & echo $! > /tmp/dirty-holder.pid'")
    machine.wait_until_succeeds(f"grep -E '^V1 READY {authority} {scope_one} 99999999-8888-7777-6666-555555555550 ' /tmp/dirty-holder", timeout=30)
    machine.succeed("kill -9 $(cat /tmp/dirty-holder.pid) || true; pkill -9 -u deploy -f nixploy-target-lease-client")
    machine.wait_until_succeeds(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty", timeout=30)
    machine.succeed(f"sh -c '{backup_busy} > /tmp/dirty 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 DIRTY' /tmp/dirty")

    # Bounded malformed input is terminal and cannot wedge the broker.
    machine.succeed(f"runuser -u intruder -- sh -c \"printf 'V1 ACQUIRE bad\\n' | socat - UNIX-CONNECT:{socket}\" > /tmp/malformed")
    machine.succeed("grep -Fx 'V1 MALFORMED' /tmp/malformed && systemctl is-active nixploy-target-lease.service")
  '';
}
