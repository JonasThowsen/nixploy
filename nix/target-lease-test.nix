{
  pkgs,
  nixployModule,
  nixployPackage,
  leaseHolder,
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
    machine.succeed("kill -9 $(cat /tmp/dirty-holder.pid) && pkill -9 -u deploy -f nixploy-target-lease-client")
    machine.wait_until_succeeds(f"test -f /var/lib/nixploy-target-lease/scope-{scope_one}.dirty", timeout=30)
    machine.succeed(f"sh -c '{backup_busy} > /tmp/dirty 2>&1; test $? -eq 1'")
    machine.succeed("grep -Fx 'V1 DIRTY' /tmp/dirty")

    # Bounded malformed input is terminal and cannot wedge the broker.
    machine.succeed(f"runuser -u intruder -- sh -c \"printf 'V1 ACQUIRE bad\\n' | socat - UNIX-CONNECT:{socket}\" > /tmp/malformed")
    machine.succeed("grep -Fx 'V1 MALFORMED' /tmp/malformed && systemctl is-active nixploy-target-lease.service")

    # A SIGKILLed broker restarts automatically and the active lease survives
    # as durable blocked evidence: no automatic restart may turn uncertainty
    # into a clean scope.
    machine.succeed("systemctl kill --signal=SIGKILL nixploy-target-lease.service")
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
    machine.succeed("pkill -f '[s]ocat -t 25' && sleep 1")
    machine.succeed(f"sh -c '{clean_probe} > /tmp/recovered-slots 2>&1'")

    # Issue #7: this is EOF churn, deliberately separate from the saturation
    # test above.  A VM-only holder in its own transient unit owns the protocol
    # session until that unit is killed; the installed client retains only its
    # normal clean-release API.
    import re

    flood_operation = "99999999-8888-7777-6666-555555555557"
    flood_unit = "nixploy-target-lease-flood-holder-99999999-8888-7777-6666-555555555557"
    flood_service = f"{flood_unit}.service"
    flood_output = "/tmp/flood-holder.stdout"
    flood_error = "/tmp/flood-holder.stderr"
    flood_holder = "${leaseHolder}/bin/nixploy-target-lease-test-holder"
    flood_marker = f"/var/lib/nixploy-target-lease/scope-{scope_one}.dirty"
    flood_clean = f"/var/lib/nixploy-target-lease/scope-{scope_one}.clean"
    machine.succeed(f"rm -f {flood_output} {flood_error}")
    machine.succeed(
        f"systemd-run --unit={flood_unit} --service-type=exec "
        "--property=User=deploy "
        f"--property=StandardOutput=file:{flood_output} "
        f"--property=StandardError=file:{flood_error} "
        f"{flood_holder} {args} --scope {scope_one} --operation {flood_operation}"
    )
    machine.wait_until_succeeds(
        f"grep -E '^V1 READY {authority} {scope_one} {flood_operation} "
        f"[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}} {identity}$' "
        f"{flood_output}",
        timeout=30,
    )
    flood_ready = machine.succeed(f"cat {flood_output}")
    ready_match = re.fullmatch(
        rf"V1 READY {authority} {scope_one} {flood_operation} "
        rf"([0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}}) {identity}\n",
        flood_ready,
    )
    if ready_match is None:
        raise RuntimeError(f"holder did not emit one exact READY: {flood_ready!r}")
    machine.succeed(
        f"test \"$(stat --format='%F:%a:%U:%G' {flood_marker})\" "
        "= 'regular file:600:nixploy-target-lease:nixploy-target-lease'"
    )
    flood_marker_content = machine.succeed(f"cat {flood_marker}")
    marker_match = re.fullmatch(
        r"dirty ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\n",
        flood_marker_content,
    )
    if marker_match is None:
        raise RuntimeError(f"dirty marker had unexpected exact content: {flood_marker_content!r}")
    flood_generation = marker_match.group(1)
    machine.succeed(f"printf 'dirty {flood_generation}\\n' | cmp - {flood_marker}")
    machine.succeed(f"test ! -e {flood_clean}")

    machine.succeed(
        "for i in $(seq 50); do (timeout 5 runuser -u intruder -- socat -t 4 - UNIX-CONNECT:"
        + socket
        + " </dev/null >/dev/null 2>&1 &); done"
    )
    # This control request proves an allowed peer can still complete cleanly
    # while scope_one remains held through the EOF churn.
    machine.succeed(f"sh -c '{other_scope} > /tmp/flood-fairness 2>&1'")
    machine.succeed("grep -Fx 'V1 RELEASED' /tmp/flood-fairness")
    machine.succeed("systemctl is-active --quiet nixploy-target-lease.service")
    machine.wait_until_succeeds("! pgrep -f '[s]ocat -t 4'", timeout=30)

    # Bind MainPID to the exact VM-only helper, request, and transient-unit
    # cgroup immediately before SIGKILL.  Record the kernel start time as part
    # of the identity proof: a later PID cannot silently stand in for this
    # holder.  This neither targets a wrapper nor relies on a pidfile that
    # could become stale or be reused.
    flood_pid_file = "/tmp/flood-holder.pid"
    flood_starttime_file = "/tmp/flood-holder.starttime"
    flood_cgroup_file = "/tmp/flood-holder.cgroup"
    machine.succeed(
        f"pid=$(systemctl show --property=MainPID --value {flood_service}); "
        "test \"$pid\" -gt 1; "
        f"test \"$(readlink -f /proc/$pid/exe)\" = {flood_holder}; "
        f"tr '\\000' ' ' < /proc/$pid/cmdline | grep -F -- "
        f"'{flood_holder} --socket {socket} --authority {authority} --identity {identity} --scope {scope_one} --operation {flood_operation}'; "
        f"cgroup=$(awk -F: '$1 == 0 {{ print $3 }}' /proc/$pid/cgroup); "
        f"test \"$cgroup\" = /system.slice/{flood_service}; "
        "test -r /proc/$pid/stat; "
        "starttime=$(awk '{ print $22 }' /proc/$pid/stat); "
        "test -n \"$starttime\"; printf '%s\\n' \"$starttime\" | grep -Eq '^[0-9]+$'; "
        f"grep -Fx \"$pid\" /sys/fs/cgroup$cgroup/cgroup.procs; "
        f"printf '%s\\n' \"$pid\" > {flood_pid_file}; "
        f"printf '%s\\n' \"$starttime\" > {flood_starttime_file}; "
        f"printf '%s\\n' \"$cgroup\" > {flood_cgroup_file}; "
        f"systemctl kill --kill-who=main --signal=SIGKILL {flood_service}"
    )

    def assert_flood_holder_absent(phase):
        """Reject PID reuse rather than ever treating a new process as holder."""
        pid = machine.succeed(f"cat {flood_pid_file}").strip()
        expected_starttime = machine.succeed(f"cat {flood_starttime_file}").strip()
        if machine.execute(f"test ! -e /proc/{pid}")[0] != 0:
            observed_starttime = machine.succeed(
                f"awk '{{ print $22 }}' /proc/{pid}/stat"
            ).strip()
            raise RuntimeError(
                f"{phase}: captured holder PID {pid} was reused "
                f"(recorded starttime {expected_starttime}, observed {observed_starttime})"
            )

    def assert_flood_holder_reaped(phase):
        # Every later observation of the captured PID begins by requiring it
        # absent, so PID reuse cannot weaken this proof.
        assert_flood_holder_absent(phase)
        main_pid = machine.succeed(
            f"systemctl show --property=MainPID --value {flood_service}"
        ).strip()
        if main_pid != "0":
            raise RuntimeError(f"{phase}: transient unit MainPID was {main_pid}, not 0")
        cgroup = machine.succeed(f"cat {flood_cgroup_file}").strip()
        machine.succeed(
            f"test ! -e /sys/fs/cgroup{cgroup}/cgroup.procs || "
            f"test ! -s /sys/fs/cgroup{cgroup}/cgroup.procs"
        )

    machine.wait_until_succeeds(
        f"test \"$(systemctl show --property=ActiveState --value {flood_service})\" = failed",
        timeout=30,
    )
    machine.wait_until_succeeds(
        f"pid=$(cat {flood_pid_file}); "
        f"cgroup=$(cat {flood_cgroup_file}); "
        f"test \"$(systemctl show --property=MainPID --value {flood_service})\" = 0; "
        "test ! -e /proc/$pid; "
        "test ! -e /sys/fs/cgroup$cgroup/cgroup.procs || "
        "test ! -s /sys/fs/cgroup$cgroup/cgroup.procs",
        timeout=30,
    )
    assert_flood_holder_reaped("immediately after SIGKILL")
    machine.succeed(
        f"test \"$(systemctl show --property=ExecMainCode --value {flood_service})\" = 2"
    )
    machine.succeed(
        f"test \"$(systemctl show --property=ExecMainStatus --value {flood_service})\" = 9"
    )

    # Restart from disk-only state after the exact holder died.  The marker's
    # bytes and metadata must remain the original durable evidence.
    machine.succeed("systemctl stop nixploy-target-lease.service")
    machine.wait_until_succeeds(
        "test \"$(systemctl show --property=ActiveState --value nixploy-target-lease.service)\" = inactive",
        timeout=30,
    )
    machine.succeed("systemctl start nixploy-target-lease.service")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    machine.succeed(
        f"test \"$(stat --format='%F:%a:%U:%G' {flood_marker})\" "
        "= 'regular file:600:nixploy-target-lease:nixploy-target-lease'"
    )
    machine.succeed(f"printf 'dirty {flood_generation}\\n' | cmp - {flood_marker}")
    flood_dirty_status, _ = machine.execute(
        f"runuser -u backup -- {client} {args} --scope {scope_one} "
        f"--operation 99999999-8888-7777-6666-555555555558 "
        "> /tmp/flood-dirty.stdout 2> /tmp/flood-dirty.stderr"
    )
    if flood_dirty_status != 1:
        raise RuntimeError(f"disk-derived dirty probe exited {flood_dirty_status}, expected 1")
    machine.succeed("printf 'V1 DIRTY\\n' | cmp - /tmp/flood-dirty.stdout")

    # The backup control proves the client and broker are still usable before
    # the negative control deliberately removes the durable marker.
    backup_control = f"runuser -u backup -- {client} {args} --scope {scope_two} --operation 99999999-8888-7777-6666-555555555559"
    backup_control_status, _ = machine.execute(
        f"{backup_control} > /tmp/flood-backup-control.stdout 2> /tmp/flood-backup-control.stderr"
    )
    if backup_control_status != 0:
        raise RuntimeError(f"backup control exited {backup_control_status}, expected 0")
    backup_control_output = machine.succeed("cat /tmp/flood-backup-control.stdout")
    if re.fullmatch(
        rf"V1 READY {authority} {scope_two} 99999999-8888-7777-6666-555555555559 "
        rf"[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}} {identity}\nV1 RELEASED\n",
        backup_control_output,
    ) is None:
        raise RuntimeError(f"backup control was not exact READY+RELEASED: {backup_control_output!r}")

    machine.succeed("systemctl stop nixploy-target-lease.service")
    machine.wait_until_succeeds(
        "test \"$(systemctl show --property=ActiveState --value nixploy-target-lease.service)\" = inactive",
        timeout=30,
    )
    machine.succeed(f"rm {flood_marker}")
    machine.succeed("systemctl start nixploy-target-lease.service")
    machine.wait_until_succeeds("systemctl is-active --quiet nixploy-target-lease.service", timeout=60)
    removed_marker_status, _ = machine.execute(
        f"runuser -u backup -- {client} {args} --scope {scope_one} "
        "--operation 99999999-8888-7777-6666-555555555560 "
        "> /tmp/removed-marker-probe.stdout 2> /tmp/removed-marker-probe.stderr"
    )
    if removed_marker_status != 0:
        raise RuntimeError(
            f"removed-marker client exited {removed_marker_status}, expected protocol success"
        )
    removed_marker_output = machine.succeed("cat /tmp/removed-marker-probe.stdout")
    if removed_marker_output == "V1 DIRTY\\n":
        raise RuntimeError("removed-marker negative control still reported V1 DIRTY")
    if re.fullmatch(
        rf"V1 READY {authority} {scope_one} 99999999-8888-7777-6666-555555555560 "
        rf"[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}} {identity}\nV1 RELEASED\n",
        removed_marker_output,
    ) is None:
        raise RuntimeError(
            f"removed-marker response was not exact READY+RELEASED: {removed_marker_output!r}"
        )
    machine.succeed("systemctl is-active --quiet nixploy-target-lease.service")
    # The complete disk-only/restart proof window must never observe the old
    # holder again, even if the VM recycles numeric PIDs under load.
    assert_flood_holder_reaped("at final test end")
  '';
}
