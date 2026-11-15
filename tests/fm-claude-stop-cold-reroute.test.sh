#!/usr/bin/env bash
# Behavior tests for the fork's Claude Stop hook wrapper
# (bin/fm-claude-stop-cold-reroute.sh, FORK.md "A notification never reloads a
# cold session").
#
# The wrapper runs as a child of a fake harness (a bash symlink named "claude")
# that holds the fixture home's session lock. Most cases replace the upstream
# hook with a stub whose outcome each case chooses, so the wrapper's judgment is
# tested against every upstream outcome; one case runs the real upstream hook
# with an actionable arm fixture, to prove the ledger interaction. Transcripts
# are made up, and the T3 Code send goes to tests/t3-fake-server.mjs.
# shellcheck disable=SC2016 # single-quoted scripts expand inside the fake harness
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-cold-reroute)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
THREAD=thread-fm

t3_fake_start "$TMP_ROOT/server"
cleanup() {
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

# One code root whose upstream hook is a stub. The stub records its parent (the
# wrapper) and its stdin, then acts out the outcome named in the case home's
# state/upstream-mode, writing the upstream ledger line the real hook writes.
STUB_ROOT="$TMP_ROOT/stub-root"
mkdir -p "$STUB_ROOT"
cp -R "$ROOT/bin" "$STUB_ROOT/bin"
WRAPPER="$STUB_ROOT/bin/fm-claude-stop-cold-reroute.sh"
cat > "$STUB_ROOT/bin/fm-claude-stop-autoarm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PPID" > "$FM_HOME/state/wrapper-pid"
if [ "$#" -gt 0 ]; then
  printf 'upstream args: %s\n' "$*" >&2
  exit 5
fi
cat > "$FM_HOME/state/upstream-stdin"
mode=$(cat "$FM_HOME/state/upstream-mode" 2>/dev/null)
ledger() {
  printf 'epoch=7 owner_pid=%s outcome=%s updated_at=%s\n' "$1" "$2" "$(date +%s)" > "$FM_HOME/state/.claude-autoarm-epoch"
}
if [ "$mode" = park-wake ]; then
  while [ ! -e "$FM_HOME/state/release" ]; do sleep 0.05; done
  mode=wake
fi
if [ "$mode" = wake ]; then
  ledger "$$" rewake
  printf 'firstmate watcher wake - one supervision event needs a handling turn now.\nsignal: fixture\nno final newline' >&2
  exit 2
elif [ "$mode" = failed ]; then
  ledger "$$" failed
  printf 'firstmate watcher auto-arm FAILED - fixture\n' >&2
  exit 2
elif [ "$mode" = foreign ]; then
  ledger 1 rewake
  printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n' >&2
  exit 2
elif [ "$mode" = quiet ]; then
  printf 'upstream stdout\n'
  exit 0
fi
exit 9
SH
chmod +x "$STUB_ROOT/bin/fm-claude-stop-autoarm.sh"
WAKE_ERR="$TMP_ROOT/wake.err"
printf 'firstmate watcher wake - one supervision event needs a handling turn now.\nsignal: fixture\nno final newline' > "$WAKE_ERR"

# write_transcript <file> <age-seconds> <context-tokens>: a made-up Claude
# transcript whose last request is <age-seconds> old and <context-tokens> big.
write_transcript() {
  local file=$1 ts
  ts=$(jq -nr --argjson t "$(( $(date +%s) - $2 ))" '$t | todate | sub("Z$"; ".512Z")')
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"made up"}}\n' "$ts"
    printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$ts" "$(( $3 - 3 ))"
    printf '{"type":"system","timestamp":"%s","subtype":"stop_hook_summary"}\n' "$ts"
  } > "$file"
}

# make_case <name> <mode> <age-seconds> <context-tokens>: a case home with a
# transcript, a payload (no final newline, so a byte-exact copy is provable), a
# T3 thread, and a credential. Sets HOME_DIR.
make_case() {
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$2" > "$HOME_DIR/state/upstream-mode"
  write_transcript "$HOME_DIR/transcript.jsonl" "$3" "$4"
  printf '{"session_id":"sess-cold","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":false}' \
    "$HOME_DIR/transcript.jsonl" > "$HOME_DIR/payload"
  t3_fake_case "$HOME_DIR/t3"
  t3_fake_set 'w.threads = { "thread-fm": { threadId: "thread-fm", projectId: "proj-1", status: "completed",
    activeRunId: null, archived: false, worktreePath: null, pendingRequestCount: 0,
    providerInstanceId: "claudeAgent", runtimeMode: "full-access", parentThreadId: null, items: [], runs: [] } }'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
}

# run_wrapper <home> <wrapper> [env...]: run the wrapper under the fake harness,
# which takes the session lock first unless FM_TEST_KEEP_LOCK=1 is given. Sets
# RC; stdout and stderr land in <home>/out and <home>/err.
run_wrapper() {
  local home=$1 wrapper=$2
  shift 2
  RC=0
  env T3CODE_THREAD_ID="$THREAD" FM_HOME="$home" env "$@" "$FAKE_CLAUDE" -c '
    [ "${FM_TEST_KEEP_LOCK:-0}" = 1 ] || printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$1" < "$FM_HOME/payload" > "$FM_HOME/out" 2> "$FM_HOME/err"
    rc=$?
    printf "%s\n" "$rc" > "$FM_HOME/rc"
    exit "$rc"
  ' fake-claude "$wrapper" || RC=$?
}

send_count() {
  t3_fake_calls t3_thread_send | grep -c . || true
}

# The upstream outcome reached Claude unchanged: its exit status and stderr.
assert_passed_through() {  # <home> <expected-rc> <expected-stderr-file> <why>
  expect_code "$2" "$RC" "$4: exit status"
  cmp -s "$1/err" "$3" || fail "$4: stderr was not passed through byte for byte: $(cat "$1/err")"
}

# The record path an operational doorbell names, per bin/fm-operational-input.sh.
doorbell_record() {  # <message>
  printf '%s' "$1" | sed -n "s/^: Firstmate operational input waiting: read '\\(.*\\)' and handle its contents as Firstmate operational input\\.\$/\\1/p"
}

test_cold_large_wake_is_rung_through_t3() {
  local args message record body
  make_case cold-large wake 4000 250000
  run_wrapper "$HOME_DIR" "$WRAPPER"
  expect_code 0 "$RC" "a cold, large wake must not wake the session in place"
  [ ! -s "$HOME_DIR/err" ] || fail "a rerouted wake must deliver no stderr: $(cat "$HOME_DIR/err")"
  cmp -s "$HOME_DIR/payload" "$HOME_DIR/state/upstream-stdin" || fail "the upstream hook must read the payload byte for byte"
  [ "$(send_count)" = 1 ] || fail "expected exactly one T3 send, saw $(send_count)"
  args=$(t3_fake_calls t3_thread_send)
  [ "$(printf '%s' "$args" | jq -r .threadId)" = "$THREAD" ] || fail "the send must go to FirstMate's own thread: $args"
  [ "$(printf '%s' "$args" | jq -r .mode)" = auto ] || fail "the send must start the thread's next turn: $args"
  [ "$(printf '%s' "$args" | jq -r 'has("freshContext")')" = false ] || fail "the send must not ask for fresh context: $args"
  message=$(printf '%s' "$args" | jq -r .message)
  [ "$(printf '%s' "$message" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" = watcher ] \
    || fail "the message must be an operational-input doorbell of the watcher kind: $message"
  record=$(doorbell_record "$message")
  [ -n "$record" ] || fail "the doorbell names no record: $message"
  body=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-operational-input.sh" open "$record") \
    || fail "the doorbell's record must sit in this home's own operational inbox: $record"
  assert_contains "$body" "bin/fm-wake-drain.sh" "the message must point at the durable queue"
  assert_not_contains "$body" "signal: fixture" "the message must carry no notification"
  pass "cold-reroute: a wake of a cold session over 100k is one T3 operational doorbell and no wake"
}

test_unwritable_record_falls_back_to_the_wake() {
  make_case no-inbox wake 4000 250000
  : > "$HOME_DIR/state/operational-inbox"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a record that cannot be written"
  [ "$(send_count)" = 0 ] || fail "a doorbell without its record must never be sent"
  pass "cold-reroute: a record that cannot be written falls back to upstream's wake"
}

test_warm_session_passes_through() {
  make_case warm wake 600 250000
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a warm session"
  [ "$(send_count)" = 0 ] || fail "a warm session must not be rung through T3"
  pass "cold-reroute: a warm session is woken in place, unchanged"
}

test_cache_lifetime_is_tunable() {
  make_case short-cache wake 600 250000
  run_wrapper "$HOME_DIR" "$WRAPPER" FM_COLD_REROUTE_CACHE_SECONDS=300
  expect_code 0 "$RC" "a session idle past a configured 300 s cache lifetime is cold"
  [ "$(send_count)" = 1 ] || fail "expected one T3 send under a 300 s cache lifetime, saw $(send_count)"
  pass "cold-reroute: the cache lifetime follows FM_COLD_REROUTE_CACHE_SECONDS"
}

test_small_session_passes_through() {
  make_case small wake 4000 100000
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a cold session of exactly 100k"
  [ "$(send_count)" = 0 ] || fail "a session not over 100k must not be rung through T3"
  pass "cold-reroute: a cold session not over 100k is woken in place"
}

test_outside_t3_matches_upstream_exactly() {
  local expected_err="$TMP_ROOT/outside-quiet.expected"
  make_case outside wake 4000 250000
  run_wrapper "$HOME_DIR" "$WRAPPER" -u T3CODE_THREAD_ID
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a session outside T3 Code"
  [ "$(send_count)" = 0 ] || fail "a session outside T3 Code must not send"

  printf 'quiet\n' > "$HOME_DIR/state/upstream-mode"
  : > "$expected_err"
  run_wrapper "$HOME_DIR" "$WRAPPER" -u T3CODE_THREAD_ID
  assert_passed_through "$HOME_DIR" 0 "$expected_err" "a silent upstream outcome"
  [ "$(cat "$HOME_DIR/out")" = "upstream stdout" ] || fail "upstream stdout must pass through"
  pass "cold-reroute: outside T3 Code the output and exit match upstream's hook exactly"
}

test_silent_upstream_passes_through_in_t3() {
  local expected_err="$TMP_ROOT/quiet.expected"
  make_case quiet-t3 quiet 4000 250000
  : > "$expected_err"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 0 "$expected_err" "a silent upstream outcome in T3"
  [ "$(send_count)" = 0 ] || fail "an exit 0 must never send"
  pass "cold-reroute: an upstream exit 0 is never rerouted"
}

test_lock_not_held_passes_through() {
  local other
  make_case no-lock wake 4000 250000
  sleep 30 &
  other=$!
  printf '%s\n' "$other" > "$HOME_DIR/state/.lock"
  run_wrapper "$HOME_DIR" "$WRAPPER" FM_TEST_KEEP_LOCK=1
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a session that does not hold the lock"
  [ "$(send_count)" = 0 ] || fail "a session without the lock must not send"
  pass "cold-reroute: a session that does not hold the session lock is not rerouted"
}

test_failure_exit_passes_through() {
  local expected="$TMP_ROOT/failed.expected"
  make_case failed failed 4000 250000
  printf 'firstmate watcher auto-arm FAILED - fixture\n' > "$expected"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$expected" "an upstream failure notice"
  [ "$(send_count)" = 0 ] || fail "a failure notice must never be rerouted"
  pass "cold-reroute: an exit 2 that is not a wake (a failure notice) passes through"
}

test_ledger_of_another_process_passes_through() {
  local expected="$TMP_ROOT/foreign.expected"
  make_case foreign foreign 4000 250000
  printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n' > "$expected"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$expected" "a rewake ledger written by another process"
  [ "$(send_count)" = 0 ] || fail "a ledger entry this hook did not write must not reroute"
  pass "cold-reroute: only a rewake recorded by this upstream hook's own pid is rerouted"
}

test_send_failures_fall_back_to_the_wake() {
  local origin
  make_case refused wake 4000 250000
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "thread_not_sendable", message: "refused" } }'
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a refused send"

  make_case unconfirmed wake 4000 250000
  t3_fake_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "an unconfirmed delivery"

  make_case revoked wake 4000 250000
  t3_fake_set 'w.revoked = true'
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a refused credential"

  make_case expired wake 4000 250000
  t3_fake_credential "$HOME_DIR/config/t3code-token" env-fake-1 1000
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "an expired credential"

  make_case unreachable wake 4000 250000
  origin=http://127.0.0.1:9
  t3_fake_credential "$HOME_DIR/config/t3code-token" env-fake-1 "" 600 "$origin"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "an unreachable T3"

  make_case no-credential wake 4000 250000
  rm -f "$HOME_DIR/config/t3code-token"
  run_wrapper "$HOME_DIR" "$WRAPPER"
  assert_passed_through "$HOME_DIR" 2 "$WAKE_ERR" "a home with no T3 credential"
  [ "$(send_count)" = 0 ] || fail "a home with no credential must not send"
  pass "cold-reroute: a refused, unconfirmed, unauthorised, expired, unreachable, or absent send falls back to upstream's wake"
}

test_signalled_wrapper_waits_and_passes_through() {
  local pid i=0
  make_case signalled park-wake 4000 250000
  run_wrapper "$HOME_DIR" "$WRAPPER" &
  pid=$!
  while [ ! -s "$HOME_DIR/state/wrapper-pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$HOME_DIR/state/wrapper-pid" ] || fail "the stub upstream hook never started"
  kill -TERM "$(cat "$HOME_DIR/state/wrapper-pid")"
  sleep 0.2
  : > "$HOME_DIR/state/release"
  wait "$pid"
  expect_code 2 "$(cat "$HOME_DIR/rc")" "a signalled wrapper must pass the upstream exit status through"
  cmp -s "$HOME_DIR/err" "$WAKE_ERR" || fail "a signalled wrapper must still pass the upstream stderr through: $(cat "$HOME_DIR/err")"
  [ "$(send_count)" = 0 ] || fail "a signalled wrapper must not reroute"
  pass "cold-reroute: a signalled wrapper waits for upstream's own outcome and never reroutes"
}

test_arguments_go_to_upstream_and_help_is_its_own() {
  local out rc=0
  out=$("$WRAPPER" --help) || fail "--help must succeed"
  assert_contains "$out" "fm-claude-stop-cold-reroute.sh" "--help must describe the wrapper"
  mkdir -p "$TMP_ROOT/args/state"
  out=$(FM_HOME="$TMP_ROOT/args" "$WRAPPER" --bogus 2>&1) || rc=$?
  expect_code 5 "$rc" "an unknown argument must reach the upstream hook unchanged"
  assert_contains "$out" "upstream args: --bogus" "the upstream hook must receive the arguments"
  pass "cold-reroute: -h is the wrapper's own usage, and other arguments go to upstream unchanged"
}

# The real upstream hook writes its ledger before it exits 2; the wrapper must
# read that write as this hook's wake and swallow the exit.
test_real_upstream_wake_is_rerouted() {
  local dir="$TMP_ROOT/real" outcome
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/config/supervision-host-off"
  : > "$dir/state/task.meta"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  write_transcript "$dir/transcript.jsonl" 4000 250000
  printf '{"session_id":"sess-real","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":false}' \
    "$dir/transcript.jsonl" > "$dir/payload"
  t3_fake_case "$dir/t3"
  t3_fake_set 'w.threads = { "thread-fm": { threadId: "thread-fm", projectId: "proj-1", status: "completed",
    activeRunId: null, archived: false, worktreePath: null, pendingRequestCount: 0,
    providerInstanceId: "claudeAgent", runtimeMode: "full-access", parentThreadId: null, items: [], runs: [] } }'
  t3_fake_credential "$dir/config/t3code-token"

  run_wrapper "$dir" "$dir/bin/fm-claude-stop-cold-reroute.sh"
  expect_code 0 "$RC" "the real upstream wake of a cold, large session must be rerouted"
  [ ! -s "$dir/err" ] || fail "a rerouted real wake must deliver no stderr: $(cat "$dir/err")"
  outcome=$(sed -n '1s/.*outcome=\([^ ]*\).*/\1/p' "$dir/state/.claude-autoarm-epoch")
  [ "$outcome" = rewake ] || fail "the upstream ledger must still record its wake, got: $outcome"
  [ "$(send_count)" = 1 ] || fail "expected one T3 send for the real wake, saw $(send_count)"

  write_transcript "$dir/transcript.jsonl" 60 250000
  run_wrapper "$dir" "$dir/bin/fm-claude-stop-cold-reroute.sh"
  expect_code 2 "$RC" "the real upstream wake of a warm session must pass through"
  assert_contains "$(cat "$dir/err")" "firstmate watcher wake" "the warm wake must carry upstream's banner"
  assert_contains "$(cat "$dir/err")" "stale: fixture-win actionable" "the warm wake must carry upstream's reason"
  [ "$(send_count)" = 1 ] || fail "a warm real wake must not send"
  pass "cold-reroute: the real upstream hook's recorded wake is rerouted when cold and passed through when warm"
}

fm_test_run \
  test_cold_large_wake_is_rung_through_t3 \
  test_warm_session_passes_through \
  test_cache_lifetime_is_tunable \
  test_small_session_passes_through \
  test_outside_t3_matches_upstream_exactly \
  test_silent_upstream_passes_through_in_t3 \
  test_lock_not_held_passes_through \
  test_failure_exit_passes_through \
  test_ledger_of_another_process_passes_through \
  test_send_failures_fall_back_to_the_wake \
  test_unwritable_record_falls_back_to_the_wake \
  test_signalled_wrapper_waits_and_passes_through \
  test_arguments_go_to_upstream_and_help_is_its_own \
  test_real_upstream_wake_is_rerouted
