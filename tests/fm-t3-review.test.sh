#!/usr/bin/env bash
# tests/fm-t3-review.test.sh - bin/fm-t3-review.sh, which keeps a finished T3
# scout's thread for the captain: firstmate's handoff is recorded locally and
# nothing is posted into the thread, which gets the tag and automatic settling
# off, retried rather than given up; the captain's close is noticed even when
# the thread is gone, and closes the open calls the card carried as not
# pursued. Driven
# against the fake T3 server and the real bin/fm-captain-hold.sh, with no live
# service.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

REVIEW="$ROOT/bin/fm-t3-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-review)
t3_fake_start "$TMP_ROOT/server"
trap 't3_fake_stop; fm_test_cleanup' EXIT

THREAD='mcp:7a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d'
TAG='waiting for captain'

# make_home <name> [world-json]: a home with the T3 credential, a finished
# scout `s1` on $THREAD with its report and a passed captain-call gate, and
# its summary and body files.
make_home() {
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/s1" "$HOME_DIR/config" "$HOME_DIR/copy"
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n- [ ] s1 - The scout (repo: sample) (kind: scout) (since 2026-11-01)\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  t3_fake_case "$HOME_DIR/world" "${2:-}"
  FM_T3_WT="$HOME_DIR/copy" t3_fake_set 'w.reviews = w.reviews ?? true; w.threads = { "mcp:7a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d": { threadId: "mcp:7a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d",
    projectId: "proj-1", title: "scout", status: "completed", activeRunId: null, archived: false, worktreePath: process.env.FM_T3_WT, items: [], runs: [] } };'
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  fm_write_meta "$HOME_DIR/state/s1.meta" window=fm-s1 endpoint_task_id=s1 kind=scout harness=claude backend=t3code \
    "t3_thread_id=$THREAD" t3_project_id=proj-1 "worktree=$HOME_DIR/copy" spawn_gen=gen-1 decisions_reviewed=1
  printf '# Report\nFindings.\n' > "$HOME_DIR/data/s1/report.md"
  printf 'The short answer.\n' > "$HOME_DIR/summary.md"
  printf 'The whole reasoning.\n\nWith tradeoffs.\n' > "$HOME_DIR/body.md"
}

review() {  # <args...> -> stdout+stderr in OUT, exit in RC
  OUT=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$REVIEW" "$@" 2>&1)
  RC=$?
}

retain() {
  review retain s1 --summary-file "$HOME_DIR/summary.md" --body-file "$HOME_DIR/body.md"
}

meta() {  # <key>
  sed -n "s/^$1=//p" "$HOME_DIR/state/s1.meta" | tail -n 1
}

notes() {
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String((w.threads[process.argv[2]].items || []).filter((i) => i.note).length))' "$T3_FAKE_WORLD" "$THREAD"
}

thread_set() {  # <js on t>
  FM_T3_ID=$THREAD t3_fake_set "const t = w.threads[process.env.FM_T3_ID]; $1"
}

test_retain_keeps_the_thread_and_posts_no_note() {
  local report
  make_home publish
  retain
  expect_code 0 "$RC" "retain should keep and publish: $OUT"
  assert_equals waiting "$(meta t3_review)" "a proven publication waits for the captain"
  assert_equals "$THREAD" "$(meta t3_review_target)" "the review is bound to its own thread"
  assert_equals 1 "$(meta t3_review_revision)" "the first handoff is revision 1"
  assert_contains "$(cd "$HOME_DIR" && tasks-axi show s1 --full 2>/dev/null)" "Captain hold flavor: read" \
    "the backlog holds the report To read"
  assert_equals "read" "$(env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input \
    | jq -r '.backlog.records[] | select(.id == "s1") | .hold_flavor')" "as a To read item, not a decision"
  assert_equals 0 "$(notes)" "no Firstmate note is posted into the thread"
  [ -z "$(t3_fake_calls t3_thread_note)" ] || fail "retain never calls the note tool"
  report="$(cd "$HOME_DIR/data/s1" && pwd -P)/report.md"
  assert_equals "**Firstmate summary**

The short answer.

**Full explanation**

The whole reasoning.

With tradeoffs.

[Full report (Markdown)]($report)" "$(cat "$HOME_DIR/data/s1/handoff-r1.md")" \
    "firstmate's handoff record holds the summary, then the fuller body, then the report link, in that order"
  node -e 'const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).threads[process.argv[2]];
if (JSON.stringify(t.tags) !== JSON.stringify([process.argv[3]])) { console.error("tags " + JSON.stringify(t.tags)); process.exit(1); }
if (t.autoSettleDisabled !== true || t.archived || (t.runs || []).length) { console.error("thread " + JSON.stringify(t)); process.exit(1); }' "$T3_FAKE_WORLD" "$THREAD" "$TAG" \
    || fail "the kept thread carries the exact tag, automatic settling off, stays unarchived, and runs nothing"

  retain
  expect_code 0 "$RC" "a repeat of the same handoff is harmless: $OUT"
  assert_equals 1 "$(meta t3_review_revision)" "a repeat keeps the revision"
  printf 'A revised answer.\n' > "$HOME_DIR/summary.md"
  retain
  expect_code 0 "$RC" "a revised handoff publishes: $OUT"
  assert_equals '2 waiting' "$(meta t3_review_revision) $(meta t3_review)" "a revision is recorded and the thread is kept again"
  assert_present "$HOME_DIR/data/s1/handoff-r1.md" "the earlier handoff stays as it was"
  assert_present "$HOME_DIR/data/s1/handoff-r2.md" "the revised handoff is recorded beside it"
  printf '# Report\nRevised findings.\n' > "$HOME_DIR/data/s1/report.md"
  retain
  assert_equals '3 0' "$(meta t3_review_revision) $(notes)" "a revised report is a new revision even with the same words, and still posts nothing"
  pass "fm-t3-review retain: the handoff is recorded for firstmate with summary, body and report link, and the thread gets the exact tag and automatic settling off but no note"
}

test_retain_refuses_what_it_must_not_keep() {
  make_home refusals
  sed -i.bak 's/^kind=scout$/kind=ship/' "$HOME_DIR/state/s1.meta"
  retain
  expect_code 4 "$RC" "a ship is never kept"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$HOME_DIR/state/s1.meta"
  sed -i.bak 's/^decisions_reviewed=1$//' "$HOME_DIR/state/s1.meta"
  retain
  expect_code 4 "$RC" "a scout that has not passed the captain-call gate is not kept"
  assert_contains "$OUT" "completion gate" "the refusal names the gate"
  printf 'decisions_reviewed=1\n' >> "$HOME_DIR/state/s1.meta"
  rm -f "$HOME_DIR/data/s1/report.md"
  retain
  expect_code 4 "$RC" "a scout without its report is not kept"
  assert_equals '' "$(meta t3_review)" "no refusal writes a record"
  assert_equals '' "$(t3_fake_mutations)" "no refusal touches T3"

  make_home upstream '{"reviews":false}'
  retain
  expect_code 4 "$RC" "a T3 that cannot keep threads is refused"
  assert_contains "$OUT" "clean it up as usual" "the refusal says the ordinary cleanup applies"
  assert_equals '' "$(meta t3_review)" "an old T3 leaves no record behind"
  pass "fm-t3-review retain: ships, ungated or reportless scouts, and an old T3 keep today's cleanup with nothing written"
}

test_failures_retry_and_close_wins() {
  make_home retry
  thread_set 't.status = "running"; t.activeRunId = "run-1"; t.runs = [{ runId: "run-1", ordinal: 1, status: "running" }];'
  retain
  expect_code 75 "$RC" "a busy thread defers publication: $OUT"
  assert_equals pending "$(meta t3_review)" "the handoff is recorded before anything is published"
  assert_present "$HOME_DIR/data/s1/handoff-r1.md" "the handoff is persisted"
  assert_equals '' "$(t3_fake_calls t3_thread_organize)" "nothing changes on the thread while the worker runs"
  thread_set 't.status = "completed"; t.activeRunId = null; t.runs[0].status = "completed";'
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "orchestration_error", message: "boom" } }'
  review publish s1
  expect_code 1 "$RC" "a failed publication is a failure"
  assert_equals pending "$(meta t3_review)" "a failed publication stays kept for retry, never archived"
  ! t3_fake_calls t3_thread_organize | grep -qF archive || fail "a failure never archives the thread"
  t3_fake_set 'delete w.failTools'
  review reconcile
  expect_code 0 "$RC" "the watcher's pass retries: $OUT"
  assert_equals '0 waiting' "$(notes) $(meta t3_review)" "the retry keeps the thread, still with no note"

  make_home race '{"archiveOnTag":true}'
  retain
  expect_code 0 "$RC" "a close racing publication is no failure: $OUT"
  assert_equals closed "$(meta t3_review)" "the captain's close wins over publication"
  assert_present "$HOME_DIR/state/t3-review/s1.closed" "his close leaves one notice for firstmate"

  make_home unreachable
  t3_fake_credential "$HOME_DIR/config/t3code-token" env-fake-1 '' 600 http://127.0.0.1:9
  retain
  [ "$RC" -ne 0 ] || fail "an unreachable T3 cannot publish"
  assert_equals pending "$(meta t3_review)" "an unreachable T3 still records the handoff for retry"
  review check-close s1
  expect_code 3 "$RC" "an unreachable T3 is never taken for a close"
  assert_equals pending "$(meta t3_review)" "an unreachable T3 preserves the record"
  pass "fm-t3-review: a busy or failed publication stays kept and is retried once, his close wins a race, and an unreachable T3 preserves everything"
}

test_reconcile_notices_his_close_and_reopen() {
  make_home close
  retain
  assert_equals waiting "$(meta t3_review)" "published first: $OUT"
  review reconcile
  assert_equals waiting "$(meta t3_review)" "an open thread stays kept"
  assert_absent "$HOME_DIR/state/t3-review/s1.closed" "an open thread leaves no notice"
  review check-close s1
  expect_code 1 "$RC" "cleanup is refused while the thread is open"
  thread_set 't.archived = true;'
  review reconcile
  assert_equals closed "$(meta t3_review)" "his archive is recorded as his close"
  assert_contains "$(cat "$HOME_DIR/state/t3-review/s1.closed")" "bin/fm-teardown.sh s1" "the notice asks for the guarded cleanup"
  thread_set 't.archived = false;'
  review reconcile
  assert_equals pending "$(meta t3_review)" "a thread he reopens is kept again, not revived by firstmate"
  assert_absent "$HOME_DIR/state/t3-review/s1.closed" "a reopen withdraws the close notice"
  review reconcile
  assert_equals waiting "$(meta t3_review)" "the next pass marks the reopened thread kept again"
  FM_T3_ID=$THREAD t3_fake_set 'delete w.threads[process.env.FM_T3_ID]'
  review reconcile
  assert_equals closed "$(meta t3_review)" "a deleted thread is his close even with the endpoint gone"
  review check-close s1
  expect_code 0 "$RC" "cleanup may run once he closed it"
  [ -z "$(t3_fake_calls t3_thread_send)" ] || fail "the review never starts a worker turn"
  ! t3_fake_calls t3_thread_organize | grep -qF -e '"archive"' -e unarchive || fail "firstmate never archives or reopens the captain's thread"
  pass "fm-t3-review reconcile: his archive or delete is recorded once with a notice, a reopen is kept again, and nothing is revived or steered"
}

# A pending record that cannot be published (T3 refuses to mark its thread)
# fails only itself: the same pass still notices his close of a review listed
# after it.
test_reconcile_survives_a_record_it_cannot_publish() {
  local other='mcp:00000000-0000-4000-8000-0000000000a0'
  make_home survive
  retain
  assert_equals waiting "$(meta t3_review)" "published first: $OUT"
  FM_T3_ID=$other t3_fake_set 'w.threads[process.env.FM_T3_ID] = { threadId: process.env.FM_T3_ID, projectId: "proj-1", title: "a0",
    status: "completed", activeRunId: null, archived: false, worktreePath: null, items: [], runs: [] };
    w.failTools = { t3_thread_organize: { code: "orchestration_error", message: "boom" } };'
  fm_write_meta "$HOME_DIR/state/a0.meta" window=fm-a0 endpoint_task_id=a0 kind=scout harness=claude backend=t3code \
    "t3_thread_id=$other" "t3_review_target=$other" t3_review=pending t3_review_revision=1 t3_review_request=fm-review-a0
  thread_set 't.archived = true;'
  review reconcile
  assert_equals closed "$(meta t3_review)" "a review after one that cannot publish is still reconciled"
  assert_present "$HOME_DIR/state/t3-review/s1.closed" "and leaves its close notice"
  assert_equals pending "$(sed -n 's/^t3_review=//p' "$HOME_DIR/state/a0.meta")" "the unpublishable record stays kept for retry"
  review publish a0
  expect_code 1 "$RC" "publishing it directly still fails on its own: $OUT"
  assert_contains "$OUT" "retried" "the failure says it is retried"
  pass "fm-t3-review reconcile: one record that cannot publish never stops the pass for the others"
}

# park_home <name>: a home with a published review s1 and four captain calls:
# c1 held with --origin s1, c2 inventoried by s1's completion gate with no
# origin, c3 another task's call, and c4 held from s1 and already answered.
park_home() {
  make_home "$1"
  local fakebin
  fakebin=$(fm_fakebin "$HOME_DIR")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  captain hold c1 --title "Pick the layout" --reason "Layout A or B?" --origin s1 >/dev/null 2>&1 || fail "hold c1"
  captain hold c2 --title "Buy the camera" --reason "Buy it?" >/dev/null 2>&1 || fail "hold c2"
  captain hold c3 --title "Elsewhere" --reason "Unrelated call" >/dev/null 2>&1 || fail "hold c3"
  captain hold c4 --title "Earlier call" --reason "Answered already" --origin s1 >/dev/null 2>&1 || fail "hold c4"
  printf 'Go with A.\n' > "$HOME_DIR/answer.txt"
  captain answer c4 --decision-file "$HOME_DIR/answer.txt" >/dev/null 2>&1 || fail "answer c4"
  printf 'decision_keys=c2\n' >> "$HOME_DIR/state/s1.meta"
  retain
  assert_equals waiting "$(meta t3_review)" "published first: $OUT"
}

captain() {  # <hold-args...>
  env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

row_state() {  # <task-id> -> open (held for the captain and not done) or closed
  if captain open "$1" >/dev/null 2>&1; then echo open; else echo closed; fi
}

assert_not_pursued() {  # <task-id> <label>
  local body today
  today=$(date -u +%Y-%m-%d)
  assert_equals closed "$(row_state "$1")" "$2: the call leaves his open decisions"
  body=$(cd "$HOME_DIR" && tasks-axi show "$1" --full 2>/dev/null)
  assert_contains "$body" "Archived in T3 on $today: not pursued." "$2: the archive is recorded as his decision"
  assert_not_contains "$body" "parked" "$2: archive is never called parking"
}

test_archiving_the_card_closes_its_open_calls() {
  park_home park-watch
  thread_set 't.archived = true;'
  review reconcile
  assert_equals closed "$(meta t3_review)" "his archive is his close"
  assert_not_pursued c1 "a call held from the review"
  assert_not_pursued c2 "a call the review's gate inventoried"
  assert_equals closed "$(row_state s1)" "the scout's own report is marked read"
  assert_equals open "$(row_state c3)" "another task's call stays open"
  assert_not_contains "$(cd "$HOME_DIR" && tasks-axi show c4 --full 2>/dev/null)" "not pursued" "an answered call keeps his answer"
  assert_contains "$(cat "$HOME_DIR/state/t3-review/s1.closed")" "s1 c1 c2 recorded as not pursued or read" "the close notice names what was closed"
  assert_present "$HOME_DIR/data/s1/report.md" "the report is never deleted"
  assert_present "$HOME_DIR/data/s1/handoff-r1.md" "the handoff is never deleted"

  captain hold c5 --title "A later call" --reason "Raised after the archive" --origin s1 >/dev/null 2>&1 || fail "hold c5"
  review reconcile
  assert_equals open "$(row_state c5)" "a call raised after the close is not closed by a later pass"

  park_home park-cleanup
  thread_set 't.archived = true;'
  review check-close s1
  expect_code 0 "$RC" "cleanup may run once he archived it: $OUT"
  assert_not_pursued c1 "cleanup noticing the archive first"
  assert_not_pursued c2 "cleanup noticing the archive first, inventoried call"
  assert_equals open "$(row_state c3)" "cleanup leaves another task's call open"
  assert_equals open "$(row_state s1)" "cleanup, holding the scout's lock, settles its own hold itself"

  # T3 logs his archive, and the listener applies it at once.
  park_home park-closed
  review closed s1 --at 2026-11-13T23:00:00.000Z
  expect_code 0 "$RC" "the logged archive applies: $OUT"
  assert_equals closed "$(meta t3_review)" "recorded closed"
  assert_contains "$(cd "$HOME_DIR" && tasks-axi show c1 --full 2>/dev/null)" "Archived in T3 on 2026-11-13: not pursued." \
    "dated by the archive itself, not by when it was applied"
  assert_equals closed "$(row_state s1)" "and the scout marked read"
  assert_present "$HOME_DIR/state/t3-review/s1.closed" "firstmate is told to clean it up"
  review closed s1 --at 2026-11-13T23:00:00.000Z
  expect_code 0 "$RC" "a replay changes nothing: $OUT"
  pass "fm-t3-review: archiving a kept card closes the calls it carried as not pursued, marks it read, and deletes nothing"
}

# A pending handoff a T3 too old to keep threads refuses is dropped. Found by
# the watcher's pass, firstmate is woken to clean the scout up; found by a
# direct publish, its exit 4 already says so and no second wake is left.
test_reconcile_wakes_cleanup_when_t3_cannot_keep_it() {
  local mode
  for mode in publish reconcile; do
    make_home "dropped-$mode" '{"reviews":false}'
    fm_write_meta "$HOME_DIR/state/s1.meta" window=fm-s1 endpoint_task_id=s1 kind=scout harness=claude backend=t3code \
      "t3_thread_id=$THREAD" t3_project_id=proj-1 "worktree=$HOME_DIR/copy" spawn_gen=gen-1 decisions_reviewed=1 \
      "t3_review_target=$THREAD" t3_review=pending t3_review_revision=1 t3_review_request=fm-review-s1
    printf 'handoff\n' > "$HOME_DIR/data/s1/handoff-r1.md"
    if [ "$mode" = publish ]; then
      review publish s1
      expect_code 4 "$RC" "a direct publish an old T3 refuses exits 4: $OUT"
      assert_equals '' "$(meta t3_review)" "a direct publish drops the record"
      assert_absent "$HOME_DIR/state/t3-review/s1.closed" "a direct publish leaves no cleanup notice; its exit 4 already asks for cleanup"
    else
      review reconcile
      assert_equals '' "$(meta t3_review)" "a T3 that cannot keep the thread drops the record"
      assert_contains "$(cat "$HOME_DIR/state/t3-review/s1.closed" 2>/dev/null)" "bin/fm-teardown.sh s1" "the watcher's drop leaves a cleanup notice for firstmate"
    fi
  done

  # A new handoff recorded while the old T3 answers keeps its record, so the
  # pass drops nothing and asks for no cleanup.
  make_home dropped-renewed '{"reviews":false,"delayMethods":{"tools/list":3000}}'
  fm_write_meta "$HOME_DIR/state/s1.meta" window=fm-s1 endpoint_task_id=s1 kind=scout harness=claude backend=t3code \
    "t3_thread_id=$THREAD" t3_project_id=proj-1 "worktree=$HOME_DIR/copy" spawn_gen=gen-1 decisions_reviewed=1 \
    "t3_review_target=$THREAD" t3_review=pending t3_review_revision=1 t3_review_request=fm-review-s1
  printf 'handoff\n' > "$HOME_DIR/data/s1/handoff-r1.md"
  local renew
  (
    for ((i = 0; i < 600; i++)); do
      grep -q '"delaying":true' "$T3_FAKE_LOG" 2>/dev/null && break
      sleep 0.05
    done
    sed -i.bak 's/^t3_review_request=fm-review-s1$/t3_review_request=fm-review-s1-r2/' "$HOME_DIR/state/s1.meta"
  ) &
  renew=$!
  review reconcile
  wait "$renew"
  assert_equals fm-review-s1-r2 "$(meta t3_review_request)" "the renewed handoff was recorded while T3 answered"
  assert_equals pending "$(meta t3_review)" "a record renewed meanwhile is not dropped"
  assert_absent "$HOME_DIR/state/t3-review/s1.closed" "a pass that dropped nothing leaves no cleanup notice"
  pass "fm-t3-review: a review an old T3 cannot keep is dropped, with a cleanup notice only from the watcher's pass and only when it dropped the record"
}

test_retain_refuses_an_option_without_its_value() {
  make_home usage
  review retain s1 --summary-file
  expect_code 2 "$RC" "an option missing its value is a usage error, not a hang"
  review retain s1 --summary-file "$HOME_DIR/summary.md" --body-file
  expect_code 2 "$RC" "a trailing --body-file without a value is a usage error"
  pass "fm-t3-review retain: an option without its value is refused"
}

WATCH_PID=
start_watcher() {  # -> output in $HOME_DIR/watch.out
  local fakebin
  fakebin=$(fm_fakebin "$HOME_DIR")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  fm_test_track_watcher_state "$HOME_DIR/state"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" PATH="$fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$HOME_DIR/watch.out" 2>/dev/null &
  WATCH_PID=$!
}

# await_watcher <tenths>: 0 once the watcher has exited (it woke), 1 if it is
# still running after that long.
await_watcher() {
  local i=0
  while [ "$i" -lt "$1" ] && kill -0 "$WATCH_PID" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$WATCH_PID" 2>/dev/null
}

stop_watcher() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  wait "$WATCH_PID" 2>/dev/null || true
}

test_watcher_wakes_once_when_he_closes_it() {
  make_home watch-close
  retain
  assert_equals waiting "$(meta t3_review)" "published first: $OUT"
  thread_set 't.archived = true;'
  start_watcher
  await_watcher 200 || { stop_watcher; fail "the watcher did not wake on the captain's close"; }
  wait "$WATCH_PID" 2>/dev/null
  assert_contains "$(cat "$HOME_DIR/watch.out")" "check: t3-review s1: the captain closed" "the wake says he closed the kept review"
  assert_contains "$(cut -f4 "$HOME_DIR/state/.wake-queue")" "t3-review-s1" "behind one durable check wake"
  assert_equals closed "$(meta t3_review)" "the watcher's pass recorded his close"
  assert_absent "$HOME_DIR/state/t3-review/s1.closed" "the notice is consumed"
  pass "fm-watch.sh: the captain closing a kept review wakes firstmate once, durably, to clean it up"
}

test_watcher_never_calls_an_idle_kept_review_stale() {
  local kind
  for kind in control kept; do
    make_home "watch-idle-$kind"
    printf 'done [at=%s]: report written\n' "$(date +%s)" > "$HOME_DIR/state/s1.status"
    FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$HOME_DIR/state" "$HOME_DIR/state/s1.status" \
      || fail "could not mark the done line as already read"
    [ "$kind" = control ] || printf '%s\n' t3_review=waiting "t3_review_target=$THREAD" >> "$HOME_DIR/state/s1.meta"
    start_watcher
    if [ "$kind" = control ]; then
      await_watcher 150 || { stop_watcher; fail "control: an idle finished scout should still reach the stale alarm, or this test proves nothing"; }
      assert_contains "$(cat "$HOME_DIR/watch.out")" "stale: $THREAD" "control: the ordinary finished scout is surfaced as stale"
    else
      ! await_watcher 80 || fail "an idle kept review woke the watcher: $(cat "$HOME_DIR/watch.out")"
      stop_watcher
      assert_not_contains "$(cut -f5 "$HOME_DIR/state/.wake-queue" 2>/dev/null)" "stale:" "no stale alarm is queued for a kept review"
    fi
  done
  pass "fm-watch.sh: an idle kept review never enters the stale alarms, while an ordinary finished scout still does"
}

test_retain_keeps_the_thread_and_posts_no_note
test_watcher_wakes_once_when_he_closes_it
test_watcher_never_calls_an_idle_kept_review_stale
test_retain_refuses_what_it_must_not_keep
test_failures_retry_and_close_wins
test_reconcile_notices_his_close_and_reopen
test_reconcile_survives_a_record_it_cannot_publish
test_archiving_the_card_closes_its_open_calls
test_reconcile_wakes_cleanup_when_t3_cannot_keep_it
test_retain_refuses_an_option_without_its_value
