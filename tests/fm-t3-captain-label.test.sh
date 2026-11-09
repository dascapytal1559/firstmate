#!/usr/bin/env bash
# tests/fm-t3-captain-label.test.sh - a live T3 worker's card status follows its
# captain wait and its no-mistakes run: bin/fm-t3-captain-label.sh driven through
# the real bin/fm-captain-hold.sh, bin/fm-crew-state.sh, bin/fm-teardown.sh, and
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

LABEL_SCRIPT="$ROOT/bin/fm-t3-captain-label.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-captain-label)
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
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=$id" "endpoint_task_id=$id" "kind=$kind" \
    "harness=claude" "backend=$backend" "t3_thread_id=$THREAD" "t3_project_id=proj-1" "$@"
}

# in_a_run [kind] -> a worker with its own branch and a no-mistakes that reports
# whatever run_is writes; `no-mistakes axi status` answers nothing until then.
in_a_run() {  # [kind]
  local fb="$HOME_DIR/fakebin" wt="$HOME_DIR/wt"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/w1
  worker_meta w1 "${1:-ship}" t3code "worktree=$wt"
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
  head=$(git -C "$HOME_DIR/wt" rev-parse HEAD)
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

label() {  # <label-args...>
  home_env "$LABEL_SCRIPT" "$@"
}

answer() {  # <task-id> [--release]
  local id=$1
  shift
  printf 'go ahead\n' > "$HOME_DIR/decision"
  captain answer "$id" --decision-file "$HOME_DIR/decision" "$@" >/dev/null 2>&1
}

thread_field() {  # <title|statusLabel>
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(w.threads[process.argv[2]][process.argv[3]] ?? "");
' "$T3_FAKE_WORLD" "$THREAD" "$1"
}

card_of() {
  thread_field statusLabel
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
  label sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "a worker mid-turn drops the wait so T3 shows Working"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "the record stays while the hold is open"
  captain open w1 || fail "the label never touches the hold"
  turn_is settled
  label sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the turn ending with the hold open brings the wait back"

  msg=$(inbox_message) || fail "could not write an inbox message"
  label sync || fail "sync should pass"
  assert_equals "" "$(card_of)" "an unhandled steering-inbox message drops the wait before T3 reports the turn"
  mkdir -p "${msg%/*}/handled" && mv "$msg" "${msg%/*}/handled/"
  label sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "once the message is handled and the turn is over, the wait is back"

  turn_is failed
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  label sync || fail "sync should pass"
  assert_equals "Unchanged" "$(card_of)" "a turn that cannot be read changes no card"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "a turn that cannot be read keeps the record"

  turn_is settled
  answer w1 --release || fail "the release should succeed"
  assert_equals "" "$(card_of)" "the release still clears the card"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "and leaves no record"
  pass "fm-t3-captain-label: the wait shows only between turns and returns when a turn ends with the hold open"
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
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "and keeps the record for the wait's return"
  pass "fm-task-inbox-lib: a doorbell delivered to a T3 worker drops its card's wait at once"
}

test_concurrent_syncs_end_on_the_latest_read() {
  local pids='' i
  make_home concurrent
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  turn_is running
  for i in 1 2 3 4; do
    label sync >/dev/null 2>&1 &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086  # one pid per word
  wait $pids
  assert_equals "" "$(card_of)" "racing passes all read the worker mid-turn"
  assert_absent "$HOME_DIR/state/.t3-captain-wait.lock" "the last pass lets go of the lock"
  assert_absent "$HOME_DIR/state/.t3-captain-wait.again" "no pass is left owed"
  ln -s 999999 "$HOME_DIR/state/.t3-captain-wait.lock"
  turn_is settled
  label sync || fail "a lock left by a killed pass is taken over"
  assert_equals "$WAITING" "$(card_of)" "the pass after a killed one still runs"
  pass "fm-t3-captain-label: passes run one at a time, and a killed pass's lock is taken over"
}

test_hold_labels_and_release_clears() {
  make_home own-row
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold on the worker's own task labels its card"
  assert_equals "$TITLE" "$(thread_field title)" "the title stays plain"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "the wait is recorded until the card is clear"
  answer w1 --release || fail "the release should succeed"
  assert_equals "" "$(card_of)" "releasing the hold clears the card"
  assert_equals "$TITLE" "$(thread_field title)" "the title is never touched"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a clear card leaves no record"
  assert_equals 0 "$(t3_fake_calls t3_thread_update | grep -c '"action":"rename"')" "nothing renames the thread"
  pass "fm-t3-captain-label: a hold on the worker's task labels the card, and the release clears it"
}

test_answer_and_repeat_hold_are_clean() {
  make_home closing-answer
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  captain hold w1 --reason "pick the layout, still" >/dev/null || fail "a repeated hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a repeated hold keeps the label"
  assert_equals 1 "$(updates)" "a repeated hold updates nothing"
  answer w1 || fail "the closing answer should succeed"
  assert_equals "" "$(card_of)" "a closing answer clears the card"
  pass "fm-t3-captain-label: a repeated hold changes nothing, and a closing answer clears"
}

test_status_decision_alone_is_no_captain_wait() {
  make_home status-only
  printf 'needs-decision [key=layout] [at=1700000000]: which layout\n' > "$HOME_DIR/state/w1.status"
  label sync || fail "sync should pass"
  assert_equals 0 "$(updates)" "a worker's own needs-decision line labels nothing"
  assert_equals "" "$(card_of)" "the card stays clear until firstmate holds the question for the captain"
  pass "fm-t3-captain-label: a needs-decision line alone is not a captain wait"
}

test_origin_holds_label_until_the_last_ends() {
  make_home origin
  worker_meta w1 scout
  captain hold w1-layout --title "Which layout" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "an origin hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold whose origin is the worker labels that worker"
  captain hold w1-colour --title "Which colour" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "a second origin hold should succeed"
  answer w1-layout || fail "the first answer should succeed"
  assert_equals "$WAITING" "$(card_of)" "the label stays while another hold on the worker is open"
  answer w1-colour || fail "the second answer should succeed"
  assert_equals "" "$(card_of)" "the last hold ending clears the card"
  pass "fm-t3-captain-label: a question held with --origin labels the worker until its last hold ends"
}

test_failed_label_converges_on_the_next_sync() {
  make_home failed-label
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "pick the layout" >/dev/null 2>"$HOME_DIR/err" || fail "a failed label must not fail the hold"
  assert_grep "could not set the status" "$HOME_DIR/err" "a failed label is reported"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "a failed label keeps the record"
  t3_fake_set 'delete w.failTools'
  label sync || fail "the retry should pass"
  assert_equals "$WAITING" "$(card_of)" "the next pass applies the label"

  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  answer w1 --release || fail "a failed clear must not fail the release"
  assert_equals "$WAITING" "$(card_of)" "the failed clear left the label"
  label sync >/dev/null && fail "sync reports a label it could not set"
  t3_fake_set 'delete w.failTools'
  label sync || fail "the retry should pass"
  assert_equals "" "$(card_of)" "the next pass clears the card"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "the record goes once the card is proven"
  pass "fm-t3-captain-label: a failed label never fails the hold or answer, and the next pass converges"
}

test_server_down_converges_after_restart() {
  make_home restart
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_stop
  answer w1 --release || fail "a release must not need T3"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "the clear waits for T3"
  t3_fake_restart "$TMP_ROOT/server"
  assert_equals "$WAITING" "$(card_of)" "the label is durable across the restart"
  label sync || fail "the pass after the restart should succeed"
  assert_equals "" "$(card_of)" "the pass after the restart clears the card"
  pass "fm-t3-captain-label: a clear that met a stopped T3 lands once T3 is back"
}

test_live_label_is_the_base() {
  make_home relabelled
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_ID].statusLabel'
  label sync || fail "sync should pass"
  assert_equals "$WAITING" "$(card_of)" "the label returns on a card that lost it"
  pass "fm-t3-captain-label: a sync compares against the live card"
}

test_unreadable_hold_leaves_the_card() {
  make_home unreadable
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  printf '#!/usr/bin/env bash\nexit 7\n' > "$HOME_DIR/fakebin/tasks-axi"
  chmod +x "$HOME_DIR/fakebin/tasks-axi"
  label sync || fail "sync should pass"
  rm -f "$HOME_DIR/fakebin/tasks-axi"
  assert_equals "Unchanged" "$(card_of)" "a hold that cannot be read changes no card"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "a hold that cannot be read keeps its record"
  pass "fm-t3-captain-label: a hold that cannot be read leaves the card and the record alone"
}

test_gone_thread_or_worker_drops_the_record() {
  make_home gone
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].archived = true'
  label sync || fail "an archived thread is no failure"
  assert_equals "" "$(card_of)" "an archived thread loses the label"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "an archived thread has no card to label"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "repeat hold should succeed"
  FM_T3_ID=$THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_ID]'
  label sync || fail "a deleted thread is no failure"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a deleted thread has no card to label"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID] = { threadId: process.env.FM_T3_ID, title: "x", status: "completed", items: [], runs: [] }'
  captain hold w1 --reason "pick the layout" >/dev/null || fail "repeat hold should succeed"
  rm -f "$HOME_DIR/state/w1.meta"
  label sync || fail "a worker with no record is no failure"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a hold with no running worker has no card"
  pass "fm-t3-captain-label: a gone thread or worker drops the record and leaves the hold alone"
}

test_only_t3_workers_are_labelled() {
  make_home other-backend
  worker_meta w1 ship tmux
  : > "$T3_FAKE_LOG"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "another backend records nothing"
  # The hold's decision-thread sync (bin/fm-t3-needs-me.sh) may still open a
  # session; no thread of a worker on another backend is read or changed.
  assert_equals "" "$(t3_fake_calls t3_thread_read)$(t3_fake_mutations)" "another backend makes no T3 thread call"
  make_home secondmate
  worker_meta w1 secondmate
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a secondmate's thread is no task card"
  make_home no-token
  rm -f "$HOME_DIR/config/t3code-token"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a home without T3 records nothing"
  pass "fm-t3-captain-label: only a recorded T3 ship or scout is labelled"
}

test_clear_takes_the_label_off_while_the_hold_stays() {
  make_home clear
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  label clear w1 >/dev/null && fail "clear reports a label it could not take off"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "a failed clear keeps the record for a rerun"
  t3_fake_set 'delete w.failTools'
  label clear w1 || fail "clear should pass"
  assert_equals "" "$(card_of)" "clear takes the label off with the hold still open"
  captain open w1 || fail "clear must leave the captain's hold open"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "clear drops the record"
  pass "fm-t3-captain-label: clear takes the label off and leaves the hold open"
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
  : > "$T3_FAKE_LOG"
  out=$(home_env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" w1 2>&1)
  rc=$?
  expect_code 0 "$rc" "teardown should succeed: $out"
  assert_equals "t3_thread_update t3_thread_organize" "$(t3_fake_mutations)" "the label comes off before the thread is archived"
  assert_equals "" "$(card_of)" "the archived thread keeps no label"
  assert_equals "$TITLE" "$(thread_field title)" "the archived thread keeps its own title"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "teardown leaves no record"
  pass "fm-teardown.sh: clears the label before it archives a worker with an open captain wait"
}

test_testing_follows_the_run() {
  make_home testing
  in_a_run
  label sync --runs || fail "a pass with no run should pass"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a worker with no run has no record"
  assert_equals 0 "$(updates)" "a worker with no run costs no update"

  run_is running
  label sync || fail "a pass without --runs should pass"
  assert_equals "" "$(card_of)" "a pass without --runs finds no new run"
  label sync --runs || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "an active run shows Testing"
  assert_equals "$TITLE" "$(thread_field title)" "Testing leaves the title plain"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "the run is recorded until the card is clear"

  run_is parked
  label sync --runs || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "a run parked at a gate is still active"
  assert_equals 1 "$(updates)" "a repeat updates nothing"

  run_is unreadable
  home_env "$ROOT/bin/fm-crew-state.sh" w1 > "$HOME_DIR/crew-state"
  assert_grep "state: unknown · source: run-step" "$HOME_DIR/crew-state" "this case must be a run that cannot be read"
  FM_T3_ID=$THREAD t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Unchanged"'
  label sync --runs || fail "the pass should pass"
  assert_equals "Unchanged" "$(card_of)" "a run that cannot be read changes no card"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "a run that cannot be read keeps its record"

  run_is ended
  label sync --runs || fail "the pass should pass"
  assert_equals "" "$(card_of)" "the end of the run clears the card"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a clear card leaves no record"
  pass "fm-t3-captain-label: Testing shows while the run is active and clears when it ends"
}

test_runs_request_rides_on_the_running_pass() {
  local holder
  make_home runs-coalesced
  in_a_run
  run_is running
  sleep 30 &
  holder=$!
  ln -s "$holder" "$HOME_DIR/state/.t3-captain-wait.lock"
  label sync --runs || fail "a pass that finds another running should pass"
  assert_equals "" "$(card_of)" "it leaves the work to the running pass"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  label sync || fail "the next pass should pass"
  assert_equals "$TESTING" "$(card_of)" "the owed pass still looks for runs"
  assert_absent "$HOME_DIR/state/.t3-captain-wait.lock" "the pass lets go of the lock"
  run_is ended
  label sync || fail "a later plain pass should pass"
  assert_equals "" "$(card_of)" "the end of the run clears the card"
  run_is running
  label sync || fail "a later plain pass should pass"
  assert_equals "" "$(card_of)" "the carried request was used up, so a plain pass finds no new run"
  pass "fm-t3-captain-label: a --runs request that finds another pass running is carried by the next pass"
}

test_waiting_outranks_testing() {
  make_home outranks
  in_a_run
  run_is running
  label sync --runs || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "the run shows first"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$WAITING" "$(card_of)" "a hold outranks the run at once"
  label sync --runs || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "a later pass keeps the wait on top"
  turn_is running
  label sync || fail "the pass should pass"
  assert_equals "$TESTING" "$(card_of)" "a worker mid-turn through the wait shows its active run"
  turn_is settled
  label sync || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "the turn's end puts the wait back on top"
  answer w1 --release || fail "the release should succeed"
  assert_equals "$TESTING" "$(card_of)" "the end of the wait falls back to the run"
  run_is ended
  label sync --runs || fail "the pass should pass"
  assert_equals "" "$(card_of)" "then the end of the run clears the card"
  pass "fm-t3-captain-label: Waiting for captain outranks Testing, and Testing returns when the wait ends"
}

test_a_scout_never_shows_testing() {
  make_home scout
  in_a_run scout
  run_is running
  label sync --runs || fail "the pass should pass"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a scout's run is not read"
  assert_equals 0 "$(updates)" "a scout's card is left alone"
  pass "fm-t3-captain-label: only a ship shows Testing"
}

test_older_t3_breaks_nothing() {
  local out rc
  teardown_home older
  t3_fake_set 'delete w.statusLabels'
  captain hold w1 --reason "pick the layout" >"$HOME_DIR/out" 2>&1 || fail "an older T3 must not fail the hold"
  assert_equals 0 "$(grep -c "could not" "$HOME_DIR/out")" "an older T3 is no failure to report"
  assert_equals 0 "$(updates)" "an older T3 is sent nothing it would refuse"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "the record stays for a T3 that gains the label"
  label sync || fail "an older T3 is no failed pass"

  t3_fake_set 'w.statusLabels = true'
  label sync || fail "the pass should pass"
  assert_equals "$WAITING" "$(card_of)" "the card catches up once T3 has the label"
  label clear w1 || fail "clear should pass"

  t3_fake_set 'delete w.statusLabels'
  captain hold w1 --reason "pick the layout, still" >/dev/null || fail "a repeat hold should succeed"
  out=$(home_env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" w1 2>&1)
  rc=$?
  expect_code 0 "$rc" "an older T3 must not fail cleanup: $out"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "cleanup leaves no record on an older T3"
  pass "fm-t3-captain-label: an older T3 breaks no hold or cleanup, and the card catches up after an update"
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
  assert_present "$HOME_DIR/state/.t3-captain-wait-sync" "the watcher paces its repairs"
  pass "fm-watch.sh: repairs a missed label while a record exists"
}

test_watcher_finds_a_run_with_no_record() {
  make_home watcher-run
  in_a_run
  run_is running
  start_watcher
  await_card_then_stop_watcher "$TESTING"
  assert_equals "$TESTING" "$(card_of)" "the watcher shows Testing with no record to start from"
  pass "fm-watch.sh: the same pass finds an active run on a worker with no record"
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
test_live_label_is_the_base
test_unreadable_hold_leaves_the_card
test_gone_thread_or_worker_drops_the_record
test_only_t3_workers_are_labelled
test_clear_takes_the_label_off_while_the_hold_stays
test_teardown_clears_before_it_archives
test_testing_follows_the_run
test_runs_request_rides_on_the_running_pass
test_waiting_outranks_testing
test_a_scout_never_shows_testing
test_older_t3_breaks_nothing
test_watcher_repairs_within_its_loop
test_watcher_finds_a_run_with_no_record

echo "ok: fm-t3-captain-label"
