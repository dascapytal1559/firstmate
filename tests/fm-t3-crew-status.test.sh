#!/usr/bin/env bash
# tests/fm-t3-crew-status.test.sh - a live T3 worker's crew card status is a
# projection of its captain holds, its current state, its steering inbox, and
# its turn: bin/fm-t3-crew-status.sh driven through the real
# bin/fm-captain-hold.sh, bin/fm-crew-state.sh, bin/fm-teardown.sh, and
# bin/fm-watch.sh against the fake T3 server, with real tasks-axi backlogs.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

STATUS_SCRIPT="$ROOT/bin/fm-t3-crew-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-crew-status)
t3_fake_start "$TMP_ROOT/server"
cleanup() {
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

THREAD='mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345'
TITLE='Print view for one recipe'
WAITING='Waiting for captain'
TESTING='Testing'

# make_home <name> -> sets HOME_DIR and a fresh fake T3 world with one thread
# titled $TITLE, for a home holding the credential and an open backlog row `w1`.
make_home() {
  local fakebin
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fakebin=$(fm_fakebin "$HOME_DIR")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  t3_fake_case "$HOME_DIR/world"
  FM_T3_TITLE=$TITLE t3_fake_set 'w.statusLabels = true; w.threads = { "mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345": { threadId: "mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345", projectId: "proj-1",
    title: process.env.FM_T3_TITLE, status: "completed", activeRunId: null, archived: false, items: [], runs: [] } };'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  (cd "$HOME_DIR" && tasks-axi add w1 "$TITLE" --repo sample) >/dev/null \
    || fail "could not seed the backlog row"
  worker_meta w1
}

worker_meta() {  # <id> [kind] [backend] [extra-meta...]
  local id=$1 kind=${2:-ship} backend=${3:-t3code}
  shift
  [ "$#" = 0 ] || shift
  [ "$#" = 0 ] || shift
  [ -d "$HOME_DIR/copy" ] || git init -q "$HOME_DIR/copy"
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=$id" "endpoint_task_id=$id" "kind=$kind" \
    "harness=claude" "backend=$backend" "t3_thread_id=$THREAD" "t3_project_id=proj-1" "worktree=$HOME_DIR/copy" "$@"
}

# second_worker <id> <thread> [kind] -> another live T3 worker on its own thread.
second_worker() {
  FM_T3_ID=$2 t3_fake_set 'w.threads[process.env.FM_T3_ID] = { threadId: process.env.FM_T3_ID, projectId: "proj-1",
    title: "other", status: "completed", activeRunId: null, archived: false, items: [], runs: [] };'
  fm_write_meta "$HOME_DIR/state/$1.meta" "window=$1" "endpoint_task_id=$1" "kind=${3:-ship}" \
    "harness=claude" "backend=t3code" "t3_thread_id=$2" "t3_project_id=proj-1" "worktree=$HOME_DIR/copy"
}

# in_a_run [kind] -> a worker with its own branch and a no-mistakes that reports
# whatever run_is writes; `no-mistakes axi status` answers nothing until then.
in_a_run() {  # [kind]
  local fb="$HOME_DIR/fakebin" wt="$HOME_DIR/copy"
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/w1
  worker_meta w1 "${1:-ship}"
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  axi:) if [ -e "$HOME_DIR/run-overview" ]; then cat "$HOME_DIR/run-overview"; else cat "$HOME_DIR/run" 2>/dev/null; fi ;;
  axi:status) cat "$HOME_DIR/run" 2>/dev/null ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
}

run_is() {  # <running|parked|unreadable|ended>
  local head
  head=$(git -C "$HOME_DIR/copy" rev-parse HEAD)
  rm -f "$HOME_DIR/run" "$HOME_DIR/run-overview"
  case "$1" in
    running|unreadable)
      printf 'run:\n  id: "01RUN"\n  branch: fm/w1\n  status: running\n  head: "%s"\n  pr: ""\n  findings: none\n' "$head" > "$HOME_DIR/run"
      [ "$1" = running ] || : > "$HOME_DIR/run-overview"
      ;;
    parked)
      printf 'run:\n  id: "01RUN"\n  branch: fm/w1\n  status: awaiting_approval\n  awaiting_agent: parked 2m10s\n  head: "%s"\n  pr: ""\n  findings: none\ngate: review\n' "$head" > "$HOME_DIR/run"
      ;;
  esac
}

home_env() {
  env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

captain() {  # <hold-args...>
  home_env "$ROOT/bin/fm-captain-hold.sh" "$@"
}

cards() {  # <status-args...>
  home_env "$STATUS_SCRIPT" "$@"
}

answer() {  # <task-id> [--release]
  local id=$1
  shift
  printf 'go ahead\n' > "$HOME_DIR/decision"
  captain answer "$id" --decision-file "$HOME_DIR/decision" "$@" >/dev/null 2>&1
}

thread_field() {  # <title|statusLabel|statusLabelSince> [thread]
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(w.threads[process.argv[2]][process.argv[3]] ?? "");
' "$T3_FAKE_WORLD" "${2:-$THREAD}" "$1"
}

card_of() {  # [thread]
  thread_field statusLabel "${1:-$THREAD}"
}

updates() {
  t3_fake_calls t3_thread_update | wc -l | tr -d ' '
}

turn_is() {  # <running|settled|failed>
  FM_T3_ID=$THREAD FM_T3_TURN=$1 t3_fake_set '
const t = w.threads[process.env.FM_T3_ID];
const turn = process.env.FM_T3_TURN;
t.status = turn === "settled" ? "completed" : turn;
t.activeRunId = turn === "running" ? "run-1" : null;
t.runs = [{ runId: "run-1", ordinal: 1, status: t.status }];'
}

declares() {  # <status-line> -> w1's status log holds exactly that line
  printf '%s\n' "$1" > "$HOME_DIR/state/w1.status"
}

inbox_message() {  # -> the path of a fresh unhandled steering-inbox message for w1
  # shellcheck disable=SC2016  # expanded by the inner shell
  home_env bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" w1 "the captain replied"' _ "$ROOT" "$HOME_DIR/state"
}

await_card() {  # <label>: up to 10s
  local i=0
  while [ "$i" -lt 100 ] && [ "$(card_of)" != "$1" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

test_wait_shows_only_between_turns() {
  local msg
  make_home turns
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold with the worker between turns shows the wait"

  turn_is running
  cards sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "a worker mid-turn drops the wait so T3 shows Working"
  captain open w1 || fail "the label never touches the hold"
  turn_is settled
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the turn ending with the hold open brings the wait back"

  msg=$(inbox_message) || fail "could not write an inbox message"
  cards sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "an unhandled steering-inbox message drops the wait before T3 reports the turn"
  mkdir -p "${msg%/*}/handled" && mv "$msg" "${msg%/*}/handled/"
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "once the message is handled and the turn is over, the wait is back"

  turn_is failed
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  cards sync || fail "sync should pass"
  assert_equals "Unchanged" "$(card_of)" "a turn that cannot be read changes no card"

  turn_is settled
  answer w1 --release || fail "the release should succeed"
  assert_equals "" "$(card_of)" "the release still clears the card"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "no hold index is written"
  pass "fm-t3-crew-status: the wait shows only between turns and returns when a turn ends with the hold open"
}

test_inbox_delivery_drops_the_wait_at_once() {
  local msg
  make_home delivery
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "the wait shows first"
  msg=$(inbox_message) || fail "could not write an inbox message"
  # shellcheck disable=SC2016  # expanded by the inner shell
  home_env bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring t3code "$2" "$3" fm-w1' _ "$ROOT" "$THREAD" "$msg" \
    || fail "the doorbell should ring"
  await_card ""
  assert_equals "" "$(card_of)" "a delivered doorbell drops the wait within seconds, with no watcher running"
  captain open w1 || fail "the delivery leaves the hold open"
  mkdir -p "${msg%/*}/handled" && mv "$msg" "${msg%/*}/handled/"
  turn_is settled
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the wait returns from the hold alone once the message is handled and the turn ends"
  pass "fm-task-inbox-lib: a doorbell delivered to a T3 worker drops its card's wait at once"
}

test_concurrent_syncs_end_on_the_latest_read() {
  local pids='' i
  make_home concurrent
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  turn_is running
  for i in 1 2 3 4; do
    cards sync >/dev/null 2>&1 &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086  # one pid per word
  wait $pids
  assert_equals "" "$(card_of)" "racing passes all read the worker mid-turn"
  assert_absent "$HOME_DIR/state/.t3-crew-status.lock" "the last pass lets go of the lock"
  assert_absent "$HOME_DIR/state/.t3-crew-status.again" "no pass is left owed"
  ln -s 999999 "$HOME_DIR/state/.t3-crew-status.lock"
  turn_is settled
  cards sync || fail "a lock left by a killed pass is taken over"
  assert_equals "$WAITING" "$(card_of)" "the pass after a killed one still runs"
  pass "fm-t3-crew-status: passes run one at a time, and a killed pass's lock is taken over"
}

test_hold_labels_and_release_clears() {
  make_home own-row
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold on the worker's own task labels its card"
  assert_equals "$TITLE" "$(thread_field title)" "the title stays plain"
  answer w1 --release || fail "the release should succeed"
  assert_equals "" "$(card_of)" "releasing the hold clears the card"
  assert_equals "$TITLE" "$(thread_field title)" "the title is never touched"
  assert_equals 0 "$(t3_fake_calls t3_thread_update | grep -c '"action":"rename"')" "nothing renames the thread"
  pass "fm-t3-crew-status: a hold on the worker's task labels the card, and the release clears it"
}

test_answer_and_repeat_hold_are_clean() {
  make_home closing-answer
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  captain hold w1 --reason "pick the layout, still" >/dev/null || fail "a repeated hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a repeated hold keeps the label"
  assert_equals 1 "$(updates)" "a repeated hold updates nothing"
  answer w1 || fail "the closing answer should succeed"
  assert_equals "" "$(card_of)" "a closing answer clears the card"
  pass "fm-t3-crew-status: a repeated hold changes nothing, and a closing answer clears"
}

test_status_decision_alone_is_no_captain_wait() {
  make_home status-only
  declares 'needs-decision [key=layout] [at=1700000000]: which layout'
  cards sync || fail "sync should pass"
  assert_equals "Waiting" "$(card_of)" "a worker's own needs-decision line is a wait on firstmate"
  captain hold w1 --reason "which layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "only firstmate holding the question makes it the captain's"
  pass "fm-t3-crew-status: a needs-decision line alone is not a captain wait"
}

test_origin_holds_label_until_the_last_ends() {
  local origin
  make_home origin
  worker_meta w1 scout
  captain hold w1-layout --title "Which layout" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "an origin hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold whose origin is the worker labels that worker"
  origin=$(home_env "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input \
    | jq -r '.backlog.records[] | select(.id == "w1-layout") | .hold_origin')
  assert_equals w1 "$origin" "the snapshot carries the hold's origin as a field"
  captain hold w1-colour --title "Which colour" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "a second origin hold should succeed"
  answer w1-layout || fail "the first answer should succeed"
  assert_equals "$WAITING" "$(card_of)" "the label stays while another hold on the worker is open"
  answer w1-colour || fail "the second answer should succeed"
  assert_equals "" "$(card_of)" "the last hold ending clears the card"
  pass "fm-t3-crew-status: a question held with --origin labels the worker until its last hold ends"
}

test_failed_label_converges_on_the_next_sync() {
  make_home failed-label
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "pick the layout" >/dev/null 2>"$HOME_DIR/err" || fail "a failed label must not fail the hold"
  assert_grep "could not set the status" "$HOME_DIR/err" "a failed label is reported"
  t3_fake_set 'delete w.failTools'
  cards sync || fail "the retry should pass"
  assert_equals "$WAITING" "$(card_of)" "the next pass applies the label"

  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  answer w1 --release || fail "a failed clear must not fail the release"
  assert_equals "$WAITING" "$(card_of)" "the failed clear left the label"
  cards sync >/dev/null && fail "sync reports a label it could not set"
  t3_fake_set 'delete w.failTools'
  cards sync || fail "the retry should pass"
  assert_equals "" "$(card_of)" "the next pass clears the card"
  pass "fm-t3-crew-status: a failed label never fails the hold or answer, and the next pass converges"
}

test_server_down_converges_after_restart() {
  local out
  make_home restart
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_stop
  answer w1 --release || fail "a release must not need T3"
  out=$(cards sync) && fail "a pass that cannot reach T3 reports it"
  assert_contains "$out" "T3 could not take the crew cards" "the unreachable T3 is named"
  t3_fake_restart "$TMP_ROOT/server"
  assert_equals "$WAITING" "$(card_of)" "the label is durable across the restart"
  cards sync || fail "the pass after the restart should succeed"
  assert_equals "" "$(card_of)" "the pass after the restart clears the card"
  pass "fm-t3-crew-status: a clear that met a stopped T3 lands once T3 is back"
}

test_restart_that_loses_labels_is_republished() {
  local other='mcp:9d1e2f3a-4b5c-4d6e-8f70-123456789abc'
  make_home republish
  second_worker w2 "$other" scout
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  printf 'done [at=1700000000]: report ready\n' > "$HOME_DIR/state/w2.status"
  mkdir -p "$HOME_DIR/data/w2" && printf 'report\n' > "$HOME_DIR/data/w2/report.md"
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the first worker waits on the captain"
  assert_equals "Ready" "$(card_of "$other")" "the second worker is ready"
  t3_fake_stop
  t3_fake_set 'for (const t of Object.values(w.threads)) { delete t.statusLabel; delete t.statusLabelSince; }'
  t3_fake_restart "$TMP_ROOT/server"
  cards sync || fail "the pass after the restart should succeed"
  assert_equals "$WAITING" "$(card_of)" "a label the restart lost is set again"
  assert_equals "Ready" "$(card_of "$other")" "on every card, from one pass"
  pass "fm-t3-crew-status: a T3 restart that loses labels is repaired by the next pass"
}

test_live_label_is_the_base() {
  make_home relabelled
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_ID].statusLabel'
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the label returns on a card that lost it"
  pass "fm-t3-crew-status: a sync compares against the live card"
}

test_unreadable_backlog_leaves_the_card() {
  local out
  make_home unreadable
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  : > "$T3_FAKE_LOG"
  chmod 000 "$HOME_DIR/data/backlog.md"
  out=$(cards sync) && fail "a pass that cannot read the holds reports it"
  chmod 644 "$HOME_DIR/data/backlog.md"
  assert_contains "$out" "the backlog could not be read" "the unreadable backlog is named"
  assert_equals "Unchanged" "$(card_of)" "holds that cannot be read change no card"
  assert_equals "" "$(t3_fake_mutations)" "and change nothing in T3"
  pass "fm-t3-crew-status: holds that cannot be read leave every card alone"
}

test_gone_thread_or_worker_is_no_failure() {
  make_home gone
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].archived = true'
  cards sync || fail "an archived thread is no failure"
  assert_equals "" "$(card_of)" "an archived thread loses the label"
  FM_T3_ID=$THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_ID]'
  cards sync || fail "a deleted thread is no failure"
  : > "$T3_FAKE_LOG"
  rm -f "$HOME_DIR/state/w1.meta"
  cards sync || fail "a worker with no record is no failure"
  assert_equals "" "$(t3_fake_calls t3_thread_read)" "a hold with no running worker has no card to read"
  captain open w1 || fail "the hold stays open"
  pass "fm-t3-crew-status: a gone thread or worker is no failure and leaves the hold alone"
}

test_only_t3_workers_are_labelled() {
  make_home other-backend
  worker_meta w1 ship tmux
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  # The hold's decision sync (bin/fm-t3-needs-me.sh) may still open a
  # session; no thread of a worker on another backend is read or changed.
  assert_equals "" "$(t3_fake_calls t3_thread_read)$(t3_fake_mutations)" "another backend makes no T3 thread call"
  make_home secondmate
  worker_meta w1 secondmate
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "" "$(t3_fake_calls t3_thread_read)" "a secondmate's thread is no task card"
  make_home no-token
  rm -f "$HOME_DIR/config/t3code-token"
  cards sync || fail "a home without T3 has nothing to do"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "" "$(card_of)" "a home without T3 labels nothing"
  pass "fm-t3-crew-status: only a recorded T3 ship or scout is labelled"
}

test_clear_takes_the_label_off_while_the_hold_stays() {
  make_home clear
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  cards clear w1 >/dev/null && fail "clear reports a label it could not take off"
  t3_fake_set 'delete w.failTools'
  cards clear w1 || fail "clear should pass"
  assert_equals "" "$(card_of)" "clear takes the label off with the hold still open"
  captain open w1 || fail "clear must leave the captain's hold open"
  cards clear w9 || fail "clearing a task with no T3 card is no failure"
  pass "fm-t3-crew-status: clear takes the label off and leaves the hold open"
}

# teardown_home <name> -> a finished scout with an open hold, ready for cleanup.
teardown_home() {
  local proj wt fb
  make_home "$1"
  proj="$HOME_DIR/project"; wt="$HOME_DIR/wt"
  fm_git_worktree "$proj" "$wt" "fm/w1"
  fm_write_meta "$HOME_DIR/state/w1.meta" "window=fm-w1" "endpoint_task_id=w1" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=t3code" "t3_thread_id=$THREAD" \
    "t3_project_id=proj-1" "decisions_reviewed=1" "decision_keys=" "spawn_gen=fixture-w1"
  mkdir -p "$HOME_DIR/data/w1"
  printf 'report\n' > "$HOME_DIR/data/w1/report.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fb="$HOME_DIR/fakebin"
  cat > "$fb/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != get ] || printf '%s\n' "$wt"
exit 0
SH
  chmod +x "$fb/treehouse"
}

test_teardown_clears_before_it_archives() {
  local out rc
  teardown_home teardown
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "the scout waits on the captain before cleanup"
  : > "$T3_FAKE_LOG"
  out=$(home_env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" w1 2>&1)
  rc=$?
  expect_code 0 "$rc" "teardown should succeed: $out"
  assert_equals "t3_thread_update t3_thread_organize" "$(t3_fake_mutations)" "the label comes off before the thread is archived"
  assert_equals "" "$(card_of)" "the archived thread keeps no label"
  assert_equals "$TITLE" "$(thread_field title)" "the archived thread keeps its own title"
  : > "$T3_FAKE_LOG"
  cards sync || fail "a pass after cleanup should pass"
  assert_equals "" "$(t3_fake_calls t3_thread_read)" "a torn-down worker's card is never visited again"
  pass "fm-teardown.sh: clears the label before it archives a worker with an open captain wait"
}

test_testing_follows_the_run() {
  local since
  make_home testing
  in_a_run
  cards sync || fail "a pass with no run should pass"
  assert_equals 0 "$(updates)" "a worker with no run costs no update"

  run_is running
  cards sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "an active run shows Testing"
  assert_equals "$TITLE" "$(thread_field title)" "Testing leaves the title plain"
  since=$(thread_field statusLabelSince)
  [ -n "$since" ] || fail "T3 stamps when Testing started"

  run_is parked
  sleep 1
  cards sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "a run parked at a gate is still active"
  assert_equals 1 "$(updates)" "a repeat updates nothing"
  assert_equals "$since" "$(thread_field statusLabelSince)" "Testing keeps its start time"
  turn_is running
  cards sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "Testing shows while the worker works too"
  assert_equals "$since" "$(thread_field statusLabelSince)" "and keeps its start time through the turn"
  turn_is settled

  run_is unreadable
  home_env "$ROOT/bin/fm-crew-state.sh" w1 > "$HOME_DIR/crew-state"
  assert_grep "state: unknown · source: run-step" "$HOME_DIR/crew-state" "this case must be a run that cannot be read"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  cards sync || fail "the pass should pass"
  assert_equals "Unchanged" "$(card_of)" "a run that cannot be read changes no card"

  run_is ended
  cards sync || fail "the pass should pass"
  assert_equals "" "$(card_of)" "the end of the run clears the card"
  pass "fm-t3-crew-status: Testing shows while the run is active, keeps its start time, and clears when it ends"
}

test_a_pass_that_finds_another_running_is_owed() {
  local holder
  make_home runs-coalesced
  in_a_run
  run_is running
  sleep 30 &
  holder=$!
  ln -s "$holder" "$HOME_DIR/state/.t3-crew-status.lock"
  cards sync || fail "a pass that finds another running should pass"
  assert_equals "" "$(card_of)" "it leaves the work to the running pass"
  assert_present "$HOME_DIR/state/.t3-crew-status.again" "and asks it for one more pass"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  cards sync || fail "the next pass should pass"
  assert_equals "$TESTING" "$(card_of)" "the next pass reads the run like any other"
  assert_absent "$HOME_DIR/state/.t3-crew-status.lock" "the pass lets go of the lock"
  assert_absent "$HOME_DIR/state/.t3-crew-status.again" "and owes nothing"
  pass "fm-t3-crew-status: a pass that finds another running is owed, and the next pass reads every run"
}

test_waiting_outranks_testing() {
  local since
  make_home outranks
  in_a_run
  run_is running
  cards sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "the run shows first"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold outranks the run at once"
  cards sync || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "a later pass keeps the wait on top"
  turn_is running
  cards sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "a worker mid-turn through the wait shows its active run"
  turn_is settled
  cards sync || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "the turn's end puts the wait back on top"
  since=$(thread_field statusLabelSince)
  sleep 1
  answer w1 --release || fail "the release should succeed"
  assert_equals "$TESTING" "$(card_of)" "the end of the wait falls back to the run"
  [ "$(thread_field statusLabelSince)" != "$since" ] || fail "Testing after a wait starts its own clock"
  run_is ended
  cards sync || fail "the pass should pass"
  assert_equals "" "$(card_of)" "then the end of the run clears the card"
  pass "fm-t3-crew-status: Waiting for captain outranks Testing, and Testing returns when the wait ends"
}

test_a_scout_never_shows_testing() {
  make_home scout
  in_a_run scout
  run_is running
  cards sync || fail "the pass should pass"
  assert_equals 0 "$(updates)" "a scout's run is not read, and its card is left alone"
  pass "fm-t3-crew-status: only a ship shows Testing"
}

test_declared_states_label_between_turns() {
  make_home declared
  worker_meta w1 scout
  declares 'paused [at=1700000000]: waiting for the upstream release'
  cards sync || fail "the pass should pass"
  assert_equals "Waiting" "$(card_of)" "a declared pause reads Waiting"
  declares 'blocked [at=1700000000]: the fixture repository is missing'
  cards sync || fail "the pass should pass"
  assert_equals "Waiting" "$(card_of)" "a blocker reads Waiting"
  turn_is running
  cards sync || fail "the pass should pass"
  assert_equals "" "$(card_of)" "a worker at work shows T3's own Working"
  turn_is settled
  mkdir -p "$HOME_DIR/data/w1" && printf 'report\n' > "$HOME_DIR/data/w1/report.md"
  declares 'done [at=1700000000]: report ready'
  cards sync || fail "the pass should pass"
  assert_equals "Ready" "$(card_of)" "finished work reads Ready"
  inbox_message >/dev/null || fail "could not write an inbox message"
  cards sync || fail "the pass should pass"
  assert_equals "" "$(card_of)" "a pending steer takes Ready off before the turn starts"
  rm -f "$HOME_DIR/state/w1.inbox/"*.msg
  declares 'failed [at=1700000000]: the reproduction does not hold'
  cards sync || fail "the pass should pass"
  assert_equals "Failed" "$(card_of)" "a failure reads Failed"
  declares 'working [at=1700000000]: reading the code'
  cards sync || fail "the pass should pass"
  assert_equals "" "$(card_of)" "a worker between turns with nothing to wait on carries no label"
  pass "fm-t3-crew-status: Waiting, Ready, and Failed follow the worker's state between turns"
}

test_older_t3_breaks_nothing() {
  local out rc
  teardown_home older
  t3_fake_set 'delete w.statusLabels'
  captain hold w1 --reason "pick the layout" >"$HOME_DIR/out" 2>&1 || fail "an older T3 must not fail the hold"
  assert_equals 0 "$(grep -c "could not" "$HOME_DIR/out")" "an older T3 is no failure to report"
  assert_equals 0 "$(updates)" "an older T3 is sent nothing it would refuse"
  cards sync || fail "an older T3 is no failed pass"

  t3_fake_set 'w.statusLabels = true'
  cards sync || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "the card catches up once T3 has the label"
  cards clear w1 || fail "clear should pass"

  t3_fake_set 'delete w.statusLabels'
  captain hold w1 --reason "pick the layout, still" >/dev/null || fail "a repeat hold should succeed"
  out=$(home_env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" w1 2>&1)
  rc=$?
  expect_code 0 "$rc" "an older T3 must not fail cleanup: $out"
  pass "fm-t3-crew-status: an older T3 breaks no hold or cleanup, and the card catches up after an update"
}

start_watcher() {
  fm_test_track_watcher_state "$HOME_DIR/state"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$HOME_DIR/fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
}

await_card_then_stop_watcher() {  # <label>
  local i=0
  while [ "$i" -lt 150 ] && [ "$(card_of)" != "$1" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

test_watcher_repairs_within_its_loop() {
  make_home watcher
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  t3_fake_set 'delete w.failTools'
  start_watcher
  await_card_then_stop_watcher "$WAITING"
  assert_equals "$WAITING" "$(card_of)" "the watcher applies the label a failed update missed"
  assert_present "$HOME_DIR/state/.t3-present-sync" "the watcher paces its repairs"
  pass "fm-watch.sh: repairs a missed label within its loop"
}

test_watcher_shows_an_active_run() {
  make_home watcher-run
  in_a_run
  run_is running
  start_watcher
  await_card_then_stop_watcher "$TESTING"
  assert_equals "$TESTING" "$(card_of)" "the watcher shows Testing with no event to start from"
  pass "fm-watch.sh: its pass finds an active run on a worker no event named"
}

test_watcher_brings_the_wait_back_when_the_run_ends() {
  local i=0
  make_home watcher-turn
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  turn_is running
  start_watcher
  await_card ""
  while [ "$i" -lt 100 ] && ! t3_fake_calls t3_thread_wait | grep -q run-1; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_equals "" "$(card_of)" "the watcher's pass drops the wait while the worker is mid-turn"
  t3_fake_calls t3_thread_wait | grep -q run-1 || fail "the watcher's T3 wait never watched the run"
  turn_is settled
  await_card_then_stop_watcher "$WAITING"
  assert_equals "$WAITING" "$(card_of)" "the run's end brings the wait back long before the minute pass"
  pass "fm-watch.sh: a T3 run ending with the hold open brings the wait back at once"
}

kept_review() {  # <state> [kind] [target] -> w1 is a finished scout kept in that review state
  worker_meta w1 "${2:-scout}" t3code "t3_review=$1" "t3_review_target=${3:-$THREAD}"
  declares "done [at=$(date +%s)]: report written"
}

test_kept_review_waits_for_the_captain() {
  local msg
  make_home kept-review
  kept_review waiting
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "a published kept review waits for the captain with no hold at all"
  turn_is running
  cards sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "the captain writing in the thread shows T3's Working"
  turn_is settled
  msg=$(inbox_message) || fail "could not write an inbox message"
  cards sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "an unhandled steering-inbox message reads as work"
  mkdir -p "${msg%/*}/handled" && mv "$msg" "${msg%/*}/handled/"
  cards sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the review waits again once the turn ends"

  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a real call on the review reads the same"
  answer w1 --release || fail "the release should succeed"
  assert_equals "$WAITING" "$(card_of)" "answering the call never closes the exploration"
  assert_grep 't3_review=waiting' "$HOME_DIR/state/w1.meta" "the answer leaves the review kept"
  [ -z "$(t3_fake_calls t3_thread_organize)" ] || fail "an answer must never archive or reorganize the kept thread"

  kept_review pending
  cards sync || fail "sync should pass"
  assert_equals Ready "$(card_of)" "a handoff not yet published is plain finished work"
  kept_review waiting ship
  cards sync || fail "sync should pass"
  assert_equals Ready "$(card_of)" "a ship never keeps its thread, even with a leftover review record"
  kept_review waiting scout mcp:another-thread
  cards sync || fail "sync should pass"
  assert_equals Ready "$(card_of)" "a review kept on another thread counts for nothing here"
  pass "fm-t3-crew-status: a published kept review reads Waiting for captain between turns, through answers, and only for its own scout thread"
}

test_kept_review_waits_for_the_captain
test_wait_shows_only_between_turns
test_inbox_delivery_drops_the_wait_at_once
test_concurrent_syncs_end_on_the_latest_read
test_watcher_brings_the_wait_back_when_the_run_ends
test_hold_labels_and_release_clears
test_answer_and_repeat_hold_are_clean
test_status_decision_alone_is_no_captain_wait
test_origin_holds_label_until_the_last_ends
test_failed_label_converges_on_the_next_sync
test_server_down_converges_after_restart
test_restart_that_loses_labels_is_republished
test_live_label_is_the_base
test_unreadable_backlog_leaves_the_card
test_gone_thread_or_worker_is_no_failure
test_only_t3_workers_are_labelled
test_clear_takes_the_label_off_while_the_hold_stays
test_teardown_clears_before_it_archives
test_testing_follows_the_run
test_a_pass_that_finds_another_running_is_owed
test_waiting_outranks_testing
test_a_scout_never_shows_testing
test_declared_states_label_between_turns
test_older_t3_breaks_nothing
test_watcher_repairs_within_its_loop
test_watcher_shows_an_active_run

echo "ok: fm-t3-crew-status"
