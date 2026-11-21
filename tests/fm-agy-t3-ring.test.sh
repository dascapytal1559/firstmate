#!/usr/bin/env bash
# Behavior tests for the fork's Antigravity T3 ring (bin/fm-agy-t3-ring.sh,
# FORK.md "Antigravity main in T3 Code"): inside a T3 Code thread the Antigravity
# Stop hook (.agents/hooks.json -> bin/fm-turnend-guard-agy.sh) ends the turn at
# once and one detached waiter rings the thread on a real wake.
#
# Each case home is a primary checkout with a copy of bin/ whose arm or host is
# a fixture. The session is a fake process named `antigravity`, the name T3
# Code's managed install gives the Antigravity CLI, that holds the fleet lock,
# runs the tracked Stop registration from .agents/ for each turn the case asks
# for, and stays alive until the case ends it, so the waiter's anchor lives as
# long as the session does. T3 Code is tests/t3-fake-server.mjs, where each turn
# is a run that is active while its Stop hook runs, as T3 holds Antigravity's
# ACP prompt open until the hook returns; a case can keep it active after the
# hook, as the prompt still finishing.
# shellcheck disable=SC2016 # single-quoted scripts expand inside the fake session
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

for tool in node jq perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool absent"; exit 0; }
done
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: no C compiler for the fake antigravity process"; exit 0; }

unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI PI_CODING_AGENT FM_PI_HARNESS FM_OMP_HARNESS GROK_AGENT AGENT \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE T3CODE_THREAD_ID

TMP_ROOT=$(fm_test_tmproot fm-agy-t3-ring)
fm_git_identity fmtest fmtest@example.invalid
THREAD=thread-fm

# The session process: a compiled binary at the path shape T3 Code installs,
# so `ps` reports it as .../antigravity, forking bash for its script.
AGY_DIR="$TMP_ROOT/tools/antigravity-acp/test-arch/versions/abc123"
mkdir -p "$AGY_DIR"
cat > "$TMP_ROOT/fake-antigravity.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 72;
}
C
"$CC_BIN" -o "$AGY_DIR/antigravity" "$TMP_ROOT/fake-antigravity.c" \
  || fail "could not build the fake antigravity process"
FAKE_AGY="$AGY_DIR/antigravity"

t3_fake_start "$TMP_ROOT/server"
SESSIONS="$TMP_ROOT/sessions"
: > "$SESSIONS"
cleanup() {
  local home pid
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    : > "$home/end" 2>/dev/null || true
    pid=$(jq -r '.pid // empty' "$home/state/.agy-t3-ring.json" 2>/dev/null)
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done < "$SESSIONS"
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

# The session's script. Turn N runs once $FM_HOME/turn.N exists: the tracked
# Stop registration, from .agents/, with the payload of a normal turn end; its
# stdout lands in out.N and its exit status in rc.N.
SESSION_SCRIPT='
  printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
  printf "%s\n" "$PPID" > "$FM_HOME/session-pid"
  n=1
  while [ ! -e "$FM_HOME/end" ]; do
    if [ -e "$FM_HOME/turn.$n" ]; then
      printf "{\"conversationId\":\"c-1\",\"executionNum\":0,\"terminationReason\":\"NO_TOOL_CALL\"}" \
        | ( cd "$FM_HOME/.agents" && eval "$STOP_CMD" ) > "$FM_HOME/out.$n" 2> "$FM_HOME/err.$n"
      printf "%s\n" "$?" > "$FM_HOME/rc.$n"
      n=$((n + 1))
    fi
    sleep 0.05
  done
'
STOP_CMD=$(jq -r '[.[] | .Stop // empty | .[].command | select(contains("fm-turnend-guard-agy.sh"))][0] // empty' \
  "$ROOT/.agents/hooks.json")
[ -n "$STOP_CMD" ] || fail "the Antigravity Stop registration is missing from .agents/hooks.json"

# An arm fixture speaking bin/fm-watch-arm.sh's output contract. Every run
# appends its pid to state/arm-ran. <kind>:
#   held     start, then close actionably once state/arm-release exists
#   instant  start and close actionably at once
#   pending  close actionably at once, before confirming a cycle: a wake
#            already pending at turn end
#   silent-then-instant  the first run prints nothing and waits; later runs are instant
write_arm() {  # <home> <kind>
  cat > "$1/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" >> "\$FM_HOME/state/arm-ran"
kind=$2
if [ "\$kind" = silent-then-instant ] && [ "\$(wc -l < "\$FM_HOME/state/arm-ran" | tr -d ' ')" = 1 ]; then
  trap 'printf "%s\n" "\$\$" >> "\$FM_HOME/state/arm-stopped"; exit 143' TERM
  while :; do sleep 0.05; done
fi
trap 'printf "%s\n" "\$\$" >> "\$FM_HOME/state/arm-stopped"; exit 143' TERM
[ "\$kind" = pending ] || printf 'watcher: started pid=%s (beacon fresh)\n' "\$\$"
if [ "\$kind" = held ]; then
  while [ ! -e "\$FM_HOME/state/arm-release" ]; do sleep 0.05; done
fi
printf 'signal: state/task1.status\n'
exit 0
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

# A supervision host fixture: records its primary pin and lock binding, starts,
# then hands one wake back once state/arm-release exists.
write_host() {  # <home>
  cat > "$1/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\n' "${FM_SUPERVISION_HOST_PRIMARY:-}" "${FM_SUPERVISION_HOST_LOCK_PID:-}" \
  "${FM_SUPERVISION_HOST_LOCK_IDENTITY:-}" "$*" >> "$FM_HOME/state/host-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.05; done
printf 'stale: fixture needs a look\n'
printf 'supervision-host: the supervision session could not take this wake: fixture; this wake is yours\n'
exit 0
SH
  chmod +x "$1/bin/fm-supervision-host.sh"
}

# make_case <name> <arm-kind>: a primary checkout home with a T3 thread, a
# credential, and one task to supervise. Sets HOME_DIR.
make_case() {
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/.agents"
  git init -q -b main "$HOME_DIR"
  git -C "$HOME_DIR" commit -q --allow-empty -m init
  : > "$HOME_DIR/AGENTS.md"
  cp -R "$ROOT/bin" "$HOME_DIR/bin"
  cp "$ROOT/.agents/hooks.json" "$HOME_DIR/.agents/hooks.json"
  write_arm "$HOME_DIR" "$2"
  : > "$HOME_DIR/state/task1.meta"
  t3_fake_case "$HOME_DIR/t3"
  t3_fake_set 'w.threads = { "thread-fm": { threadId: "thread-fm", projectId: "proj-1", status: "completed",
    activeRunId: null, archived: false, worktreePath: null, pendingRequestCount: 0,
    providerInstanceId: "antigravity", runtimeMode: "full-access", parentThreadId: null, items: [], runs: [] } }'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  printf '%s\n' "$HOME_DIR" >> "$SESSIONS"
}

# start_session <home> [env...]: the fake antigravity session in the background,
# inside T3 Code's thread unless an env argument empties T3CODE_THREAD_ID.
start_session() {
  local home=$1
  shift
  env T3CODE_THREAD_ID="$THREAD" FM_HOME="$home" STOP_CMD="$STOP_CMD" FM_AGY_PARK_POLL=1 \
    FM_AGY_T3_RING_SEND_BACKOFF=0 "$@" "$FAKE_AGY" -c "$SESSION_SCRIPT" > /dev/null 2>&1 &
  wait_for 100 test -s "$home/session-pid" || fail "the fake antigravity session did not start"
}

# run_begin <n> / run_end <n>: turn n's run on the fake thread, active from
# before its Stop hook until run_end. A send to the thread while it is active
# is steered into it, as T3 steers Antigravity's open prompt.
run_begin() {
  FM_TURN_RUN="run:turn-$1" t3_fake_set 'const t = w.threads["thread-fm"]; const id = process.env.FM_TURN_RUN;
    t.runs = [{ runId: id, status: "running", ordinal: (t.runs || []).length + 1, startedAt: new Date().toISOString(), completedAt: null }, ...(t.runs || [])];
    t.activeRunId = id; t.latestRunId = id; t.status = "running";'
}
run_end() {
  FM_TURN_RUN="run:turn-$1" t3_fake_set 'const t = w.threads["thread-fm"]; const id = process.env.FM_TURN_RUN;
    for (const r of t.runs || []) if (r.runId === id) { r.status = "completed"; r.completedAt = new Date().toISOString(); }
    const a = (t.runs || []).find((r) => r.status === "running");
    t.activeRunId = a ? a.runId : null; t.status = a ? "running" : "completed";'
}

# turn_open <home> <n>: end turn n with its run still active, and wait for its
# Stop hook to return.
turn_open() {
  run_begin "$2"
  : > "$1/turn.$2"
  wait_for 600 test -s "$1/rc.$2" || fail "turn $2's Stop hook did not return within 60s"
}

# turn <home> <n>: end turn n and wait for its Stop hook to return; its run
# ends with the hook.
turn() {
  turn_open "$1" "$2"
  run_end "$2"
}

end_session() {
  : > "$1/end"
}

wait_for() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# descends_from <pid> <ancestor>: true when <ancestor> is in <pid>'s parent chain.
descends_from() {
  local pid=$1 i=0
  while [ "$i" -lt 32 ]; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|0|1) return 1 ;; esac
    [ "$pid" = "$2" ] && return 0
    i=$((i + 1))
  done
  return 1
}

ring_field() { jq -r --arg k "$2" '.[$k] // empty | tostring' "$1/state/.agy-t3-ring.json" 2>/dev/null; }
ring_outcome_is() { [ "$(ring_field "$1" outcome)" = "$2" ]; }
send_count() { t3_fake_calls t3_thread_send | grep -c . || true; }
sends_are() { [ "$(send_count)" = "$1" ]; }
failures_at_least() { [ "$(ring_field "$1" failures)" -ge "$2" ] 2>/dev/null; }
# How T3 took the one accepted send: started, steered, or queued.
send_delivery() { jq -r '.delivery // empty' "$1"/state/t3code-sends/*.accepted 2>/dev/null; }
arm_runs() { wc -l < "$1/state/arm-ran" 2>/dev/null | tr -d ' '; }

# The record path an operational doorbell names, per bin/fm-operational-input.sh.
doorbell_record() {  # <message>
  printf '%s' "$1" | sed -n "s/^: Firstmate operational input waiting: read '\\(.*\\)' and handle its contents as Firstmate operational input\\.\$/\\1/p"
}

# The body of the one wake rung so far, opened through this home's own inbox.
rung_body() {  # <home>
  local message record
  message=$(t3_fake_calls t3_thread_send | jq -r .message)
  [ "$(printf '%s' "$message" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" = watcher ] \
    || fail "the rung message must be a watcher doorbell: $message"
  record=$(doorbell_record "$message")
  FM_HOME="$1" "$ROOT/bin/fm-operational-input.sh" open "$record" \
    || fail "the doorbell's record must sit in this home's own operational inbox: $record"
}

test_t3_turn_ends_at_once_and_the_waiter_rings_the_wake() {
  local session waiter args body
  make_case ring-wake held
  start_session "$HOME_DIR"
  session=$(cat "$HOME_DIR/session-pid")
  turn "$HOME_DIR" 1
  expect_code 0 "$(cat "$HOME_DIR/rc.1")" "the Stop hook must succeed"
  assert_equals "{}" "$(cat "$HOME_DIR/out.1")" "inside T3 the Stop hook must end the turn at once, not park it"
  ring_outcome_is "$HOME_DIR" waiting || fail "a waiter must own the cycle when the turn ends: $(cat "$HOME_DIR/state/.agy-t3-ring.json" 2>/dev/null)"
  assert_equals "$session" "$(ring_field "$HOME_DIR" anchor)" "the waiter must be bound to the antigravity session holding the lock"
  assert_equals "$session" "$(cat "$HOME_DIR/state/.lock")" "the antigravity session must hold the fleet lock"
  waiter=$(ring_field "$HOME_DIR" pid)
  ! descends_from "$waiter" "$session" || fail "the waiter must be detached from the agent's process tree"
  sends_are 0 || fail "nothing may be rung before a wake"

  turn "$HOME_DIR" 2
  assert_equals "{}" "$(cat "$HOME_DIR/out.2")" "a later turn must end at once beside the waiting waiter"
  assert_equals 1 "$(arm_runs "$HOME_DIR")" "a later turn must not start a second cycle"
  assert_equals "$waiter" "$(ring_field "$HOME_DIR" pid)" "the same waiter must keep the cycle across turns"

  : > "$HOME_DIR/state/arm-release"
  wait_for 200 sends_are 1 || fail "the wake was not rung through T3 (sends: $(send_count))"
  wait_for 100 ring_outcome_is "$HOME_DIR" delivered || fail "the waiter must record the delivery"
  args=$(t3_fake_calls t3_thread_send)
  assert_equals "$THREAD" "$(printf '%s' "$args" | jq -r .threadId)" "the wake must go to FirstMate's own thread"
  assert_equals auto "$(printf '%s' "$args" | jq -r .mode)" "the wake must start or reach the thread's turn"
  body=$(rung_body "$HOME_DIR")
  assert_contains "$body" "signal: state/task1.status" "the rung wake must carry the watcher's reason line"
  assert_contains "$body" "bin/fm-wake-drain.sh" "the rung wake must point at the durable queue"
  wait_for 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$waiter" || fail "the waiter must exit after delivering"
  assert_absent "$HOME_DIR/state/.agy-t3-ring.lock" "the waiter must release its claim"
  end_session "$HOME_DIR"
  pass "agy T3 ring: the turn ends at once, one waiter spans turns, and the wake is rung into FirstMate's thread"
}

test_outside_t3_the_hook_parks_in_place() {
  local decision
  make_case outside-t3 instant
  start_session "$HOME_DIR" T3CODE_THREAD_ID=
  turn "$HOME_DIR" 1
  decision=$(jq -r '.decision // empty' "$HOME_DIR/out.1" 2>/dev/null)
  assert_equals continue "$decision" "outside T3 the Stop hook must park in place and wake in the turn"
  assert_contains "$(jq -r .reason "$HOME_DIR/out.1")" "signal: state/task1.status" "the parked wake must carry its reason"
  assert_absent "$HOME_DIR/state/.agy-t3-ring.json" "outside T3 no waiter may start"
  sends_are 0 || fail "outside T3 nothing may be rung"
  end_session "$HOME_DIR"
  pass "agy T3 ring: outside a T3 thread the Stop hook parks in place exactly as before"
}

# A wake already pending at turn end closes the cycle while the Stop hook is
# still open: the hook hands it back as its own decision, and nothing is rung
# into the turn that is ending.
test_a_wake_pending_at_turn_end_is_handed_to_the_stop_hook() {
  make_case pending-at-turn-end pending
  start_session "$HOME_DIR"
  turn_open "$HOME_DIR" 1
  assert_equals continue "$(jq -r '.decision // empty' "$HOME_DIR/out.1")" \
    "a wake caught while the Stop hook is open must continue the turn: $(cat "$HOME_DIR/out.1")"
  assert_contains "$(jq -r .reason "$HOME_DIR/out.1")" "signal: state/task1.status" "the handed-back wake must carry its reason"
  sends_are 0 || fail "nothing may be rung into the turn that is ending (sends: $(send_count))"
  wait_for 100 ring_outcome_is "$HOME_DIR" handed-over || fail "the waiter must record that the hook took its wake: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  run_end 1
  sleep 2
  sends_are 0 || fail "a wake the hook took must not also be rung"
  assert_absent "$HOME_DIR/state/.agy-t3-ring-wake" "a handed-back wake must not stay held"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a wake pending at turn end is handed back to the Stop hook, not rung into the ending turn"
}

# A wake closing just after the hook returned waiting, while T3 still runs the
# ending turn, is held until T3 reads the thread idle and then starts a fresh
# turn.
test_a_wake_closing_as_the_turn_ends_waits_for_an_idle_thread() {
  make_case closing-at-turn-end held
  start_session "$HOME_DIR"
  turn_open "$HOME_DIR" 1
  assert_equals "{}" "$(cat "$HOME_DIR/out.1")" "the turn must end at once beside the waiting waiter"
  : > "$HOME_DIR/state/arm-release"
  wait_for 100 ring_outcome_is "$HOME_DIR" holding || fail "the waiter must hold a wake while its turn is still running: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  sleep 3
  sends_are 0 || fail "a wake must not be rung into the turn that is ending (sends: $(send_count))"
  run_end 1
  wait_for 200 sends_are 1 || fail "the held wake was not rung once the thread was idle (sends: $(send_count))"
  wait_for 100 ring_outcome_is "$HOME_DIR" delivered || fail "the waiter must record the delivery"
  assert_equals started "$(send_delivery "$HOME_DIR")" "the ring must start a fresh turn"
  assert_contains "$(rung_body "$HOME_DIR")" "signal: state/task1.status" "the rung wake must carry its reason"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a wake closing as the turn ends waits for an idle thread, then starts a fresh turn"
}

# T3 briefly unreachable: the waiter keeps the wake and retries, and the ring
# lands once T3 is back, with no turn started by hand.
test_a_send_t3_cannot_take_is_retried_until_it_lands() {
  make_case t3-down held
  start_session "$HOME_DIR" FM_AGY_T3_RING_SEND_BACKOFF=1
  turn "$HOME_DIR" 1
  assert_equals "{}" "$(cat "$HOME_DIR/out.1")" "the turn must end at once while the waiter waits"
  t3_fake_stop
  : > "$HOME_DIR/state/arm-release"
  wait_for 300 failures_at_least "$HOME_DIR" 2 || fail "the waiter must keep retrying while T3 is unreachable: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  ring_outcome_is "$HOME_DIR" holding || fail "the waiter must still hold the wake: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  t3_fake_restart "$TMP_ROOT/server"
  wait_for 600 sends_are 1 || fail "the wake was not rung once T3 came back (sends: $(send_count))"
  wait_for 100 ring_outcome_is "$HOME_DIR" delivered || fail "the waiter must record the delivery: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  assert_equals started "$(send_delivery "$HOME_DIR")" "the late ring must start a fresh turn"
  assert_absent "$HOME_DIR/state/.agy-t3-ring-fallback" "a ring that landed must not latch the blocking park"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a ring T3 cannot take is retried with backoff and lands once T3 is back"
}

# T3 refusing every try: the waiter gives up at its bound, keeps the wake with a
# notice, and latches the blocking park. Nothing can start a turn then, so the
# case starts turn 2 by hand, standing in for the captain's next message.
test_a_ring_t3_keeps_refusing_gives_up_visibly() {
  local session reason
  make_case send-refused held
  t3_fake_set 'w.tokens = []'
  start_session "$HOME_DIR"
  session=$(cat "$HOME_DIR/session-pid")
  turn "$HOME_DIR" 1
  assert_equals "{}" "$(cat "$HOME_DIR/out.1")" "the turn must end at once while the waiter waits"
  : > "$HOME_DIR/state/arm-release"
  wait_for 600 ring_outcome_is "$HOME_DIR" delivery-failed || fail "a ring T3 keeps refusing must give up: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  assert_equals 10 "$(ring_field "$HOME_DIR" failures)" "the waiter must give up at its stated bound of ten tries"
  assert_equals "$session" "$(sed -n 1p "$HOME_DIR/state/.agy-t3-ring-fallback")" "giving up must latch this session to the blocking park"
  assert_contains "$(cat "$HOME_DIR/state/.agy-t3-ring-wake")" "GAVE UP" "the held wake must record that the ring gave up"
  write_arm "$HOME_DIR" instant
  turn "$HOME_DIR" 2
  assert_equals continue "$(jq -r '.decision // empty' "$HOME_DIR/out.2")" "the next Stop hook must hand back the wake that waited"
  reason=$(jq -r .reason "$HOME_DIR/out.2")
  assert_contains "$reason" "GAVE UP" "the next Stop hook must say the ring gave up"
  assert_contains "$reason" "signal: state/task1.status" "the next Stop hook must carry the wake that waited"
  assert_absent "$HOME_DIR/state/.agy-t3-ring-wake" "the handed-back wake must not stay held"
  turn "$HOME_DIR" 3
  assert_contains "$(jq -r .reason "$HOME_DIR/out.3")" "This Stop hook owns watcher continuity" "a latched session must then park in place"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a ring T3 keeps refusing gives up at its bound, and the next Stop hook hands back the wake with the notice"
}

test_the_waiter_stands_down_when_the_lock_moves() {
  local waiter other
  make_case lock-moves held
  start_session "$HOME_DIR"
  turn "$HOME_DIR" 1
  ring_outcome_is "$HOME_DIR" waiting || fail "a waiter must own the cycle"
  waiter=$(ring_field "$HOME_DIR" pid)
  sleep 30 &
  other=$!
  printf '%s\n' "$other" > "$HOME_DIR/state/.lock"
  wait_for 100 ring_outcome_is "$HOME_DIR" stood-down || fail "a waiter whose session lost the lock must stand down"
  wait_for 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$waiter" || fail "the stood-down waiter must exit"
  wait_for 50 test -s "$HOME_DIR/state/arm-stopped" || fail "the stood-down waiter must stop its cycle"
  : > "$HOME_DIR/state/arm-release"
  sleep 1
  sends_are 0 || fail "a stood-down waiter must ring nothing"
  kill "$other" 2>/dev/null || true
  end_session "$HOME_DIR"
  pass "agy T3 ring: the waiter stands down and stops its cycle when its session no longer holds the lock"
}

test_a_host_home_runs_the_host_bound_to_the_lock_holder() {
  local session row body
  make_case host held
  : > "$HOME_DIR/config/supervision-host"
  write_host "$HOME_DIR"
  start_session "$HOME_DIR"
  session=$(cat "$HOME_DIR/session-pid")
  turn "$HOME_DIR" 1
  assert_equals "{}" "$(cat "$HOME_DIR/out.1")" "the turn must end at once on a host home too"
  ring_outcome_is "$HOME_DIR" waiting || fail "the waiter must own the host's park"
  row=$(cat "$HOME_DIR/state/host-ran")
  assert_equals agy "$(printf '%s' "$row" | cut -f1)" "the host must be pinned to the agy primary"
  assert_equals "$session" "$(printf '%s' "$row" | cut -f2)" "the host must be bound to the session holding the lock"
  assert_equals "$(ring_field "$HOME_DIR" anchor_identity)" "$(printf '%s' "$row" | cut -f3)" "the host must be bound to that holder's identity"
  assert_equals park "$(printf '%s' "$row" | cut -f4)" "the host must run its park"
  [ ! -e "$HOME_DIR/state/arm-ran" ] || fail "a host home must not run the plain arm"
  : > "$HOME_DIR/state/arm-release"
  wait_for 200 sends_are 1 || fail "the host's hand-back was not rung (sends: $(send_count))"
  body=$(rung_body "$HOME_DIR")
  assert_contains "$body" "stale: fixture needs a look" "the rung wake must carry the close"
  assert_contains "$body" "supervision-host: the supervision session could not take this wake" "the rung wake must carry the host's line"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a host home runs the host's park bound to the lock holder and rings its hand-back"
}

test_an_unconfirmed_start_falls_back_to_the_blocking_park() {
  local session
  make_case unconfirmed silent-then-instant
  start_session "$HOME_DIR" FM_AGY_T3_RING_START_TIMEOUT=2
  session=$(cat "$HOME_DIR/session-pid")
  turn "$HOME_DIR" 1
  assert_equals continue "$(jq -r '.decision // empty' "$HOME_DIR/out.1")" \
    "a waiter that never confirms must leave the turn to the blocking park, which delivers the wake"
  wait_for 50 test -s "$HOME_DIR/state/arm-stopped" || fail "the unconfirmed waiter's cycle must be stopped"
  ring_outcome_is "$HOME_DIR" stood-down || fail "the unconfirmed waiter must be stopped: $(cat "$HOME_DIR/state/.agy-t3-ring.json")"
  assert_equals "$session" "$(sed -n 1p "$HOME_DIR/state/.agy-t3-ring-fallback")" "an unconfirmed start must latch the blocking park"
  sends_are 0 || fail "a fallen-back session must ring nothing"
  end_session "$HOME_DIR"
  pass "agy T3 ring: a waiter that does not confirm in time is stopped and the blocking park takes the turn"
}

test_t3_turn_ends_at_once_and_the_waiter_rings_the_wake
test_outside_t3_the_hook_parks_in_place
test_a_wake_pending_at_turn_end_is_handed_to_the_stop_hook
test_a_wake_closing_as_the_turn_ends_waits_for_an_idle_thread
test_a_send_t3_cannot_take_is_retried_until_it_lands
test_a_ring_t3_keeps_refusing_gives_up_visibly
test_the_waiter_stands_down_when_the_lock_moves
test_a_host_home_runs_the_host_bound_to_the_lock_holder
test_an_unconfirmed_start_falls_back_to_the_blocking_park
