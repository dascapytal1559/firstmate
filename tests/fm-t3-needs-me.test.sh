#!/usr/bin/env bash
# tests/fm-t3-needs-me.test.sh - the captain's T3 Bridge decisions follow his
# open captain calls as one list: bin/fm-captain-hold.sh context,
# bin/fm-t3-needs-me.sh sync and reply-task, and bin/fm-watch.sh's alert,
# driven through the real bin/fm-captain-hold.sh and tasks-axi backlogs
# against the fake T3 server.
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
    w.decisionsTool = true; w.coordinatorRestartNote = true;
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
    --option "A: one camera" --option "B: two cameras" \
    --attach report=data/camera/report.md --label "sections 5-7" >/dev/null 2>&1 || fail "the raise should succeed"
  assert_equals "1" "$(jq -r '.revision' "$rec")" "the raise is revision 1"
  assert_equals "raised" "$(jq -r '.entries[0].kind' "$rec")" "the first entry is the raise"
  assert_equals "$(printf 'Camera: three choices.\n\nA, B or C?')" "$(jq -r '.entries[0].text' "$rec")" "the text is kept as sent"
  assert_equals '[{"label":"A: one camera"},{"label":"B: two cameras"}]' "$(jq -c '.options' "$rec")" "an option is its label alone"
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

test_unsupported_t3_or_no_credential_does_nothing() {
  make_home old-t3 'delete w.decisionsTool'
  local out
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without t3_decisions_set is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  assert_equals "" "$(t3_fake_mutations)" "nothing in T3 changes"
  assert_equals "null" "$(bridge '.decisionList')" "and no list is kept"
  make_home no-token
  rm -f "$HOME_DIR/config/t3code-token"
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a home without the credential never calls T3"
  pass "fm-t3-needs-me.sh: a T3 without the decision list, or a home without the credential, changes nothing"
}

test_secondmate_home_takes_no_part() {
  make_home mate
  printf 'mate-1\n' > "$HOME_DIR/.fm-secondmate-home"
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1
  assert_equals "0" "$(captain open w1 >/dev/null 2>&1; echo $?)" "the hold itself is recorded"
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "" "$(t3_fake_mutations)" "a secondmate's calls reach the captain through its parent"
  assert_equals "0" "$(list_calls)" "so it sends no decision list"
  pass "fm-t3-needs-me.sh: a secondmate home sends no decisions"
}

# --- Bridge decision list --------------------------------------------------

# bridge <jq-filter>: that value of the decision list T3 keeps.
bridge() {
  jq -c "$1" "$T3_FAKE_WORLD"
}

list_calls() {
  t3_fake_calls t3_decisions_set | wc -l | tr -d ' '
}

test_list_carries_every_open_call() {
  make_home list
  (cd "$HOME_DIR" && tasks-axi add w3 "Blocked call" --repo sample --blocked-by w2) >/dev/null 2>&1 \
    || fail "could not seed a blocked row"
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "Grid or list for the print view?" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "1" "$(list_calls)" "the hold sends the list in one call before it returns"
  assert_equals "\"$FM_THREAD\"" "$(bridge '.decisionList.replyTo')" "replies go to FirstMate's thread"
  assert_equals '["entries","id","options","projectName","question","revision","since","title"]' \
    "$(bridge '.decisionList.decisions[0] | keys')" "a decision carries exactly T3's fields"
  assert_equals '"w1"' "$(bridge '.decisionList.decisions[0].id')" "keyed by the task id"
  assert_equals '"Pick the print layout"' "$(bridge '.decisionList.decisions[0].title')" "titled by the task"
  assert_equals '"sample"' "$(bridge '.decisionList.decisions[0].projectName')" "naming the task's repo"
  assert_equals '"Grid or list for the print view?"' "$(bridge '.decisionList.decisions[0].question')" "the hold reason is the question"
  assert_equals '1' "$(bridge '.decisionList.decisions[0].revision')" "at revision 1"
  assert_equals "" "$(t3_fake_calls t3_thread_launch)" "and no thread is made"
  assert_absent "$HOME_DIR/state/t3-needs-me/w1.json" "nor any record per decision"
  captain hold w2 --reason "Give the word to buy the camera" --until 2099-01-02 >/dev/null 2>&1 || fail "dated hold should succeed"
  assert_equals '"2099-01-02T00:00:00Z"' "$(bridge '.decisionList.decisions[] | select(.id == "w2") | .wakeAt')" \
    "a dated hold waits under Scheduled until its date"
  assert_equals 'null' "$(bridge '.decisionList.decisions[] | select(.id == "w1") | .wakeAt')" "an undated one does not"
  captain hold w3 --reason "Choose after w2 lands" >/dev/null 2>&1 || fail "blocked hold should succeed"
  assert_equals '["w1","w2"]' "$(bridge '[.decisionList.decisions[].id]')" "a blocked call is left out"
  captain context w1 --text-file "$(say 'Grid, list, or cards?')" --question "Which layout?" --option "Grid" >/dev/null 2>&1 \
    || fail "raise should succeed"
  assert_equals '2' "$(bridge '.decisionList.decisions[] | select(.id == "w1") | .revision')" "context reaches the Bridge at once"
  assert_equals '"Which layout?"' "$(bridge '.decisionList.decisions[] | select(.id == "w1") | .question')" "with its question"
  answer w1 || fail "answer should succeed"
  assert_equals '["w2"]' "$(bridge '[.decisionList.decisions[].id]')" "an answered call leaves the list"
  answer w2 --release || fail "release should succeed"
  answer w3 --release || fail "release should succeed"
  assert_equals '[]' "$(bridge '.decisionList.decisions')" "the last answer empties it"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an idle pass should succeed"
  assert_equals "0" "$(list_calls)" "an empty list already sent is not sent again"
  pass "fm-t3-needs-me.sh: the Bridge list carries every open call and changes in the same step"
}

test_list_with_only_blocked_calls_is_sent_once() {
  make_home list-blocked
  (cd "$HOME_DIR" && tasks-axi add w3 "Blocked call" --repo sample --blocked-by w2) >/dev/null 2>&1 \
    || fail "could not seed a blocked row"
  captain hold w3 --reason "Choose after w2 lands" >/dev/null 2>&1 || fail "blocked hold should succeed"
  assert_equals '[]' "$(bridge '.decisionList.decisions')" "a blocked call is left off the Bridge"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an idle pass should succeed"
  sync_now >/dev/null || fail "an idle pass should succeed"
  assert_equals "0" "$(list_calls)" "an empty list already sent is not sent again while the blocked call waits"
  captain hold w1 --reason "Grid or list for the print view?" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "1" "$(list_calls)" "a call the captain can answer is sent at once"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "and only it is shown"
  pass "fm-t3-needs-me.sh: a list holding only blocked calls is sent empty once and not again"
}

test_list_resend_keeps_the_captains_answer() {
  make_home list-answered
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  # T3 marks a decision answered when the captain replies from the Bridge.
  t3_fake_set 'w.decisionList.decisions[0].answered = { commandId: "cmd-1", at: "2099-01-01T00:00:00Z" }'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals "1" "$(list_calls)" "every pass with something to show sends the list"
  assert_equals '"cmd-1"' "$(bridge '.decisionList.decisions[0].answered.commandId')" \
    "unchanged records send the same decision, so the answer stands and it stays hidden"
  captain context w1 --text-file "$(say 'Grid or list?')" --question "Which layout?" >/dev/null 2>&1 \
    || fail "an update after his reply should succeed"
  assert_equals 'null' "$(bridge '.decisionList.decisions[0].answered')" "a reply that left the call open shows its update"
  pass "fm-t3-needs-me.sh: resending the list leaves the captain's answer until the records change"
}

# entry <task-id> <jq-filter over its decision>: that value of the task's
# decision on the Bridge.
entry() {
  bridge ".decisionList.decisions[] | select(.id == \"$1\") | $2"
}

test_list_carries_the_context_payload() {
  make_home list-payload
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  captain context w2 --text-file "$(say 'Camera: A, B or C?')" --question "Which camera?" \
    --option "A" --option "B" --attach link=https://example.com/cx810 >/dev/null 2>&1 || fail "raise should succeed"
  assert_equals '2' "$(entry w2 .revision)" "the raise reaches the Bridge"
  assert_equals '"Camera: A, B or C?"' "$(entry w2 '.entries[0].text')" "with the words as sent"
  assert_equals '"raised"' "$(entry w2 '.entries[0].kind')" "as the raise"
  assert_equals '[{"label":"A"},{"label":"B"}]' "$(entry w2 .options)" "and the options"
  assert_equals '"https://example.com/cx810"' "$(entry w2 '.entries[0].attachments[0].path')" "a link travels as given"
  captain context w2 --changed "Only the purchase is left" --text-file "$(say 'Buy one?')" \
    --attach picture=config/t3code-token >/dev/null 2>&1 || fail "update should succeed"
  assert_equals '3' "$(entry w2 .revision)" "the update reaches the Bridge"
  assert_equals '"Only the purchase is left"' "$(entry w2 '.entries[1].changed')" "with what changed"
  assert_equals "\"$(cd "$HOME_DIR" && pwd -P)/config/t3code-token\"" "$(entry w2 '.entries[1].attachments[0].path')" \
    "a picture travels as an absolute path"
  pass "fm-t3-needs-me.sh: the raise and each update reach the Bridge with their words, options, and attachments"
}

test_list_drops_an_option_detail_from_an_older_record() {
  make_home list-old-detail
  local rec="$HOME_DIR/data/needs-me/w2.json" out rc
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  printf 'Camera: A or B?\n' > "$HOME_DIR/raised.txt"
  captain context w2 --text-file "$HOME_DIR/raised.txt" --question "Which camera?" \
    --option "A" --option "B" >/dev/null 2>&1 || fail "raise should succeed"
  # A record written before options lost their detail still carries one.
  jq '.options = [{label:"A", detail:"About 150 dollars"}, {label:"B", detail:null}]' "$rec" > "$rec.new" && mv "$rec.new" "$rec"
  sync_now >/dev/null || fail "sync over the older record should succeed"
  assert_equals '[{"label":"A"},{"label":"B"}]' "$(entry w2 .options)" "the older record syncs with its labels alone"
  captain context w2 --text-file "$HOME_DIR/raised.txt" --question "Which camera?" \
    --option "A" --option "B" >/dev/null 2>&1 || fail "an exact retry over the older record should succeed"
  assert_equals 'About 150 dollars' "$(jq -r '.options[0].detail' "$rec")" "an exact retry leaves the older record as it was"
  out=$(captain context w2 --changed "New prices" --text-file "$(say 'Still A or B?')" --option "A" --detail "x" 2>&1)
  rc=$?
  expect_code 2 "$rc" "an option takes no detail any more: $out"
  pass "fm-t3-needs-me.sh: an older record's option detail is dropped on the way to the Bridge"
}

test_list_dated_hold_waits_until_its_date() {
  make_home list-dated
  FM_CAPTAIN_HOLD_NOW=2099-01-01T10:00:00Z captain hold w1 --reason "Pick the layout" --until 2099-01-04 >/dev/null 2>&1 \
    || fail "dated hold should succeed"
  at 2099-01-01T10:01:00Z needs_me sync >/dev/null || fail "sync after the dated hold should succeed"
  assert_equals '"2099-01-04T00:00:00Z"' "$(entry w1 .wakeAt)" "a dated hold waits until 00:00 UTC on its date"
  at 2099-01-04T00:01:00Z needs_me sync >/dev/null || fail "sync on the due date should succeed"
  assert_equals 'null' "$(entry w1 .wakeAt)" "the minute its date comes due it waits no longer"
  at 2099-01-05T00:02:00Z needs_me sync >/dev/null || fail "sync a day after the due date should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "and stays listed after that day"
  assert_equals 'null' "$(entry w1 .wakeAt)" "without a date"
  FM_CAPTAIN_HOLD_NOW=2099-01-01T10:00:00Z captain hold w2 --reason "Buy the camera" --until 2099-02-01 >/dev/null 2>&1 \
    || fail "a second dated hold should succeed"
  at 2099-01-05T09:00:00Z needs_me sync >/dev/null || fail "sync after the second dated hold should succeed"
  assert_equals '"2099-02-01T00:00:00Z"' "$(entry w2 .wakeAt)" "a deferred call waits for its own date"
  at 2099-01-05T09:00:00Z captain hold w2 --reason "Buy the camera now" >/dev/null 2>&1 || fail "re-hold should succeed"
  at 2099-01-05T09:00:00Z needs_me sync >/dev/null || fail "sync after the re-hold should succeed"
  assert_equals 'null' "$(entry w2 .wakeAt)" "re-asked early with no date, it waits no longer"
  assert_equals '"Buy the camera now"' "$(entry w2 .question)" "and carries the new reason"
  pass "fm-t3-needs-me.sh: a dated hold waits until its date, and a re-ask with no date brings it back"
}

test_list_keeps_an_open_call_however_long_it_waits() {
  make_home list-waits
  (cd "$HOME_DIR" && tasks-axi add w3 "Blocked call" --repo sample --blocked-by w2) >/dev/null 2>&1 \
    || fail "could not seed a blocked row"
  FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "aged" "$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 home_env "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input | jq -r '.backlog.records[] | select(.id == "w1") | .hold_bucket')" "the hold reads as aged"
  FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=0 sync_now >/dev/null || fail "sync should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "an aged call is listed"
  assert_equals 'null' "$(entry w1 .wakeAt)" "with no date to wait for"
  at "$(jq -nr --argjson t "$(( $(date +%s) + 7 * 86400 ))" '$t | todateiso8601')" needs_me sync >/dev/null \
    || fail "a week later sync should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "and a week later it is still listed"
  captain hold w3 --reason "Choose after w2 lands" >/dev/null 2>&1 || fail "blocked hold should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "a blocked call is left out"
  (cd "$HOME_DIR" && tasks-axi 'done' w2) >/dev/null 2>&1 || fail "could not finish the blocker"
  sync_now >/dev/null || fail "sync after the blocker cleared should succeed"
  assert_equals '["w1","w3"]' "$(bridge '[.decisionList.decisions[].id] | sort')" "once its blocker clears it is listed"
  pass "fm-t3-needs-me.sh: an open call stays listed however long it waits, and a blocked one comes back once unblocked"
}

test_list_restores_what_t3_lost() {
  make_home list-restore
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  t3_fake_set 'w.decisionList.decisions = []'
  sync_now >/dev/null || fail "sync should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "a decision T3 lost is sent again on the next pass"
  t3_fake_restart "$TMP_ROOT/server"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "sync after a restart should succeed"
  assert_equals "1" "$(list_calls)" "a pass after a T3 restart sends the list again"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "unchanged"
  pass "fm-t3-needs-me.sh: a lost decision or a T3 restart converges on the next pass"
}

test_list_failures_wake_firstmate_on_the_third() {
  make_home list-fail
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  local alert="$HOME_DIR/state/t3-needs-me/.alert" out rc n
  t3_fake_set 'w.failTools = { t3_decisions_set: { code: "unavailable", message: "decisions file is busy" } }'
  for n in 1 2; do
    out=$(sync_now)
    rc=$?
    expect_code 1 "$rc" "failed pass $n is reported: $out"
    assert_contains "$out" "decisions file is busy" "with T3's words"
  done
  assert_absent "$alert" "two failures in a row only report"
  out=$(sync_now)
  assert_contains "$out" "the next pass retries" "the third is still retried"
  assert_present "$alert" "and leaves an alert for firstmate"
  assert_contains "$(cat "$alert")" "check: t3-decisions: " "as a check wake reason"
  assert_contains "$(cat "$alert")" "3 passes in a row: fm-t3-mcp: T3 t3_decisions_set failed: decisions file is busy" \
    "carrying the exact error"
  rm -f "$alert"
  sync_now >/dev/null
  assert_absent "$alert" "the same run of failures alerts once"
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "holds carry on while T3 refuses"
  FM_T3_FM=$FM_THREAD t3_fake_set 'delete w.failTools; w.decisionsAnswer = { replyTo: process.env.FM_T3_FM, decisions: [] }'
  out=$(sync_now)
  expect_code 1 "$?" "an answer that differs from the list sent is no proof: $out"
  t3_fake_set 'delete w.decisionsAnswer'
  sync_now >/dev/null || fail "the next pass should succeed"
  assert_equals '["w1","w2"]' "$(bridge '[.decisionList.decisions[].id]')" "and lands the whole list"
  assert_equals "0" "$(jq -r '.failures' "$HOME_DIR/state/t3-needs-me/.decisions")" "which ends the run"
  t3_fake_set 'w.failTools = { t3_decisions_set: { code: "unavailable", message: "still busy" } }'
  for n in 1 2; do sync_now >/dev/null; done
  assert_absent "$alert" "a new run counts from one"
  sync_now >/dev/null
  assert_present "$alert" "and alerts again on its third"
  t3_fake_set 'delete w.failTools'
  sync_now >/dev/null || fail "the next pass should succeed"
  assert_absent "$alert" "an accepted pass takes an unread alert away"
  pass "fm-t3-needs-me.sh: a refused list is retried every pass and wakes firstmate on the third in a row"
}

test_list_leaves_out_a_decision_t3_would_refuse() {
  make_home list-bounds
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  captain hold w2 --reason "Give the word to buy the camera" >/dev/null 2>&1 || fail "hold should succeed"
  captain context w1 --text-file "$(say 'Grid or list?')" --option "Grid" >/dev/null 2>&1 || fail "raise should succeed"
  local rec="$HOME_DIR/data/needs-me/w1.json" out rc
  jq --arg long "$(head -c 300 /dev/zero | tr '\0' 'g')" '.options[0].label = $long' "$rec" > "$rec.tmp" && mv "$rec.tmp" "$rec"
  out=$(sync_now)
  rc=$?
  expect_code 1 "$rc" "a decision outside T3's bounds is reported: $out"
  assert_contains "$out" "decision w1 was left off the Bridge" "naming it"
  assert_equals '["w2"]' "$(bridge '[.decisionList.decisions[].id]')" "and the rest still lands"
  pass "fm-t3-needs-me.sh: one decision T3 would refuse never blocks the rest"
}

test_list_without_firstmate_thread_sends_nothing() {
  make_home list-no-parent 'w.threads = {}'
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  sync_now >/dev/null || fail "a pass with no FirstMate thread is not a failure"
  assert_equals "0" "$(list_calls)" "a reply would have nowhere to go, so no list is sent"
  pass "fm-t3-needs-me.sh: with no FirstMate thread the list is not sent"
}

test_list_cleared_while_firstmate_thread_missing_is_sent_once_it_returns() {
  make_home list-parent-gone
  captain hold w1 --reason "Pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "the Bridge shows the call"
  FM_T3_FM=$FM_THREAD t3_fake_set 'w.gone = w.threads[process.env.FM_T3_FM]; delete w.threads[process.env.FM_T3_FM]'
  answer w1 || fail "an answer with no FirstMate thread should succeed"
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "with nowhere to reply, the list is not sent"
  FM_T3_FM=$FM_THREAD t3_fake_set 'w.threads[process.env.FM_T3_FM] = w.gone; delete w.gone'
  sync_now >/dev/null || fail "the pass after FirstMate's thread returns should succeed"
  assert_equals '[]' "$(bridge '.decisionList.decisions')" "the emptied list reaches the Bridge once the thread is back"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an idle pass should succeed"
  assert_equals "0" "$(list_calls)" "and is not sent again"
  pass "fm-t3-needs-me.sh: a list emptied while FirstMate's thread was missing is sent once it returns"
}

test_watcher_wakes_firstmate_on_the_alert() {
  make_home list-watch
  local alert="$HOME_DIR/state/t3-needs-me/.alert" out="$HOME_DIR/watch.out" reason i=0
  reason='check: t3-decisions: T3 did not take the captain'"'"'s decisions 3 passes in a row: fm-t3-mcp: boom'
  mkdir -p "$HOME_DIR/state/t3-needs-me"
  printf '%s\n' "$reason" > "$alert"
  fm_test_track_watcher_state "$HOME_DIR/state"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$HOME_DIR/fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  local pid=$!
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
    fail "the watcher did not wake on the alert"
  fi
  wait "$pid" 2>/dev/null
  assert_contains "$(cat "$out")" "$reason" "the watcher wakes firstmate with the alert's reason"
  assert_absent "$alert" "and consumes the alert"
  assert_contains "$(cut -f4,5 "$HOME_DIR/state/.wake-queue")" "t3-decisions	$reason" "behind one durable check wake"
  pass "fm-watch.sh: a T3 decisions alert wakes firstmate once, durably"
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
  FM_HOME="$home" "$ROOT/bin/fm-objectives.sh" > "$home/source.json" || return 1
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
  assert_equals "false" "$(printf '%s' "$out" | jq 'has("lastReviewed")')" "the review line does not travel"
  assert_equals "5 0" "$(printf '%s' "$out" | jq -r '"\(.objectives) \(.shortened)"')" "five objectives, none shortened"
  printf '# High level objectives\n\nLast reviewed: 2026-10-01\n\n- **Only:** one. Notes: /tmp/x\n' > "$f"
  out=$(objectives_payload "$f")
  assert_equals "- **Only** — one." "$(printf '%s' "$out" | jq -r '.markdown')" "a single objective keeps its text"
  printf '# High level objectives\n\nNothing yet.\n' > "$f"
  assert_equals "null" "$(objectives_payload "$f" | jq -r '.markdown')" "a file with no bullets clears them"
  assert_equals "null" "$(objectives_payload "$TMP_ROOT/none.md" | jq -r '.markdown')" "an absent file clears them"
  pass "fm-t3-mcp.mjs objectives-payload: the bullets, bold names, no local paths, and no review day"
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
  assert_equals '["markdown"]' "$(t3_fake_calls t3_objectives_set | jq -sc '.[0] | keys')" "carrying only the list, no review day"
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
  assert_equals '["w1"]' "$(bridge '[.decisionList.decisions[].id]')" "and the decision still lands"
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

# --- model routing -----------------------------------------------------------

# write_routing <file>: a made-up config/crew-dispatch.json.
write_routing() {
  cat > "$1" <<'EOF'
{
  "rules": [
    { "when": "Hard design work.", "approval": "captain",
      "use": [{ "harness": "claude", "model": "claude-fable-9", "effort": "xhigh" }, { "harness": "codex", "model": "gpt-9-sol", "effort": "high" }],
      "why": "Strongest reasoning." },
    { "when": "Small fixes.", "use": { "harness": "claude", "model": "claude-sonnet-9", "effort": "high" } },
    { "when": "Long chats.", "use": { "harness": "claude", "model": "claude-opus-9" } },
    { "when": "Browsing.", "use": { "harness": "codex", "model": "gpt-9-sol", "effort": "high" } },
    { "when": "Odd jobs.", "use": { "harness": "local", "model": "big|model" } },
    { "when": "Quick drafts.", "use": { "harness": "claude", "model": "claude-fable-9", "effort": "high" } }
  ],
  "default": { "harness": "claude", "model": "claude-opus-9" }
}
EOF
}

routing_payload() {
  node "$ROOT/bin/fm-t3-mcp.mjs" routing-payload --file "$1"
}

routing_calls() {
  t3_fake_calls t3_routing_set | grep -c . || true
}

test_routing_payload_shape() {
  local f="$TMP_ROOT/routing.json" out want long
  write_routing "$f"
  out=$(routing_payload "$f") || fail "the list should build"
  want=$(cat <<'EOF'
#### Anthropic

###### Opus

- `claude · claude-opus-9`\
  Default · Long chats.

###### Fable

- `claude · claude-fable-9 · xhigh`\
  Hard design work. (captain approves)
- `claude · claude-fable-9 · high`\
  Quick drafts.

###### Sonnet

- `claude · claude-sonnet-9 · high`\
  Small fixes.

#### OpenAI

- `codex · gpt-9-sol · high`\
  Hard design work. (captain approves) · Browsing.

#### Other

- `local · big|model`\
  Odd jobs.
EOF
)
  assert_equals "$want" "$(printf '%s' "$out" | jq -r '.markdown')" "grouped by provider then family, the default first, one entry per model with its Whens joined"
  assert_equals "8 0" "$(printf '%s' "$out" | jq -r '"\(.rows) \(.shortened)"')" "eight routes, none shortened"
  assert_not_contains "$(printf '%s' "$out" | jq -r '.markdown')" "Strongest reasoning" "the Why is not shown"
  jq '.rules |= map(select(.when != "Quick drafts."))' "$f" > "$f.next" && mv "$f.next" "$f"
  out=$(routing_payload "$f" | jq -r '.markdown')
  assert_not_contains "$out" "######" "a family heading is left out when every family has one entry"
  assert_contains "$out" $'#### Anthropic\n\n- `claude · claude-opus-9`\\\n  Default · Long chats.\n- `claude · claude-fable-9 · xhigh`' "and the provider stays one list"
  jq -n '{rules: [{when: "- not a list", use: {harness: "a`b"}}, {when: "2. not a list", use: {harness: "c"}}]}' > "$f"
  want=$(cat <<'EOF'
#### Other

- ``a`b``\
  \- not a list
- `c`\
  2\. not a list
EOF
)
  assert_equals "$want" "$(routing_payload "$f" | jq -r '.markdown')" "no model goes under Other; a backtick in the model and a block marker in the When stay text"
  printf '{"rules": []}\n' > "$f"
  assert_equals "null" "$(routing_payload "$f" | jq -r '.markdown')" "no rules and no default give no list"
  long=$(head -c 3000 /dev/zero | tr '\0' 'x')
  jq -n --arg when "$long" '{rules: [range(6) | {when: "Rule \(.) \($when)", approval: (if . == 0 then "captain" else null end), use: {harness: "claude", model: "m\(.)"}, why: $when}], default: {harness: "codex"}}' > "$f"
  out=$(routing_payload "$f") || fail "a long list should build"
  [ "$(printf '%s' "$out" | jq -r '.markdown | length')" -le 8192 ] || fail "the list fits T3's limit"
  assert_equals "7" "$(printf '%s' "$out" | jq -r '.markdown' | grep -c '^- `')" "no entry is dropped"
  assert_equals "6" "$(printf '%s' "$out" | jq -r '.markdown' | grep -c '^  Rule [0-5] x*…\( (captain approves)\)\{0,1\}$')" "each long When is cut, with an ellipsis"
  assert_contains "$(printf '%s' "$out" | jq -r '.markdown')" '… (captain approves)' "the captain's mark survives the cut"
  assert_contains "$(printf '%s' "$out" | jq -r '.markdown')" $'\n  Default\n' "a short When is kept whole"
  assert_equals "6" "$(printf '%s' "$out" | jq -r '.shortened')" "and the count says so"
  printf '{"rules": [{"when": "x", "use": {"model": "m"}}]}\n' > "$f"
  out=$(routing_payload "$f" 2>/dev/null)
  expect_code 1 "$?" "a profile without a harness is malformed"
  assert_equals "routing_malformed" "$(printf '%s' "$out" | jq -r '.error.code')" "and named so"
  assert_contains "$(printf '%s' "$out" | jq -r '.error.message')" "rules[0].use needs harness" "with the field"
  pass "fm-t3-mcp.mjs routing-payload: grouped by provider and family, one entry per model, fits the limit, refuses a malformed file"
}

test_routing_push_only_when_changed() {
  make_home routing 'w.routingTool = true'
  local out rc
  write_routing "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "the first pass pushes the table: $out"
  assert_equals "1" "$(routing_calls)" "one push"
  assert_equals "$(routing_payload "$HOME_DIR/config/crew-dispatch.json" | jq -r '.markdown')" \
    "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "of the built table"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an unchanged pass should succeed"
  assert_equals "0" "$(routing_calls)" "an unchanged table is not pushed again"
  jq '.rules[1].use.model = "newer-model"' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/next.json"
  mv "$HOME_DIR/config/next.json" "$HOME_DIR/config/crew-dispatch.json"
  t3_fake_set 'w.failTools = { t3_routing_set: { code: "unavailable", message: "settings are busy" } }'
  out=$(sync_now)
  rc=$?
  expect_code 1 "$rc" "a failed push is reported: $out"
  assert_contains "$out" "routing" "the line names the routing table"
  t3_fake_set 'delete w.failTools'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(routing_calls)" "the next pass retries"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "newer-model" "with the new model"
  printf '{"rules": "oops"}\n' > "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 1 "$?" "a malformed file is reported: $out"
  assert_contains "$out" "rules must be an array" "naming the fault"
  assert_equals "0" "$(routing_calls)" "and nothing is sent"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "newer-model" "so the Bridge keeps the last table"
  rm -f "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a pass without the file should succeed"
  assert_equals '{"markdown":null}' "$(t3_fake_calls t3_routing_set)" "a removed file clears the table"
  assert_equals "null" "$(jq -c '.modelRouting' "$T3_FAKE_WORLD")" "and T3 holds none"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals "0" "$(routing_calls)" "only once"
  pass "fm-t3-needs-me.sh sync: the routing table is pushed when it changes, retried, kept on a malformed file, cleared once"
}

test_routing_absent_or_unsupported() {
  make_home routing-none 'w.routingTool = true'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a home without a dispatch file should succeed"
  assert_equals "0" "$(routing_calls)" "never sent, so nothing is cleared"
  local out n
  make_home routing-old-t3
  write_routing "$HOME_DIR/config/crew-dispatch.json"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without the routing table is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  for n in 1 2 3 4; do sync_now >/dev/null || fail "a T3 without the routing table stays quiet once held back"; done
  t3_fake_set 'w.routingTool = true'
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 900 )) needs_me sync >/dev/null || fail "the retry should succeed"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "claude-fable-9" "and a T3 that gains it gets the table"
  pass "fm-t3-needs-me.sh sync: no dispatch file sends no routing table; an older T3 is quiet and retried"
}

# --- rules -------------------------------------------------------------------

# write_rules <file>: a made-up data/rules/inventory.json.
write_rules() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
{
  "rules": [
    { "id": "R1", "group": "FirstMate · How to work", "source": "data/captain.md", "text": "Answer in **plain** words.",
      "status": "approved", "approvedOn": "2026-11-08" },
    { "id": "R2", "group": "FirstMate · How to work", "text": "Search before saying not found.", "status": "pending",
      "recommendation": { "choice": "keep-narrower", "label": "Keep narrower", "note": "Too broad.", "proposedText": "Search X first." } },
    { "id": "W1", "group": "Workers", "text": "Use short commands.", "status": "pending",
      "recommendation": { "choice": "drop", "label": "Drop" } }
  ],
  "pendingEdits": [{ "id": "R0", "choice": "drop", "on": "2026-11-09", "text": "Old rule." }]
}
EOF
}

rules_payload() {
  node "$ROOT/bin/fm-t3-mcp.mjs" rules-payload --file "$1"
}

rules_calls() {
  t3_fake_calls t3_rules_set | grep -c . || true
}

# rules_refused <file> <fault>: rules-payload refuses the file, naming <fault>.
rules_refused() {
  local out
  out=$(rules_payload "$1" 2>/dev/null)
  expect_code 1 "$?" "a file outside the contract is refused ($2)"
  assert_equals "rules_malformed" "$(printf '%s' "$out" | jq -r '.error.code')" "and named so ($2)"
  assert_contains "$(printf '%s' "$out" | jq -r '.error.message')" "$2" "with the fault"
}

test_rules_payload_shape() {
  local f="$TMP_ROOT/rules/inventory.json" g="$TMP_ROOT/rules/bad.json" out long
  write_rules "$f"
  out=$(rules_payload "$f") || fail "the list should build"
  assert_equals "3 2" "$(printf '%s' "$out" | jq -r '"\(.count) \(.pending)"')" "three rules, two pending"
  assert_equals "$(jq -c '.rules' "$f")" "$(printf '%s' "$out" | jq -c '.rules')" "sent exactly as kept, pendingEdits left out"
  jq '.rules[0].owner = "me"' "$f" > "$g"; rules_refused "$g" "rules[0] (R1) has unknown field owner"
  jq '.rules[1].id = "R1"' "$f" > "$g"; rules_refused "$g" "repeats id R1"
  jq '.rules[1].id = "R 2"' "$f" > "$g"; rules_refused "$g" "rules[1] (R 2).id must be letters, digits"
  jq '.rules[1].id = 2' "$f" > "$g"; rules_refused "$g" "rules[1].id must be letters, digits"
  jq 'del(.rules[2].recommendation)' "$f" > "$g"; rules_refused "$g" "is pending, so it needs a recommendation"
  jq '.rules[0].recommendation = .rules[2].recommendation' "$f" > "$g"; rules_refused "$g" "is approved, so it takes no recommendation"
  jq '.rules[1].recommendation.choice = "maybe"' "$f" > "$g"; rules_refused "$g" "recommendation.choice must be one of"
  jq '.rules[0].approvedOn = "2026-02-30"' "$f" > "$g"; rules_refused "$g" "approvedOn must be a YYYY-MM-DD date"
  jq '.rules[0].status = "done"' "$f" > "$g"; rules_refused "$g" "status must be"
  long=$(head -c 2001 /dev/zero | tr '\0' 'x')
  jq --arg t "$long" '.rules[0].text = $t' "$f" > "$g"; rules_refused "$g" "text is 2001 characters, past 2000"
  jq --arg t "$long" '.rules[1].recommendation.proposedText = $t' "$f" > "$g"; rules_refused "$g" "proposedText is 2001 characters"
  jq '.rules = [range(401) | {id: "R\(.)", group: "G", text: "t", status: "approved"}]' "$f" > "$g"; rules_refused "$g" "401 rules, past the 400"
  printf '{"rules": []}\n' > "$g"
  assert_equals "0" "$(rules_payload "$g" | jq -r '.count')" "an empty list is a list"
  pass "fm-t3-mcp.mjs rules-payload: sends the contract fields as kept, refuses anything outside the contract"
}

test_rules_push_only_when_changed() {
  make_home rules 'w.rulesTool = true'
  local out inv="$HOME_DIR/data/rules/inventory.json"
  write_rules "$inv"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "the first pass pushes the rules: $out"
  assert_equals "1" "$(rules_calls)" "one push"
  assert_equals "$(jq -c '.rules' "$inv")" "$(jq -c '.rules' "$T3_FAKE_WORLD")" "of the whole list"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an unchanged pass should succeed"
  assert_equals "0" "$(rules_calls)" "an unchanged list is not pushed again"
  jq '.rules[1].text = "Search, then say."' "$inv" > "$inv.next" && mv "$inv.next" "$inv"
  t3_fake_set 'w.rulesAnswer = { rules: 3, pending: 1, sent: [] }'
  out=$(sync_now)
  expect_code 1 "$?" "an answer with the wrong pending count is not proof: $out"
  assert_contains "$out" "counted 3 rules and 1 pending, not 3 and 2" "the line names both counts"
  assert_contains "$out" "rules: the push failed" "the line names the rules"
  t3_fake_set 'delete w.rulesAnswer'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(rules_calls)" "the next pass retries"
  assert_equals "Search, then say." "$(jq -r '.rules[1].text' "$T3_FAKE_WORLD")" "with the new text"
  jq '.rules[0].recommendation = {choice: "keep", label: "Keep"}' "$inv" > "$inv.next" && mv "$inv.next" "$inv"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 1 "$?" "a malformed inventory is reported: $out"
  assert_contains "$out" "is approved, so it takes no recommendation" "naming the fault"
  assert_equals "0" "$(rules_calls)" "and nothing is sent"
  assert_equals "Search, then say." "$(jq -r '.rules[1].text' "$T3_FAKE_WORLD")" "so the Bridge keeps the last list"
  out=$(sync_now)
  expect_code 1 "$?" "and reported again on the next pass: $out"
  rm -f "$inv"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a pass without the inventory should succeed"
  assert_equals '{"rules":[]}' "$(t3_fake_calls t3_rules_set)" "a removed inventory clears the list"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals "0" "$(rules_calls)" "only once"
  pass "fm-t3-needs-me.sh sync: the rules are pushed when they change, proven, retried, kept on a malformed inventory, cleared once"
}

test_rules_absent_or_unsupported() {
  make_home rules-none 'w.rulesTool = true'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a home without an inventory should succeed"
  assert_equals "0" "$(rules_calls)" "never sent, so nothing is cleared"
  local out n
  make_home rules-old-t3
  write_rules "$HOME_DIR/data/rules/inventory.json"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without the rules section is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  for n in 1 2 3 4; do sync_now >/dev/null || fail "a T3 without the rules section stays quiet once held back"; done
  t3_fake_set 'w.rulesTool = true'
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 900 )) needs_me sync >/dev/null || fail "the retry should succeed"
  assert_equals "R1 R2 W1" "$(jq -r '[.rules[].id] | join(" ")' "$T3_FAKE_WORLD")" "and a T3 that gains it gets the list"
  pass "fm-t3-needs-me.sh sync: no inventory sends no rules; an older T3 is quiet and retried"
}

test_objectives_payload_shape
test_objectives_payload_fits_the_limit
test_rules_payload_shape
test_rules_push_only_when_changed
test_rules_absent_or_unsupported
test_routing_payload_shape
test_routing_push_only_when_changed
test_routing_absent_or_unsupported
test_objectives_push_only_when_changed
test_objectives_clear_once_and_back_off
test_context_raise_update_and_guards
test_context_starts_over_on_a_new_hold
test_reply_marker
test_unsupported_t3_or_no_credential_does_nothing
test_secondmate_home_takes_no_part
test_list_carries_every_open_call
test_list_with_only_blocked_calls_is_sent_once
test_list_resend_keeps_the_captains_answer
test_list_carries_the_context_payload
test_list_drops_an_option_detail_from_an_older_record
test_list_dated_hold_waits_until_its_date
test_list_keeps_an_open_call_however_long_it_waits
test_list_restores_what_t3_lost
test_list_failures_wake_firstmate_on_the_third
test_list_leaves_out_a_decision_t3_would_refuse
test_list_without_firstmate_thread_sends_nothing
test_list_cleared_while_firstmate_thread_missing_is_sent_once_it_returns
test_watcher_wakes_firstmate_on_the_alert

echo "ok: fm-t3-needs-me"
