#!/usr/bin/env bash
# tests/fm-t3-clear-session.test.sh - the session swap behind T3 Code's /clear
# on the FirstMate thread (docs/t3code-backend.md "Fresh session with /clear").
#
# T3 keeps the FirstMate thread and replaces its agent session: the old session's
# last turn ends, its Stop hook may fire, T3 ends the process with SIGTERM about
# two seconds later without anything releasing the session lock, and a new process
# starts on the same thread. These are real-process cases: a fake Claude
# session runs the real SessionStart entry point, the real Stop hook, the real
# supervision host or arm, and the real watcher, and it dies by a real SIGTERM.
# Only the engine and the worker endpoint are stubs.
#
# What Claude does to a running Stop hook when it is signalled is the harness's
# choice, so each supervision case runs both ways: the hook's process group dies
# with the session, or the hook outlives it as an orphan.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

THREAD='d72e06eb-0000-4c54-b48c-clearthread00'
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
SWAP_NOTE='check: captain inbox note left during the swap'

# Set by start_session rather than echoed: a command substitution would make the
# session a child of a subshell this shell can no longer wait for.
SESSION_PID=

# A home with its own copy of bin, so each process's command line names this home
# and the watcher count below can never see another suite's watcher.
make_swap_home() {  # <name> <host|plain>
  local home tool
  home=$(make_home "$1" attended)
  git init -q "$home"
  git -C "$home" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  cp -R "$ROOT/bin" "$home/bin"
  ln -s "$ROOT/.agents" "$home/.agents"
  ln -s "$ROOT/docs" "$home/docs"
  ln -s "$ROOT/.pi" "$home/.pi"
  rm -f "$home"/mirror-seed.*
  [ "$2" = host ] || : > "$home/config/supervision-host-off"
  for tool in node jq; do
    ln -s "$(command -v "$tool")" "$home/fakebin/$tool"
  done
  # Claude runs a hook through a shell of its own, which is not harness-shaped.
  cat > "$home/stop-hook.sh" <<'SH'
#!/usr/bin/env bash
dir=$1
if [ "${FM_TEST_ORPHAN_FIRST:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '{"session_id":"%s","stop_hook_active":false}\n' "$CLAUDE_CODE_SESSION_ID" > "$dir/hook.stdin"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$dir/hook.stdin" > "$dir/hook.out" 2> "$dir/hook.err"
printf '%s\n' "$?" > "$dir/hook.rc"
exit 0
SH
  # Every fixture script ends in an explicit exit so bash can never tail-exec a
  # command in place of the fake claude.
  cat > "$home/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=$1
dir="$FM_HOME/sessions/$1"
mkdir -p "$dir"
printf '%s\n' "$$" > "$dir/pid"
printf '%s\n' "$$" >> "$FM_HOME/claude-pids"
printf '{"session_id":"%s","source":"startup"}\n' "$1" \
  | "$FM_HOME/bin/fm-sessionstart-run.sh" > "$dir/digest" 2>&1
: > "$dir/started"
printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"%s","prompt":"%s"}' "$1" "$2" \
  | "$FM_HOME/bin/fm-host-mirror.sh" hook claude
set -m
while [ -d "$FM_HOME" ] && kill -0 "$FM_TEST_SUITE_PID" 2>/dev/null; do
  if [ -e "$dir/run" ]; then
    mv "$dir/run" "$dir/run.now"
    bash "$dir/run.now" > "$dir/run.out" 2>&1
    printf '%s\n' "$?" > "$dir/run.rc"
  fi
  if [ -e "$dir/stop.go" ]; then
    rm -f "$dir/stop.go" "$dir/hook.rc"
    bash "$FM_HOME/stop-hook.sh" "$dir" &
    printf '%s\n' "$!" > "$dir/hook.pgid"
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$home/session.sh"
  printf '%s\n' "$home"
}

session_dir() { printf '%s/sessions/%s' "$1" "$2"; }

start_session() {  # <home> <session-id> <first-prompt>
  local home=$1 id=$2 prompt=$3 dir
  dir=$(session_dir "$home" "$id")
  env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u FM_TASK_ID -u FM_TASK_INBOX \
    -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE \
    CLAUDECODE=1 T3CODE_THREAD_ID="$THREAD" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_REPO="$home" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$BASE_PATH" \
    "$FAKE_CLAUDE" "$home/session.sh" "$id" "$prompt" 2>> "$home/claude.err" &
  SESSION_PID=$!
  wait_until 600 test -e "$dir/started" || fail "session $id never finished its session start: $(cat "$home/claude.err")"
}

turn_ends() {  # <home> <session-id>: the session's Stop hook fires
  rm -f "$(session_dir "$1" "$2")/hook.rc"
  : > "$(session_dir "$1" "$2")/stop.go"
}

run_in_session() {  # <home> <session-id> <shell command>
  local dir
  dir=$(session_dir "$1" "$2")
  rm -f "$dir/run.rc"
  printf '%s\n' "$3" > "$dir/run.tmp"
  mv "$dir/run.tmp" "$dir/run"
  wait_until 300 test -s "$dir/run.rc" || fail "session $2 never ran: $3"
}

# T3 ends the old session with SIGTERM once its last turn ends, and nothing runs
# in it to release the lock.
sigterm_session() {  # <home> <session-id> <session-pid> <killed|orphaned>
  local home=$1 id=$2 pid=$3 hook_fate=$4 pgid
  pgid=$(cat "$(session_dir "$home" "$id")/hook.pgid" 2>/dev/null || true)
  if [ "$hook_fate" = killed ] && [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
  fi
  kill -TERM "$pid" || fail "could not SIGTERM session $id"
  wait "$pid" 2>/dev/null || true
  ! kill -0 "$pid" 2>/dev/null || fail "session $id outlived its SIGTERM"
}

# Every live watcher of this home, by its command line.
watcher_count() {  # <home>
  # The path rides the environment so the filter never counts its own command line.
  ps -axo command= 2>/dev/null | FM_TEST_WATCHER="$1/bin/fm-watch.sh" \
    awk 'index($0, ENVIRON["FM_TEST_WATCHER"]) { n++ } END { print n + 0 }'
}

# Act as the session does on each rewake: drain, acknowledge, and end the turn,
# whose Stop hook arms the next cycle. A watcher that died with the old session
# costs one recovery wake first, so the wake wanted may be the second one.
handle_wakes_until() {  # <home> <session-id> <text the drain must present>
  local home=$1 id=$2 text=$3 dir ack presented=0 i=0
  dir=$(session_dir "$home" "$id")
  while [ "$i" -lt 5 ] && [ "$presented" -eq 0 ]; do
    wait_until_deadline 60 test -s "$dir/hook.rc" || fail "the session's hook never delivered a wake: $(cat "$dir/hook.err" 2>/dev/null)"
    expect_code 2 "$(cat "$dir/hook.rc")" "a wake must rewake the session: $(cat "$dir/hook.err")"
    run_in_session "$home" "$id" '"$FM_HOME/bin/fm-wake-drain.sh"'
    ! grep -qF "$text" "$dir/run.out" || presented=1
    ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' "$dir/run.out" | tail -1)
    [ -z "$ack" ] || run_in_session "$home" "$id" "\"\$FM_HOME/bin/fm-wake-drain.sh\" $ack"
    turn_ends "$home" "$id"
    i=$((i + 1))
  done
  [ "$presented" -eq 1 ] || fail "no wake presented $text to session $id"
}

assert_one_watcher() {  # <home> <label>
  local count
  wait_until 100 test "$(watcher_count "$1")" -le 1 || true
  count=$(watcher_count "$1")
  [ "$count" = 1 ] || fail "$2: expected one watcher cycle, found $count"
  watcher_live "$1" || fail "$2: the watcher lock names no live watcher"
  ps -o command= -p "$(cat "$1/state/.watch.lock/pid")" | grep -qF "$1/bin/fm-watch.sh" \
    || fail "$2: the one watcher is not the one the lock names"
}

assert_took_the_helm() {  # <home> <session-id> <session-pid> <label>
  local home=$1 id=$2 pid=$3 label=$4 digest
  digest=$(cat "$(session_dir "$home" "$id")/digest")
  assert_not_contains "$digest" 'READ-ONLY SESSION' "$label: the session came up read-only"
  assert_contains "$digest" "lock acquired: harness pid $pid" "$label: the digest did not report taking the lock"
  [ "$(cat "$home/state/.lock")" = "$pid" ] \
    || fail "$label: the lock names $(cat "$home/state/.lock"), expected $pid"
  [ "$(cat "$home/state/.lock-session")" = "$id" ] \
    || fail "$label: the lock's session record names $(cat "$home/state/.lock-session"), expected $id"
  [ "$(cat "$home/state/t3-main-thread")" = "$THREAD" ] \
    || fail "$label: state/t3-main-thread reads $(cat "$home/state/t3-main-thread"), expected $THREAD"
}

# --- the lock passes over ------------------------------------------------------

test_fresh_session_takes_the_lock_from_a_sigtermed_one() {
  local home old new
  home=$(make_swap_home swap-lock plain)
  start_session "$home" sess-old 'check the build'
  old=$SESSION_PID
  assert_took_the_helm "$home" sess-old "$old" "old session"

  sigterm_session "$home" sess-old "$old" killed
  [ "$(cat "$home/state/.lock")" = "$old" ] || fail "fixture: the dead session must leave its lock behind"
  [ "$(cat "$home/state/.lock-session")" = sess-old ] || fail "fixture: the dead session must leave its session record behind"

  start_session "$home" sess-new 'what is next?'
  new=$SESSION_PID
  [ "$new" != "$old" ] || fail "fixture: the two sessions must be distinct processes"
  assert_took_the_helm "$home" sess-new "$new" "fresh session"
  stop_home_processes "$home"
  pass "swap: the fresh session takes the lock a SIGTERMed session left and records the same thread"
}

# The T3 Code fork waits for the old process to exit for this reason: a fresh session that
# starts beside a live holder comes up read-only and changes nothing.
test_fresh_session_beside_a_live_holder_stays_read_only() {
  local home old new digest
  home=$(make_swap_home swap-live-holder plain)
  start_session "$home" sess-old 'check the build'
  old=$SESSION_PID
  append_wake "$home/state" check swap-note "$SWAP_NOTE"
  printf 'earlier-thread\n' > "$home/state/t3-main-thread"

  start_session "$home" sess-new 'what is next?'
  new=$SESSION_PID
  digest=$(cat "$(session_dir "$home" sess-new)/digest")
  assert_contains "$digest" 'READ-ONLY SESSION' "a session beside a live holder must come up read-only"
  [ "$(cat "$home/state/.lock")" = "$old" ] || fail "a read-only session took the live holder's lock"
  [ "$(cat "$home/state/t3-main-thread")" = earlier-thread ] || fail "a read-only session rewrote state/t3-main-thread"
  assert_grep "$SWAP_NOTE" "$home/state/.wake-queue" "a read-only session consumed the queued wake"
  [ "$new" != "$old" ] || fail "fixture: the two sessions must be distinct processes"
  stop_home_processes "$home"
  pass "swap: a fresh session beside a live holder stays read-only, which is why T3 waits for the exit"
}

# The Stop hook can outlive the session it belongs to. Whichever side of the
# fresh session's start it fires on, it must arm nothing and move no lock.
fire_dead_sessions_stop_hook() {  # <home> <session-id> <dead-session-pid>
  local home=$1 id=$2 pid=$3 dir
  dir=$(session_dir "$home" "$id")
  rm -f "$dir/hook.rc"
  env -u FM_TASK_ID -u FM_STATE_OVERRIDE \
    CLAUDECODE=1 CLAUDE_PID="$pid" CLAUDE_CODE_SESSION_ID="$id" FM_TEST_ORPHAN_FIRST=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_REPO="$home" PATH="$home/fakebin:$BASE_PATH" \
    bash -c 'bash "$0" "$1" &' "$home/stop-hook.sh" "$dir"
  wait_until 300 test -s "$dir/hook.rc" || fail "the dead session's Stop hook never finished"
  expect_code 0 "$(cat "$dir/hook.rc")" "the dead session's Stop hook must end silently: $(cat "$dir/hook.err")"
  assert_absent "$home/state/.claude-autoarm-epoch" "the dead session's Stop hook claimed supervision"
  [ "$(watcher_count "$home")" = 0 ] || fail "the dead session's Stop hook started a watcher"
}

test_dead_sessions_stop_hook_changes_nothing() {
  local home old new
  home=$(make_swap_home swap-late-hook plain)
  start_session "$home" sess-old 'check the build'
  old=$SESSION_PID
  sigterm_session "$home" sess-old "$old" killed

  fire_dead_sessions_stop_hook "$home" sess-old "$old"
  [ "$(cat "$home/state/.lock")" = "$old" ] || fail "a Stop hook with no live session rewrote the lock"

  start_session "$home" sess-new 'what is next?'
  new=$SESSION_PID
  assert_took_the_helm "$home" sess-new "$new" "after the late hook"

  fire_dead_sessions_stop_hook "$home" sess-old "$old"
  assert_took_the_helm "$home" sess-new "$new" "after a second late hook"
  stop_home_processes "$home"
  pass "swap: the dead session's Stop hook takes no lock and arms nothing, before or after the fresh session starts"
}

# --- supervision survives ------------------------------------------------------

assert_supervision_survives_the_swap() {  # <host|plain> <killed|orphaned>
  local supervision=$1 hook_fate=$2 home old new old_dir new_dir digest ack
  home=$(make_swap_home "swap-$supervision-$hook_fate" "$supervision")
  old_dir=$(session_dir "$home" sess-old)
  new_dir=$(session_dir "$home" sess-new)

  start_session "$home" sess-old 'check the build'
  old=$SESSION_PID
  turn_ends "$home" sess-old
  wait_until 300 watcher_live "$home" || fail "the last turn's Stop hook never armed: $(cat "$old_dir/hook.err" 2>/dev/null)"

  sigterm_session "$home" sess-old "$old" "$hook_fate"
  append_wake "$home/state" check swap-note "$SWAP_NOTE"

  start_session "$home" sess-new 'what is next?'
  new=$SESSION_PID
  assert_took_the_helm "$home" sess-new "$new" "fresh session"
  digest=$(cat "$new_dir/digest")
  assert_contains "$digest" "$SWAP_NOTE" "the wake queued during the swap was not presented to the fresh session"
  ack=$(printf '%s\n' "$digest" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  [ -n "$ack" ] || fail "the fresh session's digest carried no acknowledgement for the swap wake: $digest"
  run_in_session "$home" sess-new "\"\$FM_HOME/bin/fm-wake-drain.sh\" $ack"
  expect_code 0 "$(cat "$new_dir/run.rc")" "the fresh session could not acknowledge the swap wake: $(cat "$new_dir/run.out")"
  ! grep -qF "$SWAP_NOTE" "$home/state/.wake-queue" 2>/dev/null || fail "the acknowledged swap wake stayed queued"

  turn_ends "$home" sess-new
  wait_until 300 watcher_live "$home" || fail "the fresh session's Stop hook never armed: $(cat "$new_dir/hook.err" 2>/dev/null)"
  wait_until 300 test -e "$home/state/.claude-autoarm-epoch" || fail "the fresh session claimed no supervision"
  [ "$(watcher_count "$home")" -le 1 ] || fail "the fresh session's first Stop left two watcher cycles"
  assert_absent "$home/state/.claude-autoarm-failure-notified" "the old session's interrupted hook left the fresh session a failure notice"

  # The cycle must really belong to the fresh session: a decision only main can
  # take reaches it, and nothing wakes the dead session's hook.
  printf 'project=demo\nwindow=fm-beta\nharness=claude\n' > "$home/state/beta.meta"
  printf 'needs-decision [at=%s]: select an export format\n' "$(date +%s)" > "$home/state/beta.status"
  handle_wakes_until "$home" sess-new beta.status
  wait_until 300 watcher_live "$home" || fail "the handling turn's Stop hook never re-armed: $(cat "$new_dir/hook.err" 2>/dev/null)"
  if [ "$hook_fate" = orphaned ]; then
    wait_until 300 test -s "$old_dir/hook.rc" || fail "the old session's orphaned hook never stood down"
    expect_code 0 "$(cat "$old_dir/hook.rc")" "the old session's orphaned hook must stand down silently: $(cat "$old_dir/hook.err")"
  fi
  assert_one_watcher "$home" "after the next wake"
  stop_home_processes "$home"
  pass "swap ($supervision, hook $hook_fate): the swap wake reaches the fresh session and one watcher cycle remains"
}

test_supervision_survives_with_the_host_when_the_hook_dies() { assert_supervision_survives_the_swap host killed; }
test_supervision_survives_with_the_host_when_the_hook_is_orphaned() { assert_supervision_survives_the_swap host orphaned; }
test_supervision_survives_on_the_plain_arm_when_the_hook_dies() { assert_supervision_survives_the_swap plain killed; }
test_supervision_survives_on_the_plain_arm_when_the_hook_is_orphaned() { assert_supervision_survives_the_swap plain orphaned; }

test_fresh_session_takes_the_lock_from_a_sigtermed_one
test_fresh_session_beside_a_live_holder_stays_read_only
test_dead_sessions_stop_hook_changes_nothing
test_supervision_survives_on_the_plain_arm_when_the_hook_dies
test_supervision_survives_on_the_plain_arm_when_the_hook_is_orphaned
test_supervision_survives_with_the_host_when_the_hook_dies
test_supervision_survives_with_the_host_when_the_hook_is_orphaned
