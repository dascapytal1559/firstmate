#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-idle.sh, the "is any direct report mid-turn"
# condition. Each case builds a hermetic home with task records and drives the
# check through its executable, with tmux and ps faked on PATH so the endpoint
# probe and the busy contract run their real code against a known pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-fleet-idle-tests)
IDLE="$ROOT/bin/fm-fleet-idle.sh"
EV="$ROOT/bin/fm-busy-event.sh"

# A fake tmux whose session "fmidle" holds the windows named in
# FAKE_TMUX_WINDOWS (space-separated), each running a process named claude.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  list-windows)
    for w in ${FAKE_TMUX_WINDOWS-}; do printf '%s\n' "$w"; done
    exit 0 ;;
  display-message)
    case "$*" in *pane_tty*) printf '%s\n' /dev/ttysfake; exit 0 ;; esac
    exit 0 ;;
  capture-pane) exit 0 ;;
esac
exit 1
SH
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-t ttysfake"*) printf '%s\n' '4242 4242 4242 claude'; exit 0 ;;
  *"args="*) printf '%s\n' 'claude'; exit 0 ;;
esac
PATH=/usr/bin:/bin exec ps "$@"
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/ps"

new_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state"
  printf '%s\n' "$h"
}

add_task() {  # <home> <id> <kind> [extra meta line]
  local h=$1 id=$2 kind=$3
  {
    printf 'backend=tmux\nwindow=fmidle:fm-%s\nharness=claude\nkind=%s\n' "$id" "$kind"
    [ -z "${4-}" ] || printf '%s\n' "$4"
  } > "$h/state/$id.meta"
}

busy() {  # <home> <id> <busy|idle>
  local gen
  gen=$("$EV" arm "$1/state" "$2") || fail "cannot arm the busy record for $2"
  [ "$3" = busy ] && return 0
  "$EV" apply "$1/state" "$2" "$3" --gen "$gen" --source claude-hook --event Stop >/dev/null \
    || fail "cannot apply $3 for $2"
}

export FAKE_TMUX_WINDOWS='fm-w1 fm-w2 fm-s1 fm-sm1 fm-sm2 fm-sm3 fm-sm4'

idle_rc() {  # <home> -> exit code of the check, output in $OUT
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$1" bash "$IDLE" 2>&1)
}

assert_rc() {  # <actual> <expected> <message>
  [ "$1" = "$2" ] || fail "$3 (exit $1, expected $2): ${OUT-}"
}

H=$(new_home empty)
idle_rc "$H"; rc=$?
assert_rc "$rc" 0 "a home with no direct reports is idle"
assert_contains "$OUT" "idle:" "the idle verdict is reported"
pass "an empty fleet is idle"

H=$(new_home one-busy)
add_task "$H" w1 ship; busy "$H" w1 busy
add_task "$H" w2 ship; busy "$H" w2 idle
idle_rc "$H"; rc=$?
assert_rc "$rc" 1 "one busy worker keeps the fleet active"
assert_contains "$OUT" "active: w1" "the busy worker is named"
case "$OUT" in *"active: w2"*) fail "an idle worker must not be named active: $OUT" ;; esac
pass "a busy worker keeps the fleet active and an idle one does not"

H=$(new_home all-idle)
add_task "$H" w1 ship; busy "$H" w1 idle
add_task "$H" s1 scout; busy "$H" s1 idle
idle_rc "$H"; rc=$?
assert_rc "$rc" 0 "idle workers and scouts leave the fleet idle"
pass "a fleet of idle workers is idle"

H=$(new_home unreadable)
add_task "$H" w1 ship
idle_rc "$H"; rc=$?
assert_rc "$rc" 1 "a worker with no readable busy state counts as active"
assert_contains "$OUT" "state unreadable" "the unreadable state is named"
pass "an unreadable worker counts as active"

H=$(new_home no-endpoint)
printf 'backend=tmux\nharness=claude\nkind=ship\n' > "$H/state/w1.meta"
idle_rc "$H"; rc=$?
assert_rc "$rc" 1 "a worker with no recorded endpoint counts as active"
pass "a worker with no endpoint counts as active"

H=$(new_home gone)
add_task "$H" w1 ship; busy "$H" w1 busy
OUT=$(PATH="$FAKEBIN:$PATH" FAKE_TMUX_WINDOWS='' FM_HOME="$H" bash "$IDLE" 2>&1); rc=$?
assert_rc "$rc" 0 "a worker whose endpoint is gone has no session and does not count"
pass "a gone endpoint does not block idle, even with a stale busy record"

H=$(new_home secondmates)
add_task "$H" sm1 secondmate
add_task "$H" sm2 secondmate; busy "$H" sm2 idle
add_task "$H" sm3 secondmate "remote_host=example-host"
idle_rc "$H"; rc=$?
assert_rc "$rc" 0 "idle, unreadable, and remote secondmates do not count"
add_task "$H" sm4 secondmate; busy "$H" sm4 busy
idle_rc "$H"; rc=$?
assert_rc "$rc" 1 "a secondmate inside a turn counts as active"
assert_contains "$OUT" "active: sm4" "the busy secondmate is named"
pass "secondmates count only on an exact busy verdict"

# A worker whose session is idle but whose own work still runs in its
# worktree counts as active; its agent and the agent's parent shell do not.
# Each process gets its own process group, as a real background job and a
# real agent session would.
in_group() {  # <dir> <argv>...: start argv in <dir> as a new process group, print its pid
  local dir=$1
  shift
  ( cd "$dir" && exec perl -e 'setpgrp(0, 0); exec @ARGV or die' "$@" ) >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
wait_cwd() {  # <pid> <dir>: wait until the process has started in <dir>
  for _ in $(seq 1 50); do
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | grep -qx "n$2" && return 0
    [ -d "/proc/$1" ] && [ "$(readlink "/proc/$1/cwd")" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}
H=$(new_home running-work)
WT=$(mkdir -p "$TMP_ROOT/wt1/sub" && cd -P "$TMP_ROOT/wt1" && pwd)
add_task "$H" w1 ship "worktree=$WT"; busy "$H" w1 idle
mkdir -p "$TMP_ROOT/agentbin"
# A symlink, not a copy: macOS kills a copied system binary, and both macOS
# and Linux name the process after the path it was started by.
ln -s "$(command -v sleep)" "$TMP_ROOT/agentbin/claude"
AGENT_PID=$(in_group "$WT" bash -c "\"$TMP_ROOT/agentbin/claude\" 60; true")
wait_cwd "$AGENT_PID" "$WT" || fail "the agent fixture never started"
sleep 0.3
idle_rc "$H"; rc=$?
assert_rc "$rc" 0 "an idle worker's own agent and its parent shell are not running work"
JOB_PID=$(in_group "$WT/sub" sleep 60)
wait_cwd "$JOB_PID" "$WT/sub" || fail "the background job fixture never started"
idle_rc "$H"; rc=$?
assert_rc "$rc" 1 "an idle worker with its own background job still running is active"
assert_contains "$OUT" "active: w1 - its own work is still running" "the running work is named"
kill "$JOB_PID" 2>/dev/null; wait "$JOB_PID" 2>/dev/null
idle_rc "$H"; rc=$?
assert_rc "$rc" 0 "once the background job ends the worker is idle again"
pkill -P "$AGENT_PID" 2>/dev/null; kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null
pass "an idle worker counts while its own work runs in its worktree, never for its agent"

OUT=$(FM_HOME="$TMP_ROOT/missing-home" bash "$IDLE" 2>&1); rc=$?
assert_rc "$rc" 2 "an unavailable state directory is an error, not idle"
pass "an unavailable state directory exits 2"

H=$(new_home quiet)
OUT=$(FM_HOME="$H" bash "$IDLE" -q); rc=$?
[ -z "$OUT" ] || fail "-q must print nothing: $OUT"
assert_rc "$rc" 0 "-q keeps the exit code"
pass "-q is silent"
