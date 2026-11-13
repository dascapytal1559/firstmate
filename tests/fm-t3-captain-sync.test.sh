#!/usr/bin/env bash
# tests/fm-t3-captain-sync.test.sh - the captain's T3 list follows the backlog
# in real time, both ways: bin/fm-t3-captain-sync.sh listen, apply, and check,
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

SYNC="$ROOT/bin/fm-t3-captain-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-captain-sync)
SERVER_DIR="$TMP_ROOT/server"
t3_fake_start "$SERVER_DIR"
LISTENER_PID=
stop_listener() {
  [ -n "$LISTENER_PID" ] || return 0
  kill "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=
}
cleanup() {
  stop_listener
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

FM_THREAD='mcp:00000000-0000-4000-8000-00000000f1f1'
WORKER_THREAD='mcp:00000000-0000-4000-8000-0000000000a1'

# make_home <name> [world-js] -> HOME_DIR: a main home with the T3 credential,
# backlog rows w1 and w2, and a fake T3 with the action log and crew lineage
# whose project is rooted at the home and whose FirstMate thread is pinned.
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
    w.decisionsTool = true; w.actionsTool = true; w.crewLineage = true; w.coordinatorRestartNote = true;
    w.projects = [{ id: "proj-fm", title: "firstmate", workspaceRoot: process.env.FM_T3_ROOT, defaultModelSelection: null, deletedAt: null }];
    w.threads = { [process.env.FM_T3_FM]: { threadId: process.env.FM_T3_FM, projectId: "proj-fm", title: "FirstMate",
      status: "completed", activeRunId: null, archived: false, worktreePath: null, coordinator: true,
      providerInstanceId: "claudeAgent", model: "claude-opus", runtimeMode: "full-access", items: [], runs: [] } };'
  [ -z "${2:-}" ] || t3_fake_set "$2"
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  (cd "$HOME_DIR" && tasks-axi add w1 "Pick the print layout" --repo sample && tasks-axi add w2 "Buy the camera" --repo sample) >/dev/null \
    || fail "could not seed the backlog rows"
}

home_env() {
  env PATH="$HOME_DIR/fakebin:$PATH" FM_T3_CAPTAIN_SYNC_ARM=0 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

captain() { home_env "$ROOT/bin/fm-captain-hold.sh" "$@"; }
sync_cmd() { home_env "$SYNC" "$@"; }
world() { jq -c "$1" "$T3_FAKE_WORLD"; }
item() { world ".decisionList.decisions[] | select(.id == \"$1\") | $2"; }
body_of() { (cd "$HOME_DIR" && tasks-axi show "$1" --full 2>/dev/null); }
bucket_of() {
  home_env "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input | jq -r --arg id "$1" '.backlog.records[] | select(.id == $id) | .hold_bucket'
}
pushes() { t3_fake_calls t3_decisions_set | wc -l | tr -d ' '; }

# wait_for <seconds> <command...>: true once the command succeeds.
wait_for() {
  local limit=$(( $1 * 10 )) i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

asked_for_actions() { [ -n "$(t3_fake_calls t3_decisions_actions)" ]; }

start_listener() {
  home_env "$SYNC" listen >/dev/null 2>"$HOME_DIR/listener.err" &
  LISTENER_PID=$!
  wait_for 20 grep -q 'listening' "$HOME_DIR/state/t3-captain-sync/listen.log" 2>/dev/null \
    || fail "the listener did not start: $(cat "$HOME_DIR/listener.err")"
  # Its first act is one full push; let it land.
  wait_for 30 asked_for_actions \
    || fail "the listener never asked for the captain's actions: $(tail -n 5 "$HOME_DIR/state/t3-captain-sync/listen.log")"
}

add_action() {  # <json>
  FM_ACTION=$1 t3_fake_set 'w.actions = [...(w.actions || []), JSON.parse(process.env.FM_ACTION)]'
}

acked() {  # <seq>
  [ "$(world "[.acks[]? | select(.seq == $1)] | length")" -ge 1 ]
}

has_item() { [ -n "$(item "$1" .id)" ]; }
lacks_item() { [ -z "$(item "$1" .id)" ]; }

test_backlog_edit_pushes_once() {
  make_home edit
  captain hold w1 --reason "Grid or list?" >/dev/null 2>&1 || fail "hold should succeed"
  start_listener
  sleep 1
  : > "$T3_FAKE_LOG"
  # Straight to the backlog, as any writer would, with no sync of its own.
  (cd "$HOME_DIR" && tasks-axi hold w2 --reason "Buy it" --kind captain) >/dev/null 2>&1 || fail "the edit should succeed"
  wait_for 15 has_item w2 || fail "the edit never reached T3: $(tail -n 5 "$HOME_DIR/state/t3-captain-sync/listen.log")"
  sleep 2
  assert_equals "1" "$(pushes)" "one backlog edit is one push"
  assert_equals '["w1","w2"]' "$(world '[.decisionList.decisions[].id] | sort')" "carrying the whole list"
  stop_listener
  pass "fm-t3-captain-sync.sh listen: a backlog edit reaches T3 as exactly one whole-list push"
}

test_action_applies_then_pushes_then_acks() {
  make_home action
  captain hold w1 --reason "Grid or list?" >/dev/null 2>&1 || fail "hold should succeed"
  start_listener
  : > "$T3_FAKE_LOG"
  add_action '{"seq":1,"commandId":"c1","itemId":"w1","revision":1,"type":"snooze","until":null,"at":"2026-11-13T01:00:00.000Z"}'
  wait_for 20 acked 1 || fail "the snooze was never acknowledged"
  assert_equals "snoozed" "$(bucket_of w1)" "the backlog holds the snooze"
  assert_equals '{"at":"2026-11-13T01:00:00Z","until":null}' "$(item w1 .snoozed)" "and T3's list shows it"
  assert_equals '"applied"' "$(world '[.acks[] | select(.seq == 1)][0].outcome')" "acknowledged as applied"
  assert_equals '{"at":"2026-11-13T01:00:00Z","until":null}' \
    "$(world '[.acks[] | select(.seq == 1)][0].list[] | select(.id == "w1") | .snoozed')" \
    "the list showed the snooze before T3 heard the acknowledgement"
  add_action '{"seq":2,"commandId":"c2","itemId":"w1","revision":1,"type":"unsnooze","at":"2026-11-13T02:00:00.000Z"}'
  wait_for 20 acked 2 || fail "the bring-back was never acknowledged"
  assert_equals "live" "$(bucket_of w1)" "Bring back returns it"
  assert_equals 'null' "$(item w1 .snoozed)" "and T3's list too"
  add_action '{"seq":3,"commandId":"c3","itemId":"nobody-holds-this","revision":1,"type":"snooze","until":null,"at":"2026-11-13T02:00:00.000Z"}'
  wait_for 20 acked 3 || fail "an action on an unknown item was never answered"
  assert_equals '"refused"' "$(world '[.acks[] | select(.seq == 3)][0].outcome')" "an item FirstMate does not hold is refused"
  stop_listener
  pass "fm-t3-captain-sync.sh listen: an action changes the backlog, then the list, then is acknowledged"
}

test_apply_snooze_to_a_time_and_archive_replay() {
  make_home apply
  captain hold w1 --reason "Grid or list?" >/dev/null 2>&1 || fail "hold should succeed"
  captain hold w2 --reason "Buy it?" >/dev/null 2>&1 || fail "hold should succeed"
  printf '%s\n' '{"seq":1,"itemId":"w1","revision":1,"type":"snooze","until":"2099-01-04T22:30:00.000+11:00","at":"2099-01-01T00:00:00.000Z"}' > "$HOME_DIR/a1.json"
  sync_cmd apply --file "$HOME_DIR/a1.json" >/dev/null 2>&1 || fail "a snooze to a time should apply"
  assert_contains "$(body_of w1)" "Captain hold returns: 2099-01-04T11:30:00Z" "the exact return time is kept, in UTC"
  assert_contains "$(body_of w1)" "hold_until: 2099-01-05" "the backlog's own date never lifts before it"
  assert_equals '{"at":"2099-01-01T00:00:00Z","until":"2099-01-04T11:30:00Z"}' "$(item w1 .snoozed)" "T3 is told the return time"
  printf '%s\n' '{"seq":2,"itemId":"w2","revision":1,"type":"archive","at":"2026-11-13T23:59:00.000Z"}' > "$HOME_DIR/a2.json"
  sync_cmd apply --file "$HOME_DIR/a2.json" >/dev/null 2>&1 || fail "an archive should apply"
  assert_contains "$(body_of w2)" "Archived in T3 on 2026-11-13: not pursued." "archive closes a decision as not pursued"
  assert_not_contains "$(body_of w2)" "parked" "and never calls it parked"
  FM_CAPTAIN_HOLD_NOW=2026-11-14T09:00:00Z sync_cmd apply --file "$HOME_DIR/a2.json" >/dev/null 2>&1 \
    || fail "the same action replayed next day should apply again as a no-op"
  assert_equals "1" "$(body_of w2 | grep -c 'not pursued')" "a replay the next day writes the same words once"
  lacks_item w2 || fail "the archived item leaves T3's list"
  pass "fm-t3-captain-sync.sh apply: a snooze keeps its return time, and an archive replays as the same words"
}

test_archive_on_a_running_worker_leaves_a_wind_down_notice() {
  make_home running
  FM_T3_W=$WORKER_THREAD t3_fake_set 'w.threads[process.env.FM_T3_W] = { threadId: process.env.FM_T3_W, projectId: "proj-fm", title: "Worker",
    status: "running", activeRunId: "run-1", archived: false, worktreePath: "/tmp/wt", items: [], runs: [] }'
  printf 'kind=ship\nbackend=t3code\nt3_thread_id=%s\n' "$WORKER_THREAD" > "$HOME_DIR/state/w1.meta"
  captain hold w1 --reason "Keep going?" >/dev/null 2>&1 || fail "hold should succeed"
  assert_equals "{\"id\":\"$WORKER_THREAD\",\"finished\":false}" "$(item w1 .thread)" "the item rides on the running worker's card"
  printf '%s\n' '{"seq":1,"itemId":"w1","revision":1,"type":"archive","at":"2026-11-13T01:00:00.000Z"}' > "$HOME_DIR/a.json"
  sync_cmd apply --file "$HOME_DIR/a.json" >/dev/null 2>&1 || fail "archive should apply"
  assert_contains "$(body_of w1)" "not pursued" "the decision is closed as not pursued"
  assert_contains "$(cat "$HOME_DIR/state/t3-captain-sync/w1.wake" 2>/dev/null)" "check: t3-captain w1: " "firstmate is told to wind the worker down"
  assert_contains "$(cat "$HOME_DIR/state/t3-captain-sync/w1.wake")" "never discarding unlanded work" "safely"
  assert_equals "false" "$(world ".threads[\"$WORKER_THREAD\"].archived")" "the thread itself is not archived"
  pass "fm-t3-captain-sync.sh apply: Archive on a running worker closes the item and asks for a safe wind-down"
}

test_item_without_worker_gets_its_own_thread_and_check_catches_a_lost_archive() {
  make_home light
  captain hold w1 --reason "Grid or list for the print view?" >/dev/null 2>&1 || fail "hold should succeed"
  local thread
  thread=$(jq -r '.w1 // ""' "$HOME_DIR/state/t3-needs-me/threads.json" 2>/dev/null)
  [ -n "$thread" ] || fail "an item with no worker gets a thread of its own"
  assert_equals "{\"id\":\"$thread\",\"finished\":true}" "$(item w1 .thread)" "it rides on that thread's card"
  assert_equals '"Grid or list for the print view?"' "$(world ".threads[\"$thread\"].title")" "titled with the question"
  assert_equals "\"$FM_THREAD\"" "$(world ".threads[\"$thread\"].parentThreadId")" "as crew of FirstMate"
  assert_equals '[]' "$(world ".threads[\"$thread\"].runs")" "with nothing posted into it"
  captain hold w1 --reason "Grid or list for the print view?" >/dev/null 2>&1 || fail "a repeat hold should succeed"
  assert_equals "1" "$(t3_fake_calls t3_thread_launch | wc -l | tr -d ' ')" "a repeat never launches a second thread"
  # The captain archives the thread, and T3's record of it is lost.
  FM_T3_T=$thread t3_fake_set 'w.threads[process.env.FM_T3_T].archived = true'
  sync_cmd check >/dev/null 2>&1 || true
  assert_contains "$(body_of w1)" "not pursued" "the ten-minute check closes it as not pursued"
  lacks_item w1 || fail "and it leaves T3's list"
  assert_equals '{}' "$(jq -c . "$HOME_DIR/state/t3-needs-me/threads.json")" "its thread is let go"
  # FirstMate closes an item itself: its thread is archived.
  captain hold w2 --reason "Buy it?" >/dev/null 2>&1 || fail "hold should succeed"
  thread=$(jq -r '.w2' "$HOME_DIR/state/t3-needs-me/threads.json")
  printf 'Buy it.\n' > "$HOME_DIR/decision"
  captain answer w2 --decision-file "$HOME_DIR/decision" >/dev/null 2>&1 || fail "answer should succeed"
  assert_equals "true" "$(world ".threads[\"$thread\"].archived")" "an answered item's own thread is archived"
  pass "fm-t3-captain-sync.sh: an item with no worker gets a thread of its own, and check catches a lost archive"
}

test_listener_rides_out_t3_down() {
  make_home down
  captain hold w1 --reason "Grid or list?" >/dev/null 2>&1 || fail "hold should succeed"
  start_listener
  t3_fake_stop
  (cd "$HOME_DIR" && tasks-axi hold w2 --reason "Buy it" --kind captain) >/dev/null 2>&1 || fail "the edit should succeed"
  sleep 2
  t3_fake_restart "$SERVER_DIR"
  wait_for 45 has_item w2 || fail "T3 never got the list back after it returned"
  stop_listener
  pass "fm-t3-captain-sync.sh listen: with T3 down it retries, and pushes the whole list once T3 is back"
}

test_migration_moves_kept_cards_and_pinned_reports() {
  local out
  make_home migrate 'w.reportsTool = true; w.pinnedReports = [
    { id: "w2", title: "Camera report", pinnedAt: "2026-11-10T00:00:00.000Z" },
    { id: "old-night", title: "Last night", pinnedAt: "2026-11-11T00:00:00.000Z" }];'
  printf 'kind=scout\nbackend=t3code\nt3_thread_id=%s\nt3_review=waiting\n' "$WORKER_THREAD" > "$HOME_DIR/state/w1.meta"
  mkdir -p "$HOME_DIR/data/w1" "$HOME_DIR/data/w2"
  printf '**Firstmate summary**\n\nThe grid wins.\n\n**Full explanation**\n\nBecause.\n' > "$HOME_DIR/data/w1/handoff-r1.md"
  printf '# Camera\n' > "$HOME_DIR/data/w2/report.md"
  printf '# Night\n' > "$HOME_DIR/night.md"
  jq -n --arg loc "$HOME_DIR/night.md" '{pinnedReports: {"old-night": {title: "Last night", summary: "Two things broke.", location: $loc, pinnedAt: "x"}}}' \
    > "$HOME_DIR/t3-settings.json"
  out=$(sync_cmd migrate --t3-settings "$HOME_DIR/t3-settings.json" 2>&1) || fail "the migration failed: $out"
  assert_contains "$(body_of w1)" "Captain hold flavor: read" "a kept card is held To read"
  assert_equals "The grid wins." "$(home_env "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input \
    | jq -r '.backlog.records[] | select(.id == "w1") | .hold_reason')" "with its summary as the reason"
  assert_contains "$(body_of w2)" "Captain hold flavor: read" "a pinned report whose task is open is held To read"
  assert_equals '"report"' "$(jq '.entries[0].attachments[0].kind' "$HOME_DIR/data/needs-me/w2.json")" "with its report attached"
  assert_contains "$(body_of read-old-night)" "Captain hold flavor: read" "any other pinned report becomes a new To read item"
  assert_equals "$HOME_DIR/night.md" "$(jq -r '.entries[0].attachments[0].path' "$HOME_DIR/data/needs-me/read-old-night.json")" \
    "linked from T3's own settings"
  assert_equals '[]' "$(world '.pinnedReports')" "and every report is unpinned"
  out=$(sync_cmd migrate --t3-settings "$HOME_DIR/t3-settings.json" 2>&1) || fail "a repeat migration failed: $out"
  pass "fm-t3-captain-sync.sh migrate: kept cards and pinned reports become To read items, once"
}

test_backlog_edit_pushes_once
test_migration_moves_kept_cards_and_pinned_reports
test_action_applies_then_pushes_then_acks
test_apply_snooze_to_a_time_and_archive_replay
test_archive_on_a_running_worker_leaves_a_wind_down_notice
test_item_without_worker_gets_its_own_thread_and_check_catches_a_lost_archive
test_listener_rides_out_t3_down

echo "ok: fm-t3-captain-sync"
