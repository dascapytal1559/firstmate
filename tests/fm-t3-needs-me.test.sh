#!/usr/bin/env bash
# tests/fm-t3-needs-me.test.sh - the captain's T3 decision threads follow his
# open captain calls: bin/fm-captain-hold.sh context, bin/fm-t3-needs-me.sh
# sync, status, mentioned, and reply-task, driven through the real
# bin/fm-captain-hold.sh and tasks-axi backlogs against the fake T3 server.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

NEEDS_ME="$ROOT/bin/fm-t3-needs-me.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-needs-me)
t3_fake_start "$TMP_ROOT/server"
cleanup() {
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

FM_THREAD='mcp:00000000-0000-4000-8000-00000000f1f1'

# make_home <name> [world-js] -> HOME_DIR: a main home with the T3 credential,
# a backlog with rows w1 and w2, and a fake T3 whose project is rooted at the
# home and whose FirstMate thread is pinned as coordinator.
make_home() {
  local fakebin real
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  real=$(cd "$HOME_DIR" && pwd -P)
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fakebin=$(fm_fakebin "$HOME_DIR")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  t3_fake_case "$HOME_DIR/world"
  FM_T3_ROOT=$real FM_T3_FM=$FM_THREAD t3_fake_set '
    w.decisions = true; w.coordinatorRestartNote = true;
    w.projects = [{ id: "proj-fm", title: "firstmate", workspaceRoot: process.env.FM_T3_ROOT, defaultModelSelection: null, deletedAt: null }];
    w.threads = { [process.env.FM_T3_FM]: { threadId: process.env.FM_T3_FM, projectId: "proj-fm", title: "FirstMate",
      status: "completed", activeRunId: null, archived: false, worktreePath: null, coordinator: true, items: [], runs: [] } };'
  [ -z "${2:-}" ] || t3_fake_set "$2"
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  (cd "$HOME_DIR" && tasks-axi add w1 "Pick the print layout" --repo sample && tasks-axi add w2 "Buy the camera" --repo sample) >/dev/null \
    || fail "could not seed the backlog rows"
}

home_env() {
  env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

captain() {  # <hold-args...>
  home_env "$ROOT/bin/fm-captain-hold.sh" "$@"
}

needs_me() {  # <args...>
  home_env "$NEEDS_ME" "$@"
}

sync_now() {
  needs_me sync
}

# at <UTC-timestamp> <command...>: runs the command as if it were that time,
# for the backlog snapshot, a new hold's stamp, and the sync pass alike.
at() {
  local when=$1
  shift
  FM_SNAPSHOT_NOW=$when FM_CAPTAIN_HOLD_NOW=$when FM_NEEDS_ME_NOW=$(jq -n --arg t "$when" '$t | fromdateiso8601') "$@"
}

answer() {  # <task-id> [--release]
  local id=$1
  shift
  printf 'Buy it.\n' > "$HOME_DIR/decision"
  captain answer "$id" --decision-file "$HOME_DIR/decision" "$@" >/dev/null 2>&1
}

say() {  # <text> -> a message file
  printf '%s\n' "$1" > "$HOME_DIR/message"
  printf '%s' "$HOME_DIR/message"
}

# decision <task-id> <js-expression over t> -> that value of the task's one
# unarchived decision thread (or of its only one when every one is archived).
decision() {
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const all = Object.values(w.threads ?? {}).filter((t) => t.decisionOf && t.decision?.taskId === process.argv[2]);
const live = all.filter((t) => !t.archived);
const t = live.length ? live[live.length - 1] : all[all.length - 1];
const v = t === undefined ? undefined : eval(process.argv[3]);
process.stdout.write(v === undefined || v === null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
' "$T3_FAKE_WORLD" "$1" "$2"
}

decision_count() {  # [task-id]
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const id = process.argv[2];
process.stdout.write(String(Object.values(w.threads ?? {}).filter((t) => t.decisionOf && (!id || t.decision?.taskId === id)).length));
' "$T3_FAKE_WORLD" "${1:-}"
}

set_decision_thread() {  # <task-id> <js statement over t>
  FM_T3_TASK=$1 t3_fake_set "for (const t of Object.values(w.threads)) if (t.decisionOf && t.decision?.taskId === process.env.FM_T3_TASK) { $2 }"
}

# --- context ---------------------------------------------------------------

test_context_raise_update_and_guards() {
  make_home context
  local rec="$HOME_DIR/data/needs-me/w2.json" out rc
  out=$(captain context w2 --text-file "$(say 'Which camera?')" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a task that is not held takes no context: $out"
  assert_contains "$out" "not an open captain call" "the refusal says why"
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  mkdir -p "$HOME_DIR/data/camera"
  printf 'plan\n' > "$HOME_DIR/data/camera/report.md"
  printf 'Camera: three choices.\n\nA, B or C?\n' > "$HOME_DIR/raised.txt"
  captain context w2 --text-file "$HOME_DIR/raised.txt" --question "Which camera budget?" \
    --option "A: one camera" --detail "About A\$150" --option "B: two cameras" \
    --attach report=data/camera/report.md --label "sections 5-7" >/dev/null 2>&1 || fail "the raise should succeed"
  assert_equals "1" "$(jq -r '.revision' "$rec")" "the raise is revision 1"
  assert_equals "raised" "$(jq -r '.entries[0].kind' "$rec")" "the first entry is the raise"
  assert_equals "$(printf 'Camera: three choices.\n\nA, B or C?')" "$(jq -r '.entries[0].text' "$rec")" "the text is kept as sent"
  assert_equals "About A\$150" "$(jq -r '.options[0].detail' "$rec")" "a detail belongs to the option before it"
  assert_equals "null" "$(jq -r '.options[1].detail' "$rec")" "an option needs no detail"
  assert_equals "sections 5-7" "$(jq -r '.entries[0].attachments[0].label' "$rec")" "an attachment keeps its label"
  assert_equals "$(captain open w2 --identity | cut -d'#' -f1)" "$(jq -r '.holdSet' "$rec")" "the record belongs to this hold"
  captain context w2 --text-file "$HOME_DIR/raised.txt" --question "Which camera budget?" >/dev/null 2>&1 \
    || fail "an exact retry of the raise should succeed"
  assert_equals "1" "$(jq -r '.revision' "$rec")" "an exact retry changes nothing"
  out=$(captain context w2 --text-file "$(say 'Something else')" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a second, different raise is refused: $out"
  assert_contains "$out" "--changed" "the refusal points at --changed"
  captain context w2 --changed "The facts came in; only the purchase is left." \
    --text-file "$(say 'Buy one Reolink?')" --question "Buy the camera?" >/dev/null 2>&1 || fail "the update should succeed"
  assert_equals "2" "$(jq -r '.revision' "$rec")" "an update bumps the revision"
  assert_equals "update" "$(jq -r '.entries[1].kind' "$rec")" "the update is appended"
  assert_equals "The facts came in; only the purchase is left." "$(jq -r '.entries[1].changed' "$rec")" "it says what changed"
  assert_equals "Buy the camera?" "$(jq -r '.question' "$rec")" "a new question replaces the old one"
  assert_equals "2" "$(jq -r '.options | length' "$rec")" "options stay when none are given"
  captain context w2 --changed "The facts came in; only the purchase is left." --text-file "$HOME_DIR/message" >/dev/null 2>&1 \
    || fail "an exact retry of the update should succeed"
  assert_equals "2" "$(jq -r '.revision' "$rec")" "an exact retry of the update changes nothing"
  out=$(captain context w2 --changed "x" --text-file "$(say 'y')" --attach picture=data/none.png 2>&1)
  rc=$?
  expect_code 1 "$rc" "a missing picture is refused: $out"
  head -c 8193 /dev/zero | tr '\0' 'a' > "$HOME_DIR/big.txt"
  out=$(captain context w2 --changed "x" --text-file "$HOME_DIR/big.txt" 2>&1)
  rc=$?
  expect_code 1 "$rc" "text over 8192 bytes is refused: $out"
  local -a many=()
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do many+=(--option "choice $n"); done
  out=$(captain context w2 --changed "x" --text-file "$(say 'y')" "${many[@]}" 2>&1)
  rc=$?
  expect_code 1 "$rc" "more than 12 options do not fit a decision: $out"
  out=$(captain context w2 --changed "x" --text-file "$(say 'y')" --question "$(head -c 4001 /dev/zero | tr '\0' 'q')" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a question over 4000 characters does not fit: $out"
  assert_equals "2" "$(jq -r '.revision' "$rec")" "a refused write leaves the record"
  pass "fm-captain-hold.sh context: raises once, appends updates, and refuses what does not fit"
}

test_context_starts_over_on_a_new_hold() {
  make_home context-rehold
  local rec="$HOME_DIR/data/needs-me/w1.json"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  captain context w1 --text-file "$(say 'Grid or list?')" >/dev/null 2>&1 || fail "raise should succeed"
  captain context w1 --changed "A third layout came up" --text-file "$(say 'Grid, list, or cards?')" >/dev/null 2>&1 \
    || fail "update should succeed"
  answer w1 --release || fail "release should succeed"
  sleep 1
  captain hold w1 --reason "Pick the layout again" >/dev/null 2>&1 || fail "the second hold should succeed"
  captain context w1 --text-file "$(say 'Cards won; which size?')" >/dev/null 2>&1 || fail "a new raise should succeed"
  assert_equals "1" "$(jq '.entries | length' "$rec")" "the new hold starts a new record"
  assert_equals "3" "$(jq -r '.revision' "$rec")" "its revision keeps counting up"
  pass "fm-captain-hold.sh context: a task held again starts a new record"
}

# --- reply marker ----------------------------------------------------------

test_reply_marker() {
  local f="$TMP_ROOT/reply.txt" out rc
  printf '**Decision · Buy the camera**\nneeds-me-task: w2\n\n> Buy the camera?\n>\n> A or B?\n\nYes, buy it.\n' > "$f"
  assert_equals "w2" "$(home_env "$NEEDS_ME" reply-task "$f")" "the marker names the task"
  assert_equals "w2" "$(printf '> needs-me-task: w2\nyes\n' | "$NEEDS_ME" reply-task)" "a quoted marker reads from stdin"
  printf 'Just chatting, no marker.\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 1 "$rc" "no marker is not a reply: $out"
  printf 'needs-me-task: w1\nneeds-me-task: w2\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 2 "$rc" "two tasks are ambiguous: $out"
  printf 'needs-me-task: ../w1\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 2 "$rc" "a malformed id is refused: $out"
  pass "fm-t3-needs-me.sh reply-task: reads exactly one needs-me-task line"
}

# --- sync ------------------------------------------------------------------

test_hold_creates_an_agentless_decision() {
  make_home create
  captain hold w1 --reason "Grid or list for the print view?" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "1" "$(decision_count w1)" "the hold makes one decision thread"
  assert_equals "$FM_THREAD" "$(decision w1 't.decisionOf')" "it belongs to FirstMate's thread"
  assert_equals "proj-fm" "$(decision w1 't.projectId')" "in FirstMate's project"
  assert_equals "Pick the print layout" "$(decision w1 't.title')" "titled by the task"
  assert_equals "sample" "$(decision w1 't.decision.projectName')" "naming the task's repo as its project"
  assert_equals "true" "$(decision w1 '/^\d{4}-\d\d-\d\dT/.test(t.decision.since)')" "and when it started waiting"
  assert_equals "0" "$(decision w1 't.runs.length')" "no turn ran"
  assert_equals "Grid or list for the print view?" "$(decision w1 't.decision.question')" "the hold reason is the question"
  assert_equals "raised" "$(decision w1 't.decision.entries[0].kind')" "and its only entry"
  assert_equals "1" "$(decision w1 't.decision.revision')" "at revision 1, the first T3 accepts"
  assert_equals "false" "$(decision w1 't.settled === true || t.snoozed === true')" "it is active"
  assert_equals "1" "$(t3_fake_calls t3_thread_launch | jq -s 'map(select(.message == null and .decisionOf != null)) | length')" \
    "it was launched with no message"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a repeat sync should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a repeat pass changes nothing"
  assert_equals "1" "$(decision_count)" "and makes no second thread"
  pass "fm-t3-needs-me.sh: a hold makes one agent-less decision thread beside FirstMate"
}

test_context_updates_the_payload_and_marks_unread() {
  make_home update
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  set_decision_thread w2 't.unread = false;'
  captain context w2 --text-file "$(say 'Camera: A, B or C?')" --question "Which camera?" \
    --option "A" --option "B" --attach link=https://example.com/cx810 >/dev/null 2>&1 || fail "raise should succeed"
  assert_equals "2" "$(decision w2 't.decision.revision')" "the raise reaches the thread"
  assert_equals "Camera: A, B or C?" "$(decision w2 't.decision.entries[0].text')" "with the words as sent"
  assert_equals "Which camera?" "$(decision w2 't.decision.question')" "and the question"
  assert_equals '[{"label":"A"},{"label":"B"}]' "$(decision w2 't.decision.options')" "and the options"
  assert_equals "false" "$(decision w2 't.unread')" "recording the raise is not news"
  captain context w2 --changed "Only the purchase is left" --text-file "$(say 'Buy one?')" \
    --attach picture=config/t3code-token >/dev/null 2>&1 || fail "update should succeed"
  assert_equals "3" "$(decision w2 't.decision.revision')" "the update reaches the thread"
  assert_equals "Only the purchase is left" "$(decision w2 't.decision.entries[1].changed')" "with what changed"
  assert_equals "$(cd "$HOME_DIR" && pwd -P)/config/t3code-token" "$(decision w2 't.decision.entries[1].attachments[0].path')" \
    "a picture travels as an absolute path"
  assert_equals "true" "$(decision w2 't.unread')" "an update marks the thread unread"
  assert_equals "1" "$(decision_count)" "still one thread"
  pass "fm-t3-needs-me.sh: context reaches the thread, and an update marks it unread"
}

test_dated_hold_snoozes_and_wakes() {
  make_home snooze
  captain hold w1 --reason "Pick the layout" --until 2099-01-02 >/dev/null 2>&1 || fail "dated hold should succeed"
  assert_equals "true" "$(decision w1 't.snoozed')" "a dated hold is snoozed"
  assert_equals "2099-01-02T00:00:00Z" "$(decision w1 't.snoozedUntil')" "until its date"
  captain hold w1 --reason "Pick the layout now" >/dev/null 2>&1 || fail "re-hold should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "an undated hold wakes it"
  assert_equals "Pick the layout now" "$(decision w1 't.decision.question')" "with the new reason"
  pass "fm-t3-needs-me.sh: a dated hold snoozes its thread until the date"
}

test_answer_settles_then_archives() {
  make_home settle
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  answer w2 || fail "answer should succeed"
  assert_equals "true" "$(decision w2 't.settled')" "an answered call settles"
  assert_equals "false" "$(decision w2 't.archived')" "and is kept for now"
  assert_present "$HOME_DIR/state/t3-needs-me/w2.json" "the settle is recorded"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 3600 )) needs_me sync >/dev/null || fail "an hour later sync should succeed"
  assert_equals "false" "$(decision w2 't.archived')" "an hour later it is still there"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 60 )) needs_me sync >/dev/null || fail "a day later sync should succeed"
  assert_equals "true" "$(decision w2 't.archived')" "a day after the settle it is archived"
  assert_absent "$HOME_DIR/state/t3-needs-me/w2.json" "and its record is gone"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  answer w1 --release || fail "release should succeed"
  assert_equals "true" "$(decision w1 't.settled')" "a released call settles too"
  pass "fm-t3-needs-me.sh: an answered or released call settles, then archives after a day"
}

test_captain_settle_stands_until_an_update() {
  make_home reply
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  set_decision_thread w2 't.settled = true; t.settledAt = new Date().toISOString(); t.unread = false;'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "true" "$(decision w2 't.settled')" "the captain's own settle (his reply) stands"
  assert_equals "" "$(t3_fake_mutations)" "the pass leaves it alone"
  captain context w2 --changed "His reply asked which mount; still open" --text-file "$(say 'Wall or window mount?')" >/dev/null 2>&1 \
    || fail "update should succeed"
  assert_equals "false" "$(decision w2 't.settled')" "a reply that left the call open unsettles it with the update"
  assert_equals "true" "$(decision w2 't.unread')" "and marks it unread"
  set_decision_thread w2 't.archived = true;'
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "true" "$(decision w2 't.archived')" "an archive he made himself stands too"
  pass "fm-t3-needs-me.sh: the captain's own settle or archive stands until Firstmate's records change"
}

test_failed_call_and_restart_converge() {
  make_home converge
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "Pick the layout" --until 2099-01-02 >/dev/null 2>&1 || fail "hold should still succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "the failed snooze did not land"
  assert_equals "in_sync: no" "$(needs_me status | head -n 1)" "status knows the pass did not match"
  t3_fake_set 'delete w.failTools'
  sync_now >/dev/null || fail "the next sync should succeed"
  assert_equals "true" "$(decision w1 't.snoozed')" "the next pass applies it"
  assert_equals "1" "$(decision_count)" "on the same thread"
  t3_fake_restart "$TMP_ROOT/server"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "sync after a restart should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a restart alone changes nothing"
  assert_equals "in_sync: yes" "$(needs_me status | head -n 1)" "and the records match"
  set_decision_thread w1 't.decision = null;'
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "1" "$(decision w1 't.decision.revision')" "a lost payload is set again"
  pass "fm-t3-needs-me.sh: a failed call or a T3 restart converges on the next pass"
}

test_lost_launch_reply_makes_no_duplicate() {
  make_home lost
  t3_fake_set 'w.dropReplyTools = { t3_thread_launch: 1 }'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should still succeed"
  assert_equals "1" "$(decision_count)" "the launch landed though its reply was lost"
  sync_now >/dev/null || fail "the next sync should succeed"
  assert_equals "1" "$(decision_count)" "the retry lands on the same thread"
  assert_present "$HOME_DIR/state/t3-needs-me/w1.json" "and records it"
  t3_fake_set 'for (const t of Object.values(w.threads)) if (t.decisionOf) delete w.threads[t.threadId];'
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "1" "$(decision_count)" "a thread deleted in T3 is made again"
  assert_equals "1" "$(jq -r '.generation' "$HOME_DIR/state/t3-needs-me/w1.json")" "under the next generation"
  pass "fm-t3-needs-me.sh: a lost launch reply or a deleted thread leaves exactly one decision"
}

test_a_decision_with_a_turn_is_never_kept() {
  make_home with-turn 'w.decisionStartsRun = true'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should still succeed"
  assert_equals "true" "$(decision w1 't.archived')" "a decision thread that started a turn is archived"
  assert_equals "" "$(jq -r '.thread // empty' "$HOME_DIR/state/t3-needs-me/w1.json")" "and never recorded as the call's thread"
  assert_equals "1" "$(jq -r '.generation' "$HOME_DIR/state/t3-needs-me/w1.json")" "the next try uses a new request id"
  t3_fake_set 'delete w.decisionStartsRun'
  sync_now >/dev/null || fail "the next sync should succeed"
  assert_equals "false" "$(decision w1 't.archived')" "the next pass makes a proper one"
  assert_equals "0" "$(decision w1 't.runs.length')" "with no turn"
  assert_equals "2" "$(decision_count w1)" "beside the archived one"
  pass "fm-t3-needs-me.sh: a decision thread that started a turn is archived and replaced, never kept"
}

test_parked_holds_sit_in_settled() {
  make_home parked
  (cd "$HOME_DIR" && tasks-axi add w3 "Blocked call" --repo sample --blocked-by w1) >/dev/null 2>&1 \
    || fail "could not seed a blocked row"
  captain hold w3 --reason "Choose after w1 lands" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "true" "$(decision w3 't.settled')" "a blocked call is parked in Settled"
  assert_equals "false" "$(decision w3 't.archived')" "and kept"
  pass "fm-t3-needs-me.sh: a blocked call stays out of the top level"
}

test_aged_holds_are_not_shelved_for_age() {
  make_home aged
  FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "aged" "$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 home_env "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input | jq -r '.backlog.records[] | select(.id == "w1") | .hold_bucket')" "the hold reads as aged"
  assert_equals "false" "$(decision w1 't.settled === true || t.snoozed === true')" "an aged call is an active top-level thread"
  assert_contains "$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 needs_me status)" "waiting: 1" "and counts as waiting on him"
  FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 sync_now >/dev/null || fail "the next sync should succeed"
  assert_equals "false" "$(decision w1 't.settled')" "later passes keep it there"
  pass "fm-t3-needs-me.sh: an aged call is not shelved just for being aged"
}

test_day_old_calls_move_to_the_snoozed_shelf() {
  make_home shelve
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 3600 )) needs_me sync >/dev/null || fail "an hour later sync should succeed"
  assert_equals "false" "$(decision w1 't.snoozed === true')" "a call raised an hour ago stays under FirstMate"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 60 )) needs_me sync >/dev/null || fail "a day later sync should succeed"
  assert_equals "true" "$(decision w1 't.snoozed')" "a call raised over a day ago is snoozed"
  assert_equals "true" "$(decision w1 't.snoozedUntil == null')" "with no date"
  assert_contains "$(FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 60 )) needs_me status)" "waiting: 0" "and no longer counts as waiting under FirstMate"
  pass "fm-t3-needs-me.sh: a call older than a day moves to the Snoozed shelf with no date"
}

test_shelving_leaves_the_captains_own_placement() {
  make_home shelve-captain
  (cd "$HOME_DIR" && tasks-axi add w3 "Third call" --repo sample) >/dev/null 2>&1 || fail "could not seed a third row"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  captain hold w3 --reason "Name the release" >/dev/null 2>&1 || fail "hold should succeed"
  set_decision_thread w1 't.snoozed = true; t.snoozedUntil = "2099-01-05T00:00:00Z";'
  set_decision_thread w2 't.archived = true;'
  set_decision_thread w3 't.settled = true; t.settledAt = new Date().toISOString();'
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 60 )) needs_me sync >/dev/null || fail "a day later sync should succeed"
  assert_equals "2099-01-05T00:00:00Z" "$(decision w1 't.snoozedUntil')" "his own dated snooze keeps its date"
  assert_equals "true" "$(decision w2 't.archived === true && t.snoozed !== true')" "his own archive stands"
  assert_equals "true" "$(decision w3 't.settled === true && t.snoozed !== true')" "his reply's settle stands until the answer is recorded"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 120 )) needs_me sync >/dev/null || fail "the next sync should succeed"
  assert_equals "2099-01-05T00:00:00Z" "$(decision w1 't.snoozedUntil')" "and later passes leave them alone"
  assert_contains "$(FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 120 )) needs_me status)" "in_sync: yes" "while the records match"
  pass "fm-t3-needs-me.sh: moving a day-old call to the shelf leaves the captain's own snooze, archive, or settle"
}

test_an_update_brings_a_shelved_call_back() {
  make_home shelve-update
  local raised=$(( $(date +%s) - 2 * 86400 ))
  FM_CAPTAIN_HOLD_NOW=$(jq -nr --argjson t "$raised" '$t | todateiso8601') \
    captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "true" "$(decision w1 't.snoozed === true && t.snoozedUntil == null')" "a call raised two days ago is on the shelf"
  FM_NEEDS_ME_NOW=$(( raised + 3600 )) needs_me mentioned w1 || fail "mentioned should succeed"
  assert_present "$HOME_DIR/state/needs-me-mentioned/w1" "the captain was told of it while it was at the top"
  captain context w1 --text-file "$(say 'Grid or list?')" >/dev/null 2>&1 || fail "raise should succeed"
  assert_equals "true" "$(decision w1 't.snoozed')" "a context rewrite without --changed leaves it there"
  assert_present "$HOME_DIR/state/needs-me-mentioned/w1" "a shelved call keeps its mention record"
  captain context w1 --changed "A third layout came up" --text-file "$(say 'Grid, list, or cards?')" >/dev/null 2>&1 \
    || fail "update should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "a recorded update brings it back under FirstMate"
  assert_contains "$(needs_me status)" "$(printf 'changed\tw1\tPick the print layout\tA third layout came up')" \
    "and status names it as changed, with what changed"
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 86400 + 60 )) needs_me sync >/dev/null || fail "a day later sync should succeed"
  assert_equals "true" "$(decision w1 't.snoozed === true && t.snoozedUntil == null')" "for a day, then it is shelved again"
  pass "fm-t3-needs-me.sh: an update brings a shelved call back for another day"
}

test_dated_hold_gets_its_day_when_it_comes_due() {
  make_home dated-due
  FM_CAPTAIN_HOLD_NOW=2099-01-01T10:00:00Z captain hold w1 --reason "Pick the layout" --until 2099-01-04 >/dev/null 2>&1 \
    || fail "dated hold should succeed"
  assert_equals "2099-01-04T00:00:00Z" "$(decision w1 't.snoozedUntil')" "a dated hold is snoozed until its date"
  local due=2099-01-04T00:01:00Z late=2099-01-04T23:59:00Z next_day=2099-01-05T00:02:00Z
  at "$due" needs_me sync >/dev/null || fail "sync on the due date should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "the minute its date comes due it is back under FirstMate"
  assert_contains "$(at "$due" needs_me status)" "waiting: 1" "and counts as waiting on him"
  at "$late" needs_me sync >/dev/null || fail "sync late on the due date should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "for the whole day, though it was raised days before"
  at "$next_day" needs_me sync >/dev/null || fail "sync a day after the due date should succeed"
  assert_equals "true" "$(decision w1 't.snoozed === true && t.snoozedUntil == null')" "a day after its date it moves to the shelf"
  pass "fm-t3-needs-me.sh: a dated hold gets its day at the top when its date comes due"
}

test_re_asked_deferred_call_gets_its_day() {
  make_home re-asked
  FM_CAPTAIN_HOLD_NOW=2099-01-01T10:00:00Z captain hold w1 --reason "Pick the layout" --until 2099-02-01 >/dev/null 2>&1 \
    || fail "dated hold should succeed"
  at 2099-01-01T10:01:00Z needs_me sync >/dev/null || fail "sync after the dated hold should succeed"
  assert_equals "2099-02-01T00:00:00Z" "$(decision w1 't.snoozedUntil')" "the deferred call is snoozed until its date"
  at 2099-01-05T09:00:00Z captain hold w1 --reason "Pick the layout now" >/dev/null 2>&1 || fail "re-hold should succeed"
  at 2099-01-05T09:00:00Z needs_me sync >/dev/null || fail "sync after the re-hold should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "re-asked days after it was raised, it is back under FirstMate"
  at 2099-01-06T08:59:00Z needs_me sync >/dev/null || fail "sync later that day should succeed"
  assert_equals "false" "$(decision w1 't.snoozed')" "for a day from the re-ask"
  at 2099-01-06T09:01:00Z needs_me sync >/dev/null || fail "sync a day later should succeed"
  assert_equals "true" "$(decision w1 't.snoozed === true && t.snoozedUntil == null')" "then it moves to the shelf"
  pass "fm-t3-needs-me.sh: a deferred call re-asked early gets its day at the top"
}

test_unblocked_call_gets_its_day() {
  make_home unblocked
  (cd "$HOME_DIR" && tasks-axi add w3 "Blocked call" --repo sample --blocked-by w1) >/dev/null 2>&1 \
    || fail "could not seed a blocked row"
  FM_CAPTAIN_HOLD_NOW=2099-01-01T10:00:00Z captain hold w3 --reason "Choose after w1 lands" >/dev/null 2>&1 || fail "hold should succeed"
  at 2099-01-01T10:01:00Z needs_me sync >/dev/null || fail "sync while blocked should succeed"
  assert_equals "true" "$(decision w3 't.settled')" "while w1 is open the call is parked in Settled"
  at 2099-01-04T12:00:00Z needs_me sync >/dev/null || fail "a later sync while blocked should succeed"
  assert_equals "true" "$(decision w3 't.settled')" "and stays there"
  (cd "$HOME_DIR" && tasks-axi 'done' w1) >/dev/null 2>&1 || fail "could not finish the blocker"
  at 2099-01-05T09:00:00Z needs_me sync >/dev/null || fail "sync after the blocker cleared should succeed"
  assert_equals "false" "$(decision w3 't.settled === true || t.snoozed === true')" "four days after it was raised, it is under FirstMate"
  assert_contains "$(at 2099-01-05T09:00:00Z needs_me status)" "waiting: 1" "and counts as waiting on him"
  at 2099-01-06T08:59:00Z needs_me sync >/dev/null || fail "sync later that day should succeed"
  assert_equals "false" "$(decision w3 't.snoozed')" "for a day from when its blocker cleared"
  at 2099-01-06T09:01:00Z needs_me sync >/dev/null || fail "sync a day later should succeed"
  assert_equals "true" "$(decision w3 't.snoozed === true && t.snoozedUntil == null')" "then it moves to the shelf"
  pass "fm-t3-needs-me.sh: a call whose blocker clears gets its day at the top"
}

test_status_and_mentioned() {
  make_home status
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  captain hold w2 --reason "Buy the camera" --until 2099-01-02 >/dev/null 2>&1 || fail "hold should succeed"
  local out
  out=$(needs_me status)
  assert_contains "$out" "in_sync: yes" "the pass matched"
  assert_contains "$out" "waiting: 1" "one decision waits at the top (the dated one is snoozed)"
  assert_contains "$out" "$(printf 'new\tw1\tPick the print layout')" "w1 is new"
  needs_me mentioned w1 w2 || fail "mentioned should succeed"
  out=$(needs_me status)
  assert_not_contains "$out" "w1" "a mentioned decision is not named again"
  captain context w1 --changed "A third layout came up" --text-file "$(say 'Grid, list or cards?')" >/dev/null 2>&1 \
    || fail "update should succeed"
  out=$(needs_me status)
  assert_contains "$out" "$(printf 'changed\tw1\tPick the print layout\tA third layout came up')" "a changed decision is named with what changed"
  answer w1 || fail "answer should succeed"
  assert_absent "$HOME_DIR/state/needs-me-mentioned/w1" "a decision no longer waiting drops its mention record"
  pass "fm-t3-needs-me.sh status: counts the waiting decisions and names only new or changed ones"
}

test_no_firstmate_thread_or_old_t3_does_nothing() {
  make_home no-parent 'w.threads = {}'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "0" "$(decision_count)" "with no FirstMate thread nothing is made"
  assert_equals "in_sync: no" "$(needs_me status | head -n 1)" "and nothing counts as in sync"
  make_home old-t3 'delete w.decisions'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  sync_now >/dev/null
  expect_code 0 "$?" "a T3 without decision threads is not a failure"
  assert_equals "0" "$(decision_count)" "and gets none"
  make_home no-token
  rm -f "$HOME_DIR/config/t3code-token"
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a home without the credential never calls T3"
  pass "fm-t3-needs-me.sh: no FirstMate thread, an older T3, or no credential changes nothing"
}

test_secondmate_home_takes_no_part() {
  make_home mate
  printf 'mate-1\n' > "$HOME_DIR/.fm-secondmate-home"
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1
  assert_equals "0" "$(captain open w1 >/dev/null 2>&1; echo $?)" "the hold itself is recorded"
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a secondmate's calls reach the captain through its parent"
  assert_equals "0" "$(decision_count)" "so it makes no decision thread"
  pass "fm-t3-needs-me.sh: a secondmate home makes no decision threads"
}

# --- objectives ------------------------------------------------------------

# write_objectives <file>: a made-up objectives file in the shape the home
# keeps: a heading, a preamble, the review line, then one bullet each.
write_objectives() {
  cat > "$1" <<'MD'
# High level objectives

The broad direction right now. Nothing gets ticked off.

Last reviewed: 2026-10-01

- **Garden shed:** build the shed before winter. The plans are drawn. Plans so far: /home/someone/notes/shed/plans.md
- **Sourdough (or any bread):** bake one loaf a week, in the style of the corner bakery; keep the starter alive. Added from the 3 October journal, which holds the full details: /home/someone/journal/2026-10-03.md
- **Running:** "a 10k by spring"; two runs a week. Added from the 4 October journal: ~/journal/2026-10-04.md
- **Reading:** a book a month. Added from the 4 October journal (same file).
- A bullet with no name, see https://example.com/list
MD
}

# objectives_payload <objectives-md>: the Bridge payload for a home whose
# objectives file is <objectives-md> (none when it does not exist), read as
# the sync reads it.
objectives_payload() {
  local home="$TMP_ROOT/payload-home"
  mkdir -p "$home/data"
  rm -f "$home/data/high-level-objectives.md"
  [ ! -f "$1" ] || cp "$1" "$home/data/high-level-objectives.md"
  FM_HOME="$home" "$ROOT/bin/fm-objectives.sh" --reviewed > "$home/source.json" || return 1
  node "$ROOT/bin/fm-t3-mcp.mjs" objectives-payload --file "$home/source.json"
}

test_objectives_payload_shape() {
  local f="$TMP_ROOT/objectives.md" out want
  write_objectives "$f"
  out=$(objectives_payload "$f") || fail "the payload should build"
  want=$(printf '%s\n' \
    '- **Garden shed** — build the shed before winter. The plans are drawn.' \
    '- **Sourdough (or any bread)** — bake one loaf a week, in the style of the corner bakery; keep the starter alive.' \
    '- **Running** — "a 10k by spring"; two runs a week.' \
    '- **Reading** — a book a month. Added from the 4 October journal (same file).' \
    '- A bullet with no name, see https://example.com/list')
  assert_equals "$want" "$(printf '%s' "$out" | jq -r '.markdown')" "only the bullets, names bold, local path pointers dropped"
  assert_equals "2026-10-01" "$(printf '%s' "$out" | jq -r '.lastReviewed')" "lastReviewed comes from the review line"
  assert_equals "5 0" "$(printf '%s' "$out" | jq -r '"\(.objectives) \(.shortened)"')" "five objectives, none shortened"
  printf '# High level objectives\n\nLast reviewed: 2026-02-30\n\n- **Only:** one. Notes: /tmp/x\n' > "$f"
  out=$(objectives_payload "$f")
  assert_equals "null" "$(printf '%s' "$out" | jq -r '.lastReviewed')" "a day that does not exist is left out"
  assert_equals "- **Only** — one." "$(printf '%s' "$out" | jq -r '.markdown')" "a single objective keeps its text"
  printf '# High level objectives\n\nNothing yet.\n' > "$f"
  assert_equals "null" "$(objectives_payload "$f" | jq -r '.markdown')" "a file with no bullets clears them"
  assert_equals "null" "$(objectives_payload "$TMP_ROOT/none.md" | jq -r '.markdown')" "an absent file clears them"
  pass "fm-t3-mcp.mjs objectives-payload: the bullets, bold names, no local paths, and the review day"
}

test_objectives_payload_fits_the_limit() {
  local f="$TMP_ROOT/objectives-long.md" out md n long
  long=$(head -c 3000 /dev/zero | tr '\0' 'x')
  { printf '# High level objectives\n\nLast reviewed: 2026-10-01\n\n- **Short:** stays whole.\n'
    for n in 1 2 3 4; do printf -- '- **Long %s:** %s\n' "$n" "$long"; done; } > "$f"
  out=$(objectives_payload "$f") || fail "the payload should build"
  md=$(printf '%s' "$out" | jq -r '.markdown')
  [ "$(printf '%s' "$out" | jq '.markdown | length')" -le 8192 ] || fail "the list fits T3's 8192 characters"
  assert_equals "5" "$(printf '%s\n' "$md" | grep -c '^- \*\*')" "no objective is dropped"
  assert_equals "- **Short** — stays whole." "$(printf '%s\n' "$md" | head -n 1)" "a short objective is not cut"
  assert_equals "4" "$(printf '%s\n' "$md" | grep -c '…$')" "each long objective's text is cut, with an ellipsis"
  assert_equals "4" "$(printf '%s' "$out" | jq -r '.shortened')" "and the count says so"
  pass "fm-t3-mcp.mjs objectives-payload: past the limit every objective stays, its text cut"
}

objectives_calls() {
  t3_fake_calls t3_objectives_set | grep -c . || true
}

test_objectives_push_only_when_changed() {
  make_home objectives 'w.objectivesTool = true'
  local out rc
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "the first pass pushes them: $out"
  assert_equals "1" "$(objectives_calls)" "one push"
  assert_equals "2026-10-01" "$(jq -r '.objectives.lastReviewed' "$T3_FAKE_WORLD")" "with the review day"
  assert_equals "$(objectives_payload "$HOME_DIR/data/high-level-objectives.md" | jq -r '.markdown')" \
    "$(jq -r '.objectives.markdown' "$T3_FAKE_WORLD")" "and the built list"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an unchanged pass should succeed"
  assert_equals "0" "$(objectives_calls)" "unchanged objectives are not pushed again"
  printf -- '- **Swimming:** once a week.\n' >> "$HOME_DIR/data/high-level-objectives.md"
  t3_fake_set 'w.failTools = { t3_objectives_set: { code: "unavailable", message: "settings are busy" } }'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  out=$(sync_now)
  rc=$?
  expect_code 1 "$rc" "a failed push is reported: $out"
  assert_contains "$out" "objectives" "the line names the objectives"
  assert_equals "1" "$(decision_count w1)" "and the decision still lands"
  assert_equals "in_sync: yes" "$(needs_me status | head -n 1)" "and counts as in sync"
  t3_fake_set 'delete w.failTools'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(objectives_calls)" "the next pass retries"
  assert_contains "$(jq -r '.objectives.markdown' "$T3_FAKE_WORLD")" "- **Swimming** — once a week." "with the new objective"
  t3_fake_set 'w.objectivesAnswer = { markdown: "something else" }'
  printf -- '- **Cycling:** to work.\n' >> "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 1 "$?" "an answer that differs from what was sent is not proven: $out"
  t3_fake_set 'delete w.objectivesAnswer'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(objectives_calls)" "so it is pushed again"
  printf -- '- **Long:** %s\n' "$(head -c 9000 /dev/zero | tr '\0' 'x')" >> "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 0 "$?" "a list past the limit is still pushed: $out"
  assert_contains "$out" "1 of 8 objectives were shortened" "and the pass says it was cut"
  pass "fm-t3-needs-me.sh sync: objectives are pushed when they change, retried when a push fails"
}

test_objectives_clear_once_and_back_off() {
  make_home objectives-clear 'w.objectivesTool = true; w.objectives = { markdown: "- **Old** — gone." }'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals '{"markdown":null}' "$(t3_fake_calls t3_objectives_set)" "with no objectives file they are cleared"
  assert_equals "null" "$(jq -c '.objectives' "$T3_FAKE_WORLD")" "and T3 holds none"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals "0" "$(objectives_calls)" "only once"
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  t3_fake_set 'w.failTools = { t3_objectives_set: { code: "unavailable", message: "settings are busy" } }'
  local now n out
  now=$(date +%s)
  : > "$T3_FAKE_LOG"
  for n in 1 2 3 4; do FM_NEEDS_ME_NOW=$now needs_me sync >/dev/null; done
  assert_equals "3" "$(objectives_calls)" "three failures in a row, then it waits"
  FM_NEEDS_ME_NOW=$((now + 900)) needs_me sync >/dev/null
  assert_equals "4" "$(objectives_calls)" "and tries again 15 minutes later"
  make_home objectives-old-t3
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without objectives is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  for n in 1 2 3 4; do sync_now >/dev/null || fail "a T3 without objectives stays quiet once held back"; done
  pass "fm-t3-needs-me.sh sync: a missing file clears them once; failures back off; an older T3 is quiet"
}

test_objectives_payload_shape
test_objectives_payload_fits_the_limit
test_objectives_push_only_when_changed
test_objectives_clear_once_and_back_off
test_context_raise_update_and_guards
test_context_starts_over_on_a_new_hold
test_reply_marker
test_hold_creates_an_agentless_decision
test_context_updates_the_payload_and_marks_unread
test_dated_hold_snoozes_and_wakes
test_answer_settles_then_archives
test_captain_settle_stands_until_an_update
test_failed_call_and_restart_converge
test_lost_launch_reply_makes_no_duplicate
test_a_decision_with_a_turn_is_never_kept
test_parked_holds_sit_in_settled
test_aged_holds_are_not_shelved_for_age
test_day_old_calls_move_to_the_snoozed_shelf
test_shelving_leaves_the_captains_own_placement
test_an_update_brings_a_shelved_call_back
test_dated_hold_gets_its_day_when_it_comes_due
test_re_asked_deferred_call_gets_its_day
test_unblocked_call_gets_its_day
test_status_and_mentioned
test_no_firstmate_thread_or_old_t3_does_nothing
test_secondmate_home_takes_no_part

echo "ok: fm-t3-needs-me"
