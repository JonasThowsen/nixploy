# This wrapper keeps an external command in its own process group. Explicit
# termination of the wrapper, or EOF from its owning Erlang port, terminates the
# whole command group with a bounded TERM/KILL sequence.
set -u

setsid_executable=$1
shift

child_pid=""
monitor_pid=""

terminate_child() {
  if [ -z "$child_pid" ]; then
    return
  fi

  kill -TERM -- "-$child_pid" 2>/dev/null || true

  attempts=0
  while kill -0 "$child_pid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done

  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL -- "-$child_pid" 2>/dev/null || true
  fi
}

trap terminate_child TERM INT HUP

"$setsid_executable" "$@" </dev/null &
child_pid=$!

# Bash redirects stdin of asynchronous commands to /dev/null unless an explicit
# redirection is supplied. Preserve the port pipe here; otherwise this monitor
# races every command and can terminate it immediately.
(
  while IFS= read -r _; do :; done
  kill -TERM "$PPID" 2>/dev/null || true
) <&0 &
monitor_pid=$!

wait "$child_pid"
status=$?

kill "$monitor_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true
trap - TERM INT HUP

exit "$status"
