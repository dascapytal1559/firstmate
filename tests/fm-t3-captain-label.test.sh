#!/usr/bin/env bash
# tests/fm-t3-captain-label.test.sh - a live T3 worker's title follows its
# captain wait: bin/fm-t3-captain-label.sh driven through the real
# bin/fm-captain-hold.sh, bin/fm-teardown.sh, and bin/fm-watch.sh against the
# fake T3 server, with real tasks-axi backlogs.
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

TITLE='Print view for one recipe'
LABELLED="Waiting for captain · $TITLE"

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
  FM_T3_TITLE=$TITLE t3_fake_set 'w.threads = { "mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345": { threadId: "mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345", projectId: "proj-1",
    title: process.env.FM_T3_TITLE, status: "completed", activeRunId: null, archived: false, items: [], runs: [] } };'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  (cd "$HOME_DIR" && tasks-axi add w1 "$TITLE" --repo sample) >/dev/null \
    || fail "could not seed the backlog row"
  worker_meta w1
}

worker_meta() {  # <id> [kind] [backend]
  fm_write_meta "$HOME_DIR/state/$1.meta" "window=$1" "endpoint_task_id=$1" "kind=${2:-ship}" \
    "harness=claude" "backend=${3:-t3code}" "t3_thread_id=mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345" "t3_project_id=proj-1"
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

title_of() {  # [thread-id]
  node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(w.threads[process.argv[2]].title);
' "$T3_FAKE_WORLD" "${1:-mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345}"
}

renames() {
  t3_fake_calls t3_thread_update | grep -c '"action":"rename"' || true
}

test_hold_labels_and_release_restores() {
  make_home own-row
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  assert_equals "$LABELLED" "$(title_of)" "a hold on the worker's own task labels its title"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "the wait is recorded until the title is restored"
  answer w1 --release || fail "the release should succeed"
  assert_equals "$TITLE" "$(title_of)" "releasing the hold restores the title"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a restored title leaves no record"
  pass "fm-t3-captain-label: a hold on the worker's task labels the title, and the release restores it"
}

test_answer_and_repeat_hold_are_clean() {
  make_home closing-answer
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  captain hold w1 --reason "pick the layout, still" >/dev/null || fail "a repeated hold should succeed"
  assert_equals "$LABELLED" "$(title_of)" "a repeated hold never stacks the label"
  assert_equals 1 "$(renames)" "a repeated hold renames nothing"
  answer w1 || fail "the closing answer should succeed"
  assert_equals "$TITLE" "$(title_of)" "a closing answer restores the title"
  pass "fm-t3-captain-label: a repeated hold changes nothing, and a closing answer restores"
}

test_status_decision_alone_is_no_captain_wait() {
  make_home status-only
  printf 'needs-decision [key=layout] [at=1700000000]: which layout\n' > "$HOME_DIR/state/w1.status"
  label sync || fail "sync should pass"
  assert_equals 0 "$(renames)" "a worker's own needs-decision line labels nothing"
  assert_equals "$TITLE" "$(title_of)" "the title stays until firstmate holds the question for the captain"
  pass "fm-t3-captain-label: a needs-decision line alone is not a captain wait"
}

test_origin_holds_label_until_the_last_ends() {
  make_home origin
  worker_meta w1 scout
  captain hold w1-layout --title "Which layout" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "an origin hold should succeed"
  assert_equals "$LABELLED" "$(title_of)" "a hold whose origin is the worker labels that worker"
  captain hold w1-colour --title "Which colour" --reason "pick one" --origin w1 --repo sample >/dev/null \
    || fail "a second origin hold should succeed"
  answer w1-layout || fail "the first answer should succeed"
  assert_equals "$LABELLED" "$(title_of)" "the label stays while another hold on the worker is open"
  answer w1-colour || fail "the second answer should succeed"
  assert_equals "$TITLE" "$(title_of)" "the last hold ending restores the title"
  pass "fm-t3-captain-label: a question held with --origin labels the worker until its last hold ends"
}

test_failed_rename_converges_on_the_next_sync() {
  make_home failed-rename
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "pick the layout" >/dev/null 2>"$HOME_DIR/err" || fail "a failed rename must not fail the hold"
  assert_grep "could not set the title" "$HOME_DIR/err" "a failed rename is reported"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "a failed rename keeps the record"
  t3_fake_set 'delete w.failTools'
  label sync || fail "the retry should pass"
  assert_equals "$LABELLED" "$(title_of)" "the next pass applies the label"

  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  answer w1 --release || fail "a failed restore must not fail the release"
  assert_equals "$LABELLED" "$(title_of)" "the failed restore left the label"
  label sync >/dev/null && fail "sync reports a title it could not set"
  t3_fake_set 'delete w.failTools'
  label sync || fail "the retry should pass"
  assert_equals "$TITLE" "$(title_of)" "the next pass restores the title"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "the record goes once the title is proven"
  pass "fm-t3-captain-label: a failed rename never fails the hold or answer, and the next pass converges"
}

test_server_down_converges_after_restart() {
  make_home restart
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_stop
  answer w1 --release || fail "a release must not need T3"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "the restore waits for T3"
  t3_fake_restart "$TMP_ROOT/server"
  assert_equals "$LABELLED" "$(title_of)" "the label is durable across the restart"
  label sync || fail "the pass after the restart should succeed"
  assert_equals "$TITLE" "$(title_of)" "the pass after the restart restores the title"
  pass "fm-t3-captain-label: a restore that met a stopped T3 lands once T3 is back"
}

test_live_title_is_the_base() {
  make_home retitled
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.threads["mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345"].title = "A title set meanwhile"'
  label sync || fail "sync should pass"
  assert_equals "Waiting for captain · A title set meanwhile" "$(title_of)" "the label returns on a title changed under it"
  answer w1 --release || fail "the release should succeed"
  assert_equals "A title set meanwhile" "$(title_of)" "the restore keeps the live title, not a stored copy"
  pass "fm-t3-captain-label: the base title is always the live one"
}

test_unreadable_hold_leaves_the_title() {
  make_home unreadable
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.threads["mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345"].title = "Unlabelled"'
  printf '#!/usr/bin/env bash\nexit 7\n' > "$HOME_DIR/fakebin/tasks-axi"
  chmod +x "$HOME_DIR/fakebin/tasks-axi"
  label sync || fail "sync should pass"
  rm -f "$HOME_DIR/fakebin/tasks-axi"
  assert_equals "Unlabelled" "$(title_of)" "a hold that cannot be read changes no title"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1/w1" "a hold that cannot be read keeps its record"
  pass "fm-t3-captain-label: a hold that cannot be read leaves the title and the record alone"
}

test_gone_thread_or_worker_drops_the_record() {
  make_home gone
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.threads["mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345"].archived = true'
  label sync || fail "an archived thread is no failure"
  assert_equals "$TITLE" "$(title_of)" "an archived thread loses the label"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "an archived thread has no card to label"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "repeat hold should succeed"
  t3_fake_set 'delete w.threads["mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345"]'
  label sync || fail "a deleted thread is no failure"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "a deleted thread has no card to label"
  t3_fake_set 'w.threads["mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345"] = { threadId: "mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345", title: "x", status: "completed", items: [], runs: [] }'
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
  assert_equals "" "$(cat "$T3_FAKE_LOG")" "another backend makes no T3 call"
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

test_clear_restores_while_the_hold_stays() {
  make_home clear
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  label clear w1 >/dev/null && fail "clear reports a title it could not restore"
  assert_present "$HOME_DIR/state/t3-captain-wait/w1" "a failed restore keeps the record for a rerun"
  t3_fake_set 'delete w.failTools'
  label clear w1 || fail "clear should pass"
  assert_equals "$TITLE" "$(title_of)" "clear restores the title with the hold still open"
  captain open w1 || fail "clear must leave the captain's hold open"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "clear drops the record"
  pass "fm-t3-captain-label: clear restores the title and leaves the hold open"
}

test_teardown_restores_before_it_archives() {
  local proj wt out rc fb order
  make_home teardown
  proj="$HOME_DIR/project"; wt="$HOME_DIR/wt"
  fm_git_worktree "$proj" "$wt" "fm/w1"
  fm_write_meta "$HOME_DIR/state/w1.meta" "window=fm-w1" "endpoint_task_id=w1" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=t3code" "t3_thread_id=mcp:2c8f0d4e-7b1a-4f3c-9e2d-abcdef012345" \
    "t3_project_id=proj-1" "decisions_reviewed=1" "decision_keys=" "spawn_gen=fixture-w1"
  mkdir -p "$HOME_DIR/data/w1"
  printf 'report\n' > "$HOME_DIR/data/w1/report.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  captain hold w1 --reason "pick the layout" >/dev/null || fail "hold should succeed"
  : > "$T3_FAKE_LOG"
  fb="$HOME_DIR/fakebin"
  printf '#!/usr/bin/env bash\n[ "${1:-}" != get ] || printf "%%s\\n" "%s"\nexit 0\n' "$wt" > "$fb/treehouse"
  chmod +x "$fb/treehouse"
  out=$(home_env FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" w1 2>&1)
  rc=$?
  expect_code 0 "$rc" "teardown should succeed: $out"
  order=$(t3_fake_mutations)
  assert_equals "t3_thread_update t3_thread_organize" "$order" "the title is restored before the thread is archived"
  assert_equals "$TITLE" "$(title_of)" "the archived thread keeps its own title"
  assert_absent "$HOME_DIR/state/t3-captain-wait" "teardown leaves no record"
  pass "fm-teardown.sh: restores the title before it archives a worker with an open captain wait"
}

test_watcher_repairs_within_its_loop() {
  local i=0
  make_home watcher
  t3_fake_set 'w.failTools = { t3_thread_update: { code: "orchestration_error", message: "no" } }'
  captain hold w1 --reason "pick the layout" >/dev/null 2>&1 || fail "hold should succeed"
  t3_fake_set 'delete w.failTools'
  fm_test_track_watcher_state "$HOME_DIR/state"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$HOME_DIR/fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
  while [ "$i" -lt 150 ] && [ "$(title_of)" != "$LABELLED" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  assert_equals "$LABELLED" "$(title_of)" "the watcher applies the label a failed rename missed"
  assert_present "$HOME_DIR/state/.t3-captain-wait-sync" "the watcher paces its repairs"
  pass "fm-watch.sh: repairs a missed title while a record exists"
}

test_hold_labels_and_release_restores
test_answer_and_repeat_hold_are_clean
test_status_decision_alone_is_no_captain_wait
test_origin_holds_label_until_the_last_ends
test_failed_rename_converges_on_the_next_sync
test_server_down_converges_after_restart
test_live_title_is_the_base
test_unreadable_hold_leaves_the_title
test_gone_thread_or_worker_drops_the_record
test_only_t3_workers_are_labelled
test_clear_restores_while_the_hold_stays
test_teardown_restores_before_it_archives
test_watcher_repairs_within_its_loop

echo "ok: fm-t3-captain-label"
