#!/usr/bin/env bash
# tests/fm-t3-usage-claim.test.sh - bin/fm-t3-usage-claim.sh, Firstmate's
# usage claims on T3 Code, and the records it reads from
# bin/fm-t3-origin-lib.sh: driven through its CLI, and through
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
REF_T='{"threadId":"coord","at":"2026-11-15T00:00:30.000Z"}'
ORIGIN_LIB="$ROOT/bin/fm-t3-origin-lib.sh"
mkdir -p "$STATE_DIR" "$CONFIG_DIR"
# The drain's BRANCH OUTCOMES section stays out of these cases.
: > "$CONFIG_DIR/supervision-host-off"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_CONFIG_OVERRIDE="$CONFIG_DIR"

# fresh_case <name> [world-json]: a fresh fake world holding thread coord: a
# finished human turn run-old (prompt msg-old), a finished wake turn run-w
# (notification msg-w), and the active wake turn run-c (notification msg-c),
# started a minute ago; worker threads t-tk (work counting to the phone) and
# t-lost (work counting to no device); plus a fresh state directory.
# shellcheck disable=SC2016  # ${...} belongs to the JavaScript snippet.
fresh_case() {
  t3_fake_case "$TMP_ROOT/cases/$1" "${2:-{\"causedBy\":true,\"usageClaims\":true,\"fromThread\":true\}}"
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
    run("run-c", 3, "running", "msg-c", process.env.FM_AT, null)] } };
const worker = (id) => ({ threadId: id, projectId: "p", title: id, status: "idle", activeRunId: null, archived: false, items: [], runs: [] });
w.threads["t-tk"] = worker("t-tk");
w.threads["t-lost"] = worker("t-lost");
w.origins = { "t-tk": "phone", "t-lost": null };'
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

# claim_of <key> <field>: one field of the stored claim.
claim_of() {
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = ((w.usageClaims || {})[process.argv[2]] || {})[process.argv[3]]; if (v != null) process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));' "$T3_FAKE_WORLD" "$1" "$2"
}

meta_with_thread() {  # <task> <t3-thread-id|empty>
  { printf 'window=t3code:%s\n' "$1"; [ -z "$2" ] || printf 't3_thread_id=%s\n' "$2"; } > "$STATE_DIR/$1.meta"
}

lib() {  # <state-dir> <snippet>: run <snippet> with the origin library sourced
  bash -c '. "$1"; state=$2; eval "$3"' _ "$ORIGIN_LIB" "$1" "$2"
}

# shellcheck disable=SC2016  # $state and $1 belong to the snippets lib runs.
test_origin_records() {
  local state="$TMP_ROOT/records" out rc
  mkdir -p "$state"
  out=$(env -u T3CODE_THREAD_ID bash -c '. "$1"; fm_t3_origin_resolve' _ "$ORIGIN_LIB")
  assert_equals "" "$out" "a process in no T3 thread has no reference"
  out=$(T3CODE_THREAD_ID=coord bash -c '. "$1"; fm_t3_origin_resolve' _ "$ORIGIN_LIB")
  assert_equals coord "$(printf '%s' "$out" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).threadId)')" "this thread, now, names the calling thread"
  printf '%s' "$out" | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")); if (Object.keys(d).join() !== "threadId,at" || Math.abs(Date.parse(d.at) - Date.now()) > 60000) process.exit(1)' \
    || fail "this thread, now, carries the time it was written: $out"
  out=$(T3CODE_THREAD_ID=coord FM_T3_FROM_THREAD=off bash -c '. "$1"; fm_t3_origin_resolve' _ "$ORIGIN_LIB")
  assert_equals "" "$out" "off names nothing"
  out=$(FM_T3_FROM_THREAD='{"at":"2026-11-15T11:00:30+11:00","threadId":"coord"}' bash -c '. "$1"; fm_t3_origin_resolve' _ "$ORIGIN_LIB")
  assert_equals "$REF_T" "$out" "a reference given is used, in order and in UTC"
  out=$(FM_T3_FROM_THREAD="$CAUSE_T" bash -c '. "$1"; fm_t3_origin_resolve' _ "$ORIGIN_LIB" 2>&1); rc=$?
  expect_code 2 "$rc" "a cause is not a reference"
  assert_contains "$out" "FM_T3_FROM_THREAD must be off" "and the refusal says what is accepted"
  out=$(FM_T3_FROM_THREAD="$REF_T" lib "$state" 'fm_t3_origin_queue_record "$state" item-1; fm_t3_origin_queued "$state" item-1')
  assert_equals "$REF_T" "$out" "a queued item keeps the reference of the turn that queued it"
  out=$(FM_T3_FROM_THREAD='{"nope":1}' lib "$state" 'fm_t3_origin_queue_record "$state" item-2; echo "rc=$?"; fm_t3_origin_queued "$state" item-2' 2>/dev/null)
  assert_equals "rc=0" "$out" "a malformed reference records nothing and never fails the add"
  printf '%s\n' "$CAUSE_T" > "$state/item-3.queued-cause"
  out=$(lib "$state" 'fm_t3_origin_queued "$state" item-3')
  assert_equals "$CAUSE_T" "$out" "an item queued before references existed keeps its cause"
  out=$(lib "$state" 'fm_t3_origin_of_task "$state" item-1')
  assert_equals "$REF_T" "$out" "a task with no thread yet has its queued reference"
  printf 't3_thread_id=%s\n' t-1 > "$state/item-1.meta"
  out=$(lib "$state" 'fm_t3_origin_of_task "$state" item-1')
  assert_equals '{"threadId":"t-1"}' "$out" "a task with a thread names that thread, with no time"
  printf '%s\n' "x	old	$CAUSE_T" > "$state/t3-landed-cause"
  out=$(lib "$state" 'fm_t3_origin_landed_record "$state" item-1; fm_t3_origin_landed "$state"')
  assert_equals '{"threadId":"t-1"}' "$out" "a landing keeps the landed task's thread"
  [ ! -e "$state/t3-landed-cause" ] || fail "a landing drops the cause file kept before references existed"
  out=$(lib "$state" 'fm_t3_origin_landed_record "$state" item-9; fm_t3_origin_landed "$state"')
  assert_equals "" "$out" "a later landing with no thread leaves none, never an older task's"
  lib "$state" 'fm_t3_origin_queue_forget "$state" item-1; fm_t3_origin_queue_forget "$state" item-3'
  [ ! -e "$state/item-1.queued-origin" ] && [ ! -e "$state/item-3.queued-cause" ] || fail "forget drops the queued records of both kinds"
  out=$(lib "$state" 'fm_t3_origin_of_task "$state" ../item-1')
  assert_equals "" "$out" "a task id that is not a plain name reads nothing"
  assert_equals "--caused-by --from-thread" "$(lib "$state" "fm_t3_origin_flag '$CAUSE_T'; printf ' '; fm_t3_origin_flag '$REF_T'")" \
    "a cause is sent as causedBy and a reference as fromThread"
  printf 't3_thread_id=%s\n' t-pr > "$state/pr-task.meta"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    fm_merge_outcome_report "$TMP_ROOT" "$state" pr-task https://github.com/o/r/pull/7 self >/dev/null 2>&1
  ) || fail "the PR merge outcome was not recorded"
  out=$(lib "$state" 'fm_t3_origin_landed "$state"')
  assert_equals '{"threadId":"t-pr"}' "$out" "a PR merge keeps its task's thread as the latest landed origin"
  pass "fm-t3-origin-lib: this thread now, queued, task, and latest landed references are recorded, read, and dropped, a PR merge included"
}

test_wake_tries_candidates_until_one_binds() {
  fresh_case wake-task
  meta_with_thread unbound ''
  meta_with_thread lost t-lost
  meta_with_thread tk t-tk
  meta_with_thread lost-again t-lost
  as_agent "$CLAIM" wake --task gone --task unbound --task lost --task lost --task lost-again --task tk
  expect_code 0 "$RC" "a wake claim exits 0: $ERR"
  assert_equals phone "$(claim_of run:coord:run-c device)" "the turn counts with the first named task T3 binds: $(claims run:coord:run-c)"
  assert_equals '{"threadId":"t-tk"}' "$(claim_of run:coord:run-c fromThread)" "named by that task's own thread, with no time"
  assert_equals 2 "$(t3_fake_calls t3_usage_claim | awk 'END { print NR }')" "a task with no thread is skipped, one T3 refuses gives the next its turn, and a thread already refused is not asked again"
  assert_equals "" "$(t3_fake_calls t3_usage_claim | head -n 1 | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).runId ?? ""))')" "the turn is named by the thread alone"
  [ ! -s "$STATE_DIR/t3-usage-claims.log" ] || fail "a wake that names its turn logs nothing: $(cat "$STATE_DIR/t3-usage-claims.log")"
  as_agent "$CLAIM" wake --device computer
  assert_equals phone "$(claim_of run:coord:run-c device)" "a later drain in the same turn keeps the first claim"
  assert_equals true "$(t3_fake_calls t3_usage_claim | tail -n 1 | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).ifUnclaimed))')" "because the drain asks T3 to keep it"
  assert_equals "" "$(claims run:coord:run-w)$(claims run:coord:run-old)" "and no other turn of the thread is claimed"
  as_agent "$CLAIM" turn --device computer
  expect_code 0 "$RC" "an explicit turn claim exits 0: $ERR"
  assert_equals '{"device":"computer"}' "$(claims run:coord:run-c)" "an explicit claim replaces the drain's"
  as_agent "$CLAIM" turn --task tk
  assert_equals '{"threadId":"t-tk"}' "$(claim_of run:coord:run-c fromThread)" "a turn claim can name a task's work"
  as_agent "$CLAIM" turn --from-thread "$REF_T"
  assert_equals "$REF_T" "$(claim_of run:coord:run-c fromThread)" "or a reference, sent untouched"
  as_agent "$CLAIM" wake --task tk
  assert_equals "$REF_T" "$(claim_of run:coord:run-c fromThread)" "and a later drain leaves it"
  pass "fm-t3-usage-claim wake: candidates are tried in order until T3 binds one, the first claim of a turn stands, and turn replaces"
}

test_wake_about_nothing_claims_nothing() {
  fresh_case wake-upkeep
  as_agent "$CLAIM" wake
  expect_code 0 "$RC" "an upkeep wake exits 0: $ERR"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a wake about no task claims nothing, so T3 files it as upkeep"
  fresh_case wake-unbound
  meta_with_thread old-task ''
  as_agent "$CLAIM" wake --task old-task
  expect_code 0 "$RC" "a wake about a task with no thread exits 0: $ERR"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a wake about tasks with no thread claims nothing either"
  fresh_case wake-note
  as_agent "$CLAIM" wake --from-thread "$REF_T"
  assert_equals "$REF_T" "$(claim_of run:coord:run-c fromThread)" "a reference given, such as an inbox note's, is claimed"
  fresh_case wake-old-note
  as_agent "$CLAIM" wake --caused-by "$CAUSE_T"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a cause recorded before references existed is passed on unchanged"
  pass "fm-t3-usage-claim wake: upkeep and a wake about tasks with no thread claim nothing"
}

test_claims_are_best_effort_and_logged_once() {
  fresh_case none-binds
  meta_with_thread lost t-lost
  as_agent "$CLAIM" wake --task lost --from-thread '{"threadId":"gone"}'
  expect_code 0 "$RC" "a wake none of whose candidates binds exits 0: $ERR"
  assert_equals "" "$(claims run:coord:run-c)" "and claims nothing"
  assert_equals 1 "$(awk 'END { print NR }' "$STATE_DIR/t3-usage-claims.log")" "a wake that fails to name its turn is logged once: $(cat "$STATE_DIR/t3-usage-claims.log")"
  assert_grep "no candidate bound" "$STATE_DIR/t3-usage-claims.log" "the log says no candidate bound: $(cat "$STATE_DIR/t3-usage-claims.log")"
  fresh_case claim-fails '{"causedBy":true,"usageClaims":true,"fromThread":true,"failTools":{"t3_usage_claim":{"code":"unavailable","message":"down"}}}'
  as_agent "$CLAIM" wake --device phone --device computer
  expect_code 0 "$RC" "a failed claim never fails its caller"
  assert_equals 1 "$(awk 'END { print NR }' "$STATE_DIR/t3-usage-claims.log")" "a failed call is logged once, and not retried with the next candidate: $(cat "$STATE_DIR/t3-usage-claims.log")"
  assert_grep "unavailable: " "$STATE_DIR/t3-usage-claims.log" "the log names T3's error: $(cat "$STATE_DIR/t3-usage-claims.log")"
  as_agent "$CLAIM" turn --device phone
  assert_equals 2 "$(awk 'END { print NR }' "$STATE_DIR/t3-usage-claims.log")" "a failed turn claim is logged too: $(cat "$STATE_DIR/t3-usage-claims.log")"
  fresh_case claim-unsupported '{"causedBy":true}'
  meta_with_thread tk t-tk
  as_agent "$CLAIM" wake --task tk --device phone
  expect_code 0 "$RC" "a T3 without usage claims is not a failure"
  [ ! -s "$STATE_DIR/t3-usage-claims.log" ] || fail "an absent feature is not logged: $(cat "$STATE_DIR/t3-usage-claims.log")"
  fresh_case claim-no-keep '{"causedBy":true,"usageClaims":true,"fromThread":true,"noIfUnclaimed":true}'
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
  as_agent "$CLAIM" turn --caused-by "$CAUSE_T"
  expect_code 2 "$RC" "a turn claim names a device, a task, or a reference, not a cause"
  as_agent "$CLAIM" bogus
  expect_code 2 "$RC" "an unknown verb is invalid use"
  pass "fm-t3-usage-claim: failures are logged once and never fail the caller; no credential or turn claims nothing"
}

test_drain_claims_the_wake_turn() {
  local out="$TMP_ROOT/drain.out"
  fresh_case drain
  meta_with_thread tk t-tk
  append_wake "$STATE_DIR" check "heartbeat-like-upkeep" "check: rearm-resurface"
  append_wake "$STATE_DIR" signal tk.status "signal: tk.status"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals '{"threadId":"t-tk"}' "$(claim_of run:coord:run-c fromThread)" "the drain claims its wake turn with the work of the worker the wake is about"
  fresh_case drain-inactive
  meta_with_thread child-1 t-tk
  append_wake "$STATE_DIR" check "inactive-outcome:abc" "inactive terminal outcome awaiting captain presentation: child=child-1 state=done"
  as_agent "$DRAIN"
  assert_equals '{"threadId":"t-tk"}' "$(claim_of run:coord:run-c fromThread)" "an inactive outcome claims for its child"
  fresh_case drain-turn-ended
  meta_with_thread tk t-tk
  append_wake "$STATE_DIR" signal tk.turn-ended "signal: tk.turn-ended"
  as_agent "$DRAIN"
  assert_equals '{"threadId":"t-tk"}' "$(claim_of run:coord:run-c fromThread)" "a lone turn-ended row claims for its task, not the computer or an empty claim"
  fresh_case drain-empty
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a drain with nothing about a task claims nothing, so T3 files it as upkeep"
  fresh_case drain-outside
  append_wake "$STATE_DIR" signal tk.status "signal: tk.status"
  "$DRAIN" > "$out" 2>&1
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a drain outside a T3 turn claims nothing"
  pass "fm-wake-drain: a T3 wake turn is claimed with the work of the task its first wake names, or left to T3 as upkeep"
}

# when_spec <name> [field=value]: a condition->action follow-up's spec, with
# the from_thread= (or, armed before references existed, caused_by=) line
# bin/fm-procevent-when.sh arm records.
when_spec() {
  mkdir -p "$STATE_DIR/when"
  { printf 'fm-when-spec-v1\narmed=1\n'; [ -z "${2:-}" ] || printf '%s\n' "$2"; printf 'argv:\nfrom_thread=not-a-reference\n'; } > "$STATE_DIR/when/when-$1.spec"
}

test_drain_claims_a_followups_arming_origin() {
  fresh_case drain-when
  when_spec promo "from_thread=$REF_T"
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals "$REF_T" "$(claim_of run:coord:run-c fromThread)" "a fired follow-up's wake counts with the turn that armed it"
  fresh_case drain-when-old
  when_spec promo "caused_by=$CAUSE_T"
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a follow-up armed before references existed passes its cause on"
  fresh_case drain-when-none
  when_spec promo ''
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a follow-up armed outside T3 stays upkeep, and argv text is never read as a reference"
  fresh_case drain-when-gone
  append_wake "$STATE_DIR" check "procevent:when-promo:1" "check: procevent when when-promo 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "a follow-up whose spec is gone stays upkeep"
  fresh_case drain-other-procevent
  append_wake "$STATE_DIR" check "procevent:lavish-x:1" "check: procevent lavish lavish-x 1"
  as_agent "$DRAIN"
  assert_equals "" "$(t3_fake_calls t3_usage_claim)" "any other process-event result stays upkeep"
  pass "fm-wake-drain: a fired follow-up's wake counts with the turn that armed it, and upkeep otherwise"
}

inbox_note() {  # <id> <header-line...>: a saved inbox note with those header lines
  local id=$1
  shift
  mkdir -p "$STATE_DIR/inbox"
  { printf 'id=%s\nsource=text\n' "$id"; printf '%s\n' "$@"; printf -- '--\nmade-up body\n'; } > "$STATE_DIR/inbox/$id.note"
}

test_drain_claims_inbox_notes() {
  fresh_case drain-journal
  inbox_note 1-journal request_id=voice-journal-2026-11-16 "from-thread=$REF_T"
  append_wake "$STATE_DIR" check "inbox:1-journal" "check: captain inbox note 1-journal - journal"
  as_agent "$DRAIN"
  assert_contains "$ERR" "WAKE_ACK_REQUIRED" "the drain presents as before: $ERR"
  assert_equals '{"device":"phone"}' "$(claims run:coord:run-c)" "a voice journal's note counts to the phone, whatever origin it carries"
  fresh_case drain-note
  inbox_note 1-note request_id=export-1 "from-thread=$REF_T"
  append_wake "$STATE_DIR" check "inbox:1-note" "check: captain inbox note 1-note - note"
  as_agent "$DRAIN"
  assert_equals "$REF_T" "$(claim_of run:coord:run-c fromThread)" "any other note counts with the turn that wrote it"
  fresh_case drain-old-note
  inbox_note 1-old request_id=export-2 "caused-by=$CAUSE_T"
  append_wake "$STATE_DIR" check "inbox:1-old" "check: captain inbox note 1-old - note"
  as_agent "$DRAIN"
  assert_equals "{\"causedBy\":$CAUSE_T}" "$(claims run:coord:run-c)" "a note written before references existed passes its cause on"
  pass "fm-wake-drain: an inbox note's wake counts with the turn that wrote it, a voice journal's to the phone"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_origin_records \
  test_wake_tries_candidates_until_one_binds \
  test_wake_about_nothing_claims_nothing \
  test_drain_claims_inbox_notes \
  test_claims_are_best_effort_and_logged_once \
  test_drain_claims_the_wake_turn \
  test_drain_claims_a_followups_arming_origin
