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
  as_agent "$CLAIM" wake --device phone
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a later drain in the same turn keeps the first claim"
  assert_equals true "$(t3_fake_calls t3_usage_claim | tail -n 1 | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).ifUnclaimed))')" "because the drain asks T3 to keep it"
  assert_equals "" "$(claims run:coord:run-w)$(claims run:coord:run-old)" "and no other turn of the thread is claimed"
  [ ! -e "$STATE_DIR/.t3-usage-claimed-runs" ] || fail "no claimed-turns list is kept"
  as_agent "$CLAIM" turn --device phone
  expect_code 0 "$RC" "an explicit turn claim exits 0: $ERR"
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "an explicit claim replaces the drain's, such as a voice journal's"
  as_agent "$CLAIM" wake --task tk
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "and a later drain leaves it"
  pass "fm-t3-usage-claim wake: the first caused task wins, the first claim of a turn stands, and turn replaces"
}

test_wake_about_nothing_claims_nothing() {
  fresh_case wake-upkeep
  as_agent "$CLAIM" wake
  expect_code 0 "$RC" "an upkeep wake exits 0: $ERR"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a wake about no task claims nothing, so T3 files it as upkeep"
  fresh_case wake-uncaused
  meta_with_cause old-task ''
  as_agent "$CLAIM" wake --task old-task
  expect_code 0 "$RC" "an uncaused wake exits 0: $ERR"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a wake about tasks with no cause claims nothing either"
  fresh_case wake-note
  as_agent "$CLAIM" wake --caused-by "$CAUSE_T"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a cause given, such as an inbox note's, is claimed"
  pass "fm-t3-usage-claim wake: upkeep and a wake about tasks with no cause claim nothing"
}

test_claims_are_best_effort_and_logged_once() {
  fresh_case claim-fails '{"causedBy":true,"usageClaims":true,"failTools":{"t3_usage_claim":{"code":"unavailable","message":"down"}}}'
  as_agent "$CLAIM" wake --device phone
  expect_code 0 "$RC" "a failed claim never fails its caller"
  assert_equals 1 "$(awk 'END { print NR }' "$STATE_DIR/t3-usage-claims.log")" "a failed call is logged once: $(cat "$STATE_DIR/t3-usage-claims.log")"
  assert_grep "unavailable: " "$STATE_DIR/t3-usage-claims.log" "the log names T3's error: $(cat "$STATE_DIR/t3-usage-claims.log")"
  fresh_case claim-unsupported '{"causedBy":true}'
  as_agent "$CLAIM" wake --device phone
  expect_code 0 "$RC" "a T3 without usage claims is not a failure"
  fresh_case claim-no-keep '{"causedBy":true,"usageClaims":true,"noIfUnclaimed":true}'
  as_agent "$CLAIM" wake --device phone
  expect_code 0 "$RC" "a T3 that cannot keep a claim is not a failure"
  assert_equals "" "$(claims run:coord:run-c)" "and the drain claims nothing there rather than replace"
  [ ! -s "$STATE_DIR/t3-usage-claims.log" ] || fail "an absent feature is not logged: $(cat "$STATE_DIR/t3-usage-claims.log")"
  rm -f "$CONFIG_DIR/t3code-token"
  as_agent "$CLAIM" wake --device phone
  expect_code 0 "$RC" "a home with no T3 credential claims nothing"
  as_agent env -u T3CODE_THREAD_ID "$CLAIM" wake --device phone
  expect_code 0 "$RC" "no T3 turn claims nothing"
  as_agent "$CLAIM" turn --device tablet
  expect_code 2 "$RC" "an unknown device is invalid use"
  as_agent "$CLAIM" bogus
  expect_code 2 "$RC" "an unknown verb is invalid use"
  pass "fm-t3-usage-claim: failures are logged once and never fail the caller; no credential or turn claims nothing"
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
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a drain with nothing about a task claims nothing, so T3 files it as upkeep"
  fresh_case drain-outside
  append_wake "$STATE_DIR" signal tk.status "signal: tk.status"
  "$DRAIN" > "$out" 2>&1
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a drain outside a T3 turn claims nothing"
  pass "fm-wake-drain: a T3 wake turn is claimed for the task its first wake names, or left to T3 as upkeep"
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
  fresh_case drain-when-nocause
  when_spec promo ''
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a follow-up armed with no cause stays upkeep, and argv text is never read as a cause"
  fresh_case drain-when-gone
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a follow-up whose spec is gone stays upkeep"
  fresh_case drain-other-procevent
  append_wake "$STATE_DIR" check "procevent:lavish-x:1" "check: procevent lavish lavish-x 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "any other process-event result stays upkeep"
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
  fresh_case drain-note
  inbox_note 1-note request_id=export-1 "caused-by=$CAUSE_T"
  append_wake "$STATE_DIR" check "inbox:1-note" "check: captain inbox note 1-note - note"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "any other note keeps the cause it recorded"
  pass "fm-wake-drain: a voice journal's inbox note claims its wake turn for the phone"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_cause_records \
  test_wake_claims_the_first_caused_task_and_keeps_it \
  test_wake_about_nothing_claims_nothing \
  test_drain_claims_a_voice_journal_note_for_the_phone \
  test_claims_are_best_effort_and_logged_once \
  test_drain_claims_the_wake_turn \
  test_drain_claims_a_followups_arming_cause
