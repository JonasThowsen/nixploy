# This wrapper keeps an external command in its own process group. Closing the
# Erlang port or terminating this wrapper also terminates the whole group.
set -u

setsid_executable=$1
shift

child_pid=""
monitor_pid=""

terminate_child() {
  if [ -n "$child_pid" ]; then
    kill -TERM -- "-$child_pid" 2>/dev/null || true
  fi
}

trap terminate_child TERM INT HUP

"$setsid_executable" "$@" </dev/null &
child_pid=$!

(
  while IFS= read -r _; do :; done
  kill -TERM -- "-$child_pid" 2>/dev/null || true
) &
monitor_pid=$!

wait "$child_pid"
status=$?

kill "$monitor_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true
trap - TERM INT HUP

exit "$status"
