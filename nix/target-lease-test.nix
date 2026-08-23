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
        extraGroups = [ "nixploy-target-lease" ];
      };
      backup = {
        isNormalUser = true;
        createHome = false;
        extraGroups = [ "nixploy-target-lease" ];
      };
      second-only = {
        isNormalUser = true;
        createHome = false;
        extraGroups = [ "nixploy-target-lease" ];
      };
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
        {
          scope = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
          users = [
            "deploy"
            "backup"
          ];
        }
        {
          scope = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee";
          users = [
            "backup"
            "second-only"
          ];
        }
      ];
    };

    environment.systemPackages = [
      nixployPackage
      pkgs.coreutils
      pkgs.util-linux
      pkgs.socat
    ];
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

    # A SIGKILLed broker restarts automatically and the active lease survives
    # as durable blocked evidence: no automatic restart may turn uncertainty
    # into a clean scope.
    machine.succeed("systemctl kill --signal=SIGKILL nixploy-target-lease.service || true")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    machine.wait_until_succeeds(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty", timeout=30)
    import time

    def expect_dirty(attempts=10):
        """The restarted broker must refuse the scope with V1 DIRTY."""
        for _ in range(attempts):
            machine.execute(f"sh -c '{backup_busy}' > /tmp/dirty-after-restart 2>&1")
            if "V1 DIRTY" in machine.execute("cat /tmp/dirty-after-restart")[1]:
                machine.fail("grep -Fq 'V1 READY' /tmp/dirty-after-restart")
                return
            time.sleep(2)
        raise RuntimeError("restarted broker never reported V1 DIRTY")

    expect_dirty()

    # Only explicit operator intervention resolves durable dirty evidence.
    machine.succeed("rm -f /var/lib/nixploy-target-lease/scope-*.dirty && systemctl restart nixploy-target-lease.service")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    machine.succeed(f"sh -c '{clean_probe} > /tmp/recovered-probe 2>&1'")

    def fails_closed(marker_actions):
        """Corrupt/partial/mismatched durable evidence refuses startup.

        Runs the packaged broker once directly so systemd restart pacing cannot
        mask the validation result.  A broker that starts up and has to be
        killed by timeout (exit 124) is a test failure, not a pass: refusal
        must be an explicit, prompt, nonzero exit with bounded diagnostics."""
        machine.execute("systemctl stop nixploy-target-lease.service")
        machine.succeed(marker_actions)
        broker_bin = "${nixployPackage}/bin/nixploy-target-lease-broker"
        run = (
            "start=$(date +%s); "
            f"timeout 60 {broker_bin}"
            f" --socket {socket} --state-directory /var/lib/nixploy-target-lease"
            f" --authority {authority} --identity {identity}"
            f" --scope-user {scope_one}:deploy"
            " >/tmp/fails-closed.out 2>/tmp/fails-closed.err;"
            " code=$?; end=$(date +%s);"
            ' echo "$code" >/tmp/fails-closed.code;'
            " echo $((end - start)) >/tmp/fails-closed.elapsed"
        )
        machine.succeed(f"runuser -u nixploy-target-lease -- sh -c '{run}'")
        code = machine.succeed("cat /tmp/fails-closed.code").strip()
        elapsed = int(machine.succeed("cat /tmp/fails-closed.elapsed").strip())
        try:
            if code == "124":
                raise RuntimeError(
                    "broker started despite corrupt evidence and was killed by timeout"
                )
            if code == "" or code == "0":
                raise RuntimeError(
                    f"broker accepted corrupt evidence with status {code!r}"
                )
            # Refusal is prompt even under heavy VM load: far below the 60s cap.
            if elapsed >= 30:
                raise RuntimeError(
                    f"broker took {elapsed}s to refuse startup; not prompt"
                )
            machine.succeed("test -s /tmp/fails-closed.err")
            machine.succeed("test $(stat --format=%s /tmp/fails-closed.err) -lt 100000")
            # Nothing may linger: no surviving broker process, no socket.
            machine.fail("pgrep -f '[b]in/nixploy-target-lease-broker'")
            machine.fail(f"test -S {socket}")
        finally:
            machine.execute(
                "rm -f /var/lib/nixploy-target-lease/scope-*"
                " /tmp/fails-closed.out /tmp/fails-closed.err"
                " /tmp/fails-closed.code /tmp/fails-closed.elapsed"
                " && systemctl reset-failed nixploy-target-lease.service"
            )
            machine.execute("systemctl start nixploy-target-lease.service")
            machine.wait_until_succeeds(
                "systemctl is-active --quiet nixploy-target-lease.service", timeout=60
            )

    fails_closed(f"printf 'garbage' > /var/lib/nixploy-target-lease/scope-{scope_one}.dirty")
    fails_closed(f": > /var/lib/nixploy-target-lease/scope-{scope_one}.dirty")
    fails_closed(
        f"printf 'dirty {scope_one}\\n' > /var/lib/nixploy-target-lease/scope-{scope_one}.dirty",
    )
    # Dirty marker plus clean receipt is ambiguous ownership: fail closed.
    fails_closed(
        " && ".join(
            [
                f"printf 'dirty 01234567-89ab-4cde-8fab-0123456789ab\\n' > /var/lib/nixploy-target-lease/scope-{scope_one}.dirty",
                f"printf 'clean 01234567-89ab-4cde-8fab-0123456789ab\\n' > /var/lib/nixploy-target-lease/scope-{scope_one}.clean",
            ]
        ),
    )

    # A durable clean receipt alone is honored as released state.
    machine.execute("systemctl stop nixploy-target-lease.service")
    machine.succeed(
        f"printf 'clean 99999999-8888-7777-6666-555555555558\\n' > /var/lib/nixploy-target-lease/scope-{scope_one}.clean"
        f" && chown nixploy-target-lease:nixploy-target-lease /var/lib/nixploy-target-lease/scope-{scope_one}.clean"
        f" && chmod 600 /var/lib/nixploy-target-lease/scope-{scope_one}.clean"
    )
    machine.succeed("systemctl start nixploy-target-lease.service")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    machine.succeed(f"sh -c '{clean_probe} > /tmp/clean-receipt-probe 2>&1'")
    machine.succeed(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.clean")
    machine.succeed(f"rm -f /var/lib/nixploy-target-lease/scope-{scope_one}.clean")

    # Connection-cap saturation is bounded: excess peers are dropped, the
    # broker stays live, and slots recover once the flood drains.
    machine.succeed(
        "for i in $(seq 40); do (sleep 20 | runuser -u intruder -- socat -t 25 - UNIX-CONNECT:"
        + socket
        + " >/dev/null 2>&1 &); done"
    )
    machine.sleep(2)
    machine.succeed("systemctl is-active --quiet nixploy-target-lease.service")
    machine.succeed(f"sh -c '{other_scope} > /tmp/saturated-probe 2>&1'")
    machine.succeed("pkill -f '[s]ocat -t 25' || true; sleep 1")
    machine.succeed(f"sh -c '{clean_probe} > /tmp/recovered-slots 2>&1'")

    # Issue #7: this is connection churn, not a queue-saturation claim. Each
    # socat gets EOF immediately, so the proof must not depend on arbitrary
    # scheduling delays while a timed holder happens to remain live.  The
    # explicit client release barrier makes the dirty marker authoritative:
    # after READY, it cannot be retired unless this test creates the signal.
    flood_release_signal = "/tmp/flood-holder.release"
    flood_operation = "99999999-8888-7777-6666-555555555557"
    flood_holder_script = "/tmp/flood-holder-run"
    flood_holder_pid = "/tmp/flood-holder.client.pid"
    machine.succeed(
        "cat > "
        + flood_holder_script
        + " <<'EOF'\n"
        + "echo $$ > "
        + flood_holder_pid
        + "\nexec "
        + client
        + " "
        + args
        + " --scope "
        + scope_one
        + " --operation "
        + flood_operation
        + " --release-signal "
        + flood_release_signal
        + "\nEOF\nchmod 755 "
        + flood_holder_script
    )
    flood_holder = f"runuser -u deploy -- {flood_holder_script}"
    machine.succeed(
        f"rm -f {flood_release_signal} {flood_holder_pid} /tmp/flood-holder /tmp/flood-holder.pid"
    )
    machine.succeed(
        f"sh -c '{flood_holder} > /tmp/flood-holder 2>&1 & echo $! > /tmp/flood-holder.pid'"
    )
    # READY is emitted after mark_dirty. The absent release signal prevents a
    # clean release, so seeing both files is a deterministic holder barrier.
    machine.wait_until_succeeds(
        f"test ! -e {flood_release_signal}"
        f" && test $(cat {flood_holder_pid}) -gt 1"
        f" && grep -E '^V1 READY {authority} {scope_one} {flood_operation} ' /tmp/flood-holder"
        f" && test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty",
        timeout=30,
    )
    machine.succeed(
        "for i in $(seq 50); do (timeout 5 runuser -u intruder -- socat -t 4 - UNIX-CONNECT:"
        + socket
        + " </dev/null >/dev/null 2>&1 &); done"
    )
    # During the churn an unrelated allowed peer still completes cleanly.
    machine.succeed(f"sh -c '{other_scope} > /tmp/flood-fairness 2>&1'")
    machine.succeed("grep -Fx 'V1 RELEASED' /tmp/flood-fairness")
    machine.succeed("systemctl is-active --quiet nixploy-target-lease.service")
    # Killing the barrier-held client must leave the already-observed marker in
    # place. Creating the signal here would make this assertion fail, proving
    # the check is wired to the dirty-marker invariant rather than a timeout.
    machine.succeed("pkill -9 -f '[s]ocat -t 4' || true")
    # The holder script writes the PID immediately before [exec], so this
    # kills the lease client itself rather than only its runuser wrapper.
    machine.succeed(f"kill -9 $(cat {flood_holder_pid}) || true")
    machine.succeed(f"test ! -e {flood_release_signal}")
    machine.succeed(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty")
    # The broker may need one select cycle to observe the killed holder's EOF.
    # Poll its authoritative protocol state, rather than sleeping or mistaking
    # the transient BUSY response for a missing dirty marker.
    flood_dirty_probe = (
        f"runuser -u backup -- sh -c '{client} {args} --scope {scope_one} "
        f"--operation {flood_operation}' > /tmp/flood-dirty 2>&1 || true; "
        "grep -Fx 'V1 DIRTY' /tmp/flood-dirty"
    )
    machine.wait_until_succeeds(flood_dirty_probe, timeout=30)
    machine.succeed("rm -f /var/lib/nixploy-target-lease/scope-*.dirty && systemctl restart nixploy-target-lease.service")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    # Negative control: after the intentionally removed marker permits READY,
    # the exact DIRTY assertion above fails. This proves the flood check is
    # tied to durable evidence, not merely to the client or its timeout.
    machine.fail(
        f"sh -c '{backup_busy} > /tmp/removed-marker-dirty 2>&1 && grep -Fx \"V1 DIRTY\" /tmp/removed-marker-dirty'"
    )
    machine.succeed(f"sh -c '{clean_probe} > /tmp/final-probe 2>&1'")
    machine.succeed("systemctl is-active --quiet nixploy-target-lease.service")
  '';
}
