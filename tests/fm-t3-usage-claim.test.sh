#!/usr/bin/env bash
# tests/fm-t3-usage-claim.test.sh - bin/fm-t3-usage-claim.sh, Firstmate's
# usage claims on T3 Code, and the records it reads from
# bin/fm-t3-cause-lib.sh: driven through its CLI, and through
# bin/fm-wake-drain.sh, against tests/t3-fake-server.mjs. No live T3 server
# is ever called.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-usage-claim-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
CLAIM="$ROOT/bin/fm-t3-usage-claim.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
CONFIG_DIR="$HOME_DIR/config"
CAUSE_T='{"threadId":"coord","runId":"run-old","messageId":"msg-old"}'
mkdir -p "$STATE_DIR" "$CONFIG_DIR"
# The drain's BRANCH OUTCOMES section stays out of these cases.
: > "$CONFIG_DIR/supervision-host-off"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR"

# fresh_case <name> [world-json]: a fresh fake world holding thread coord: a
# finished human turn run-old (prompt msg-old), a finished wake turn run-w
# (notification msg-w), and the active wake turn run-c (notification msg-c),
# started a minute ago; plus a fresh state directory.
# shellcheck disable=SC2016  # ${...} belongs to the JavaScript snippet.
fresh_case() {
  local i=0
  # An earlier case's detached sweep finishes before its world and records go.
  while pgrep -f "$CLAIM" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  t3_fake_case "$TMP_ROOT/cases/$1" "${2:-{\"causedBy\":true,\"usageClaims\":true\}}"
  t3_fake_credential "$CONFIG_DIR/t3code-token"
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  FM_AT="$(FM_IN=-60 node -e 'process.stdout.write(new Date(Date.now() + Number(process.env.FM_IN) * 1000).toISOString())')" t3_fake_set '
const item = (type, id, run) => ({ type, status: "completed", text: "x", runId: run, messageId: id });
const run = (runId, ordinal, status, userMessageId, at, done) => ({ runId, userMessageId, ordinal, status, requestedAt: at, startedAt: at, completedAt: done });
w.threads = { coord: { threadId: "coord", projectId: "p", title: "FirstMate", status: "running", activeRunId: "run-c", latestRunId: "run-c",
  archived: false, worktreePath: null, pendingRequestCount: 0, itemCount: 3,
  items: [item("user_message", "msg-old", "run-old"), item("notification", "msg-w", "run-w"), item("notification", "msg-c", "run-c")],
  runs: [run("run-old", 1, "completed", "msg-old", "2026-11-15T00:00:00.000Z", "2026-11-15T00:01:00.000Z"),
    run("run-w", 2, "completed", "msg-w", "2026-11-15T00:02:00.000Z", "2026-11-15T00:03:00.000Z"),
    run("run-c", 3, "running", "msg-c", process.env.FM_AT, null)] } };'
}

# as_agent <command...>: run <command> as a command FirstMate's agent in
# thread coord started now (its parent bash stands for the agent).
# shellcheck disable=SC2016  # $@ belongs to the bash -c snippet.
as_agent() {
  OUT=$(env T3CODE_THREAD_ID=coord bash -c '"$@"; rc=$?; exit "$rc"' _ "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

claims() {  # <key> -> the stored claim
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = (w.usageClaims || {})[process.argv[2]]; if (v) process.stdout.write(JSON.stringify(v));' "$T3_FAKE_WORLD" "$1"
}

# wait_claim <key> <expected> <seconds>: the detached sweep's claim lands.
wait_claim() {
  local i=0
  while [ "$i" -lt $(($3 * 10)) ]; do
    [ "$(claims "$1")" = "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# settle_sweep: a wake's detached sweep has claimed both finished turns, so it
# cannot spill into the next case.
settle_sweep() {
  if ! wait_claim run:coord:run-w '{"device":"computer"}' 10 || ! wait_claim run:coord:run-old '{"device":"computer"}' 10; then
    fail "the sweep claims every unclaimed finished turn computer: $(t3_fake_field usageClaims)"
  fi
}

meta_with_cause() {  # <task> <cause-json|empty>
  { printf 'window=t3code:%s\n' "$1"; [ -z "$2" ] || printf 'caused_by=%s\n' "$2"; } > "$STATE_DIR/$1.meta"
}

test_cause_records() {
  local state="$TMP_ROOT/records" out
  mkdir -p "$state"
  # shellcheck source=bin/fm-t3-cause-lib.sh
  out=$(FM_T3CODE_CAUSED_BY="$CAUSE_T" bash -c '. "$1"; fm_t3_cause_queue_record "$2" item-1 /nonexistent; fm_t3_cause_queued "$2" item-1' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "$CAUSE_T" "$out" "a queued item keeps the cause of the turn that queued it"
  out=$(FM_T3CODE_CAUSED_BY='{"nope":1}' bash -c '. "$1"; fm_t3_cause_queue_record "$2" item-2 /nonexistent; echo "rc=$?"; fm_t3_cause_queued "$2" item-2' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "rc=0" "$out" "a malformed cause records nothing and never fails the add"
  out=$(bash -c '. "$1"; fm_t3_cause_of_task "$2" item-1' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "$CAUSE_T" "$out" "a task with no record yet has its queued cause"
  printf 'caused_by=%s\n' '{"threadId":"coord","messageId":"msg-w"}' > "$state/item-1.meta"
  out=$(bash -c '. "$1"; fm_t3_cause_of_task "$2" item-1' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals '{"threadId":"coord","messageId":"msg-w"}' "$out" "the task record's cause wins over the queued one"
  out=$(bash -c '. "$1"; fm_t3_cause_landed_record "$2" item-1; fm_t3_cause_landed "$2"' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals '{"threadId":"coord","messageId":"msg-w"}' "$out" "a landing keeps the landed task's cause"
  out=$(bash -c '. "$1"; fm_t3_cause_landed_record "$2" item-9; fm_t3_cause_landed "$2"' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "" "$out" "a later landing with no cause leaves none, never an older task's"
  bash -c '. "$1"; fm_t3_cause_queue_forget "$2" item-1' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state"
  [ ! -e "$state/item-1.queued-cause" ] || fail "forget drops the queued record"
  out=$(bash -c '. "$1"; fm_t3_cause_of_task "$2" ../item-1' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "" "$out" "a task id that is not a plain name reads nothing"
  printf 'caused_by=%s\n' "$CAUSE_T" > "$state/pr-task.meta"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$TMP_ROOT" "$state" pr-task https://github.com/o/r/pull/7 self >/dev/null 2>&1
  ) || fail "the PR merge outcome was not recorded"
  out=$(bash -c '. "$1"; fm_t3_cause_landed "$2"' _ "$ROOT/bin/fm-t3-cause-lib.sh" "$state")
  assert_equals "$CAUSE_T" "$out" "a PR merge keeps its task's cause as the latest landed cause"
  pass "fm-t3-cause-lib: queued, task, and latest landed causes are recorded, read, and dropped, a PR merge included"
}

test_wake_claims_the_first_caused_task_and_keeps_it() {
  fresh_case wake-task
  meta_with_cause uncaused ''
  meta_with_cause tk "$CAUSE_T"
  as_agent "$CLAIM" wake --task gone --task uncaused --task tk
  expect_code 0 "$RC" "a wake claim exits 0: $ERR"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "the turn counts to the first named task that has a cause"
  assert_grep "$(printf 'coord\trun-c')" "$STATE_DIR/.t3-usage-claimed-runs" "the claimed turn is remembered"
  settle_sweep
  as_agent "$CLAIM" wake
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a later drain in the same turn keeps the first claim"
  as_agent "$CLAIM" turn --device phone
  expect_code 0 "$RC" "an explicit turn claim exits 0: $ERR"
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "an explicit claim replaces the drain's, such as a voice journal's"
  as_agent "$CLAIM" wake --task tk
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "and a later drain leaves it"
  pass "fm-t3-usage-claim wake: the first caused task wins, the first claim of a turn stands, the sweep marks the rest, and turn replaces"
}

test_wake_about_nothing_is_upkeep_and_uncaused_tasks_count_to_the_computer() {
  fresh_case wake-upkeep
  as_agent "$CLAIM" wake
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "a wake about no task counts to the computer"
  settle_sweep
  fresh_case wake-uncaused
  meta_with_cause old-task ''
  as_agent "$CLAIM" wake --task old-task
  expect_code 0 "$RC" "an uncaused wake exits 0: $ERR"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "a wake about tasks with no cause falls back to the computer"
  assert_grep "$(printf 'coord\trun-c')" "$STATE_DIR/.t3-usage-claimed-runs" "and the turn is marked handled"
  settle_sweep
  fresh_case wake-note
  as_agent "$CLAIM" wake --caused-by "$CAUSE_T"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a cause given, such as an inbox note's, is claimed"
  pass "fm-t3-usage-claim wake: upkeep and a wake about tasks with no cause count to the computer"
}

test_claims_are_best_effort_and_logged_once() {
  fresh_case claim-fails '{"causedBy":true,"usageClaims":true,"failTools":{"t3_usage_claim":{"code":"unavailable","message":"down"}}}'
  as_agent "$CLAIM" wake
  expect_code 0 "$RC" "a failed claim never fails its caller"
  assert_equals 1 "$(awk 'END { print NR }' "$STATE_DIR/t3-usage-claims.log")" "a failed call is logged once: $(cat "$STATE_DIR/t3-usage-claims.log")"
  assert_grep "unavailable: " "$STATE_DIR/t3-usage-claims.log" "the log names T3's error: $(cat "$STATE_DIR/t3-usage-claims.log")"
  sleep 1
  assert_equals 1 "$(t3_fake_calls t3_usage_claim | awk 'END { print NR }')" "a failed turn claim skips the sweep"
  fresh_case claim-unsupported '{"causedBy":true}'
  as_agent "$CLAIM" wake
  expect_code 0 "$RC" "a T3 without usage claims is not a failure"
  rm -f "$CONFIG_DIR/t3code-token"
  as_agent "$CLAIM" wake
  expect_code 0 "$RC" "a home with no T3 credential claims nothing"
  as_agent env -u T3CODE_THREAD_ID "$CLAIM" wake
  expect_code 0 "$RC" "no T3 turn claims nothing"
  as_agent "$CLAIM" turn --device tablet
  expect_code 2 "$RC" "an unknown device is invalid use"
  as_agent "$CLAIM" bogus
  expect_code 2 "$RC" "an unknown verb is invalid use"
  pass "fm-t3-usage-claim: failures are logged once and never fail the caller; no credential or turn claims nothing"
}

test_session_claims_the_engine_conversation() {
  fresh_case session
  meta_with_cause tk "$CAUSE_T"
  "$CLAIM" session sess-1 --task tk
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims session:sess-1)" "an engine session counts to the woken task's cause"
  "$CLAIM" session sess-2
  assert_equals '{"device":"computer"}' "$(claims session:sess-2)" "an engine session about no task counts to the computer"
  meta_with_cause old ''
  "$CLAIM" session sess-3 --task old
  assert_equals "" "$(claims session:sess-3)" "an engine session about an uncaused task is left alone"
  pass "fm-t3-usage-claim session: the engine's conversation counts to its task's cause, or the computer for no task"
}

test_session_claims_split_a_resumed_conversation_by_turn() {
  fresh_case session-from '{"causedBy":true,"usageClaims":true,"usageClaimFrom":true}'
  meta_with_cause tk "$CAUSE_T"
  "$CLAIM" session sess-1 --from 2026-11-16T09:00:00Z --task tk
  "$CLAIM" session sess-1 --from 2026-11-16T09:05:00Z
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims session:sess-1@1794819600000)" "the first turn's claim stands from its start"
  assert_equals '{"device":"computer"}' "$(claims session:sess-1@1794819900000)" "the next turn's claim is kept beside it from its own start"
  assert_equals "" "$(claims session:sess-1)" "no whole-session claim is made"
  fresh_case session-from-absent
  "$CLAIM" session sess-1 --from 2026-11-16T09:00:00Z
  assert_equals '{"device":"computer"}' "$(claims session:sess-1)" "a T3 whose claim takes no start gets the whole-session claim"
  "$CLAIM" session sess-1 --from not-a-time
  assert_equals 0 "$?" "a start T3 cannot read never fails the caller"
  assert_contains "$(cat "$STATE_DIR/t3-usage-claims.log" 2>/dev/null)" "session sess-1" "and is logged once"
  pass "fm-t3-usage-claim session --from: a resumed conversation splits by turn start, and an older T3 keeps the whole-session claim"
}

# make_nm <dir> <run-id> <branch> [db]: a git worktree on <branch>, a stub
# no-mistakes reporting run <run-id> on it, and an NM_HOME whose run folder is
# found through the state database ("db") or the folder layout.
make_nm() {
  local dir=$1 id=$2 branch=$3
  mkdir -p "$dir/wt" "$dir/bin" "$dir/nm/worktrees/repohash/$id"
  git -C "$dir/wt" init -q -b "$branch"
  git -C "$dir/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  cat > "$dir/bin/no-mistakes" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "axi status" ] || exit 1
printf 'current_branch: %s\n' "\$(git rev-parse --abbrev-ref HEAD)"
printf '%s\n  id: "%s"\n  branch: %s\n  status: running\n' "\${NM_STUB_KEY:-run:}" "$id" "\${NM_STUB_BRANCH:-$branch}"
SH
  chmod +x "$dir/bin/no-mistakes"
  if [ "${4:-}" = db ]; then
    sqlite3 "$dir/nm/state.sqlite" "create table runs (id text primary key, worktree_dir text); insert into runs values ('$id', '/db/says/$id');"
  fi
}

test_pipeline_claims_the_branch_run_folder() {
  local dir="$TMP_ROOT/nm" before
  fresh_case pipeline
  meta_with_cause tk "$CAUSE_T"
  make_nm "$dir" 01RUNA fm/tk
  OUT=$(PATH="$dir/bin:$PATH" NM_HOME="$dir/nm" "$CLAIM" pipeline --task tk --worktree "$dir/wt" 2>&1)
  assert_contains "$OUT" "claimed $dir/nm/worktrees/repohash/01RUNA for tk" "the run's folder is claimed: $OUT"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims "directory:$dir/nm/worktrees/repohash/01RUNA")" "it counts to the task's cause"
  if command -v sqlite3 >/dev/null 2>&1; then
    rm -rf "$dir"
    make_nm "$dir" 01RUNB fm/tk db
    PATH="$dir/bin:$PATH" NM_HOME="$dir/nm" "$CLAIM" pipeline --task tk --worktree "$dir/wt" >/dev/null 2>&1
    assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims directory:/db/says/01RUNB)" "no-mistakes' own record of the folder wins"
  fi
  rm -rf "$dir"
  make_nm "$dir" 01RUNC fm/tk
  before=$(t3_fake_calls t3_usage_claim | awk 'END { print NR }')
  OUT=$(PATH="$dir/bin:$PATH" NM_HOME="$dir/nm" NM_STUB_KEY=other_branch_run: NM_STUB_BRANCH=fm/other "$CLAIM" pipeline --task tk --worktree "$dir/wt" 2>&1)
  assert_contains "$OUT" "no no-mistakes run of this branch" "another branch's run is never claimed"
  meta_with_cause none ''
  OUT=$(PATH="$dir/bin:$PATH" NM_HOME="$dir/nm" "$CLAIM" pipeline --task none --worktree "$dir/wt" 2>&1)
  assert_contains "$OUT" "has no recorded cause" "a task with no cause claims nothing"
  assert_equals "$before" "$(t3_fake_calls t3_usage_claim | awk 'END { print NR }')" "neither of those reached T3"
  pass "fm-t3-usage-claim pipeline: the branch's no-mistakes run folder counts to the task's cause, and nothing else is claimed"
}

test_drain_claims_the_wake_turn() {
  local out="$TMP_ROOT/drain.out"
  fresh_case drain
  meta_with_cause tk "$CAUSE_T"
  append_wake "$STATE_DIR" check "heartbeat-like-upkeep" "check: rearm-resurface"
  append_wake "$STATE_DIR" signal tk.status "signal: tk.status"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "the drain claims its wake turn for the worker the wake is about"
  fresh_case drain-inactive
  meta_with_cause child-1 "$CAUSE_T"
  append_wake "$STATE_DIR" check "inactive-outcome:abc" "inactive terminal outcome awaiting captain presentation: child=child-1 state=done"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "an inactive outcome claims for its child"
  fresh_case drain-turn-ended
  meta_with_cause tk "$CAUSE_T"
  append_wake "$STATE_DIR" signal tk.turn-ended "signal: tk.turn-ended"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a lone turn-ended row claims for its task, not the computer or an empty claim"
  fresh_case drain-empty
  as_agent "$DRAIN"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "a drain with nothing about a task claims the computer"
  fresh_case drain-outside
  append_wake "$STATE_DIR" signal tk.status "signal: tk.status"
  "$DRAIN" > "$out" 2>&1
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a drain outside a T3 turn claims nothing"
  pass "fm-wake-drain: a T3 wake turn is claimed for the task its first wake names, or the computer for upkeep"
}

# when_spec <name> [cause-json]: a condition->action follow-up's spec, with the
# caused_by= line bin/fm-procevent-when.sh arm records when it has a cause.
when_spec() {
  mkdir -p "$STATE_DIR/when"
  { printf 'fm-when-spec-v1\narmed=1\n'; [ -z "${2:-}" ] || printf 'caused_by=%s\n' "$2"; printf 'argv:\ncaused_by=not-a-cause\n'; } > "$STATE_DIR/when/when-$1.spec"
}

test_drain_claims_a_followups_arming_cause() {
  fresh_case drain-when
  when_spec promo "$CAUSE_T"
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a fired follow-up's wake counts to the prompt that armed it"
  settle_sweep
  fresh_case drain-when-nocause
  when_spec promo ''
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "a follow-up armed with no cause stays upkeep, and argv text is never read as a cause"
  settle_sweep
  fresh_case drain-when-gone
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "a follow-up whose spec is gone stays upkeep"
  settle_sweep
  fresh_case drain-other-procevent
  append_wake "$STATE_DIR" check "procevent:lavish-x:1" "check: procevent lavish lavish-x 1"
  as_agent "$DRAIN"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "any other process-event result stays upkeep"
  pass "fm-wake-drain: a fired follow-up's wake counts to the prompt that armed it, and upkeep otherwise"
}

inbox_note() {  # <id> <header-line...>: a saved inbox note with those header lines
  local id=$1
  shift
  mkdir -p "$STATE_DIR/inbox"
  { printf 'id=%s\nsource=text\n' "$id"; printf '%s\n' "$@"; printf -- '--\nmade-up body\n'; } > "$STATE_DIR/inbox/$id.note"
}

test_drain_claims_a_voice_journal_note_for_the_phone() {
  fresh_case drain-journal
  inbox_note 1-journal request_id=voice-journal-2026-11-16 "caused-by=$CAUSE_T"
  append_wake "$STATE_DIR" check "inbox:1-journal" "check: captain inbox note 1-journal - journal"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "a voice journal's note counts to the phone, whatever cause it carries"
  settle_sweep
  fresh_case drain-note
  inbox_note 1-note request_id=export-1 "caused-by=$CAUSE_T"
  append_wake "$STATE_DIR" check "inbox:1-note" "check: captain inbox note 1-note - note"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "any other note keeps the cause it recorded"
  pass "fm-wake-drain: a voice journal's inbox note claims its wake turn for the phone"
}

test_folder_claims_a_tasks_data_folder() {
  fresh_case folder
  meta_with_cause tk "$CAUSE_T"
  "$CLAIM" folder "$HOME_DIR/data/tk" --task tk
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims "directory:$HOME_DIR/data/tk")" "the folder counts to the task's cause"
  meta_with_cause none ''
  "$CLAIM" folder "$HOME_DIR/data/none" --task none
  assert_equals "" "$(claims "directory:$HOME_DIR/data/none")" "a task with no cause claims nothing"
  "$CLAIM" folder data/tk --task tk 2>/dev/null
  expect_code 2 "$?" "a relative folder is invalid use"
  pass "fm-t3-usage-claim folder: a task's folder counts to its cause, and nothing without one"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_cause_records \
  test_wake_claims_the_first_caused_task_and_keeps_it \
  test_wake_about_nothing_is_upkeep_and_uncaused_tasks_count_to_the_computer \
  test_folder_claims_a_tasks_data_folder \
  test_drain_claims_a_voice_journal_note_for_the_phone \
  test_claims_are_best_effort_and_logged_once \
  test_session_claims_the_engine_conversation \
  test_session_claims_split_a_resumed_conversation_by_turn \
  test_pipeline_claims_the_branch_run_folder \
  test_drain_claims_the_wake_turn \
  test_drain_claims_a_followups_arming_cause
