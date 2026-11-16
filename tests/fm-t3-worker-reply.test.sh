#!/usr/bin/env bash
# tests/fm-t3-worker-reply.test.sh - bin/fm-t3-worker-reply.sh names the task
# behind a captain message T3 forwarded from a worker's thread, in both of the
# message's forms, and refuses anything ambiguous.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPLY="$ROOT/bin/fm-t3-worker-reply.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-worker-reply)
trap fm_test_cleanup EXIT

STATE_DIR="$TMP_ROOT/state"
FORWARDED="$TMP_ROOT/forwarded.txt"
WORKER='mcp:7a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d'
OTHER='mcp:00000000-0000-4000-8000-0000000000b2'
mkdir -p "$STATE_DIR"
fm_write_meta "$STATE_DIR/s1.meta" kind=scout backend=t3code "t3_thread_id=$WORKER"
fm_write_meta "$STATE_DIR/w9.meta" kind=ship backend=t3code "t3_thread_id=$OTHER"

# reply <message> -> OUT, RC: the reader's answer for that message file.
reply() {
  printf '%s' "$1" > "$FORWARDED"
  OUT=$(FM_STATE_OVERRIDE="$STATE_DIR" "$REPLY" "$FORWARDED" 2>&1)
  RC=$?
}

test_a_thread_names_its_task() {
  reply "**Reply · Camera options**
kept-thread: $WORKER

Looks good, but check the lens too.
"
  expect_code 0 "$RC" "a message naming a worker's thread names its task: $OUT"
  assert_equals s1 "$OUT" "the task is the one recorded on that thread"
  assert_equals w9 "$(printf '> kept-thread: %s\nyes\n' "$OTHER" | FM_STATE_OVERRIDE="$STATE_DIR" "$REPLY")" \
    "a quoted marker reads from stdin"
  reply "**Reply · Camera options**
kept-thread: mcp:00000000-0000-4000-8000-00000000dead

Hello.
"
  expect_code 1 "$RC" "a thread no task records names no task: $OUT"
  assert_contains "$OUT" "no task records" "the refusal says the thread is unknown"
  pass "fm-t3-worker-reply.sh: a thread names the one task recorded on it"
}

test_a_task_names_itself() {
  reply '**Decision · Buy the camera**
needs-me-task: w2

> Buy the camera?
>
> A or B?

Yes, buy it.
'
  expect_code 0 "$RC" "a message naming its task reads: $OUT"
  assert_equals w2 "$OUT" "the marker names the task"
  reply 'Just chatting, no marker.
'
  expect_code 1 "$RC" "a message with no marker names no worker: $OUT"
  pass "fm-t3-worker-reply.sh: a task id on the message names that task"
}

test_anything_ambiguous_is_refused() {
  reply 'needs-me-task: w1
needs-me-task: w2
'
  expect_code 2 "$RC" "two tasks are ambiguous: $OUT"
  reply 'needs-me-task: ../w1
'
  expect_code 2 "$RC" "a malformed task id is refused: $OUT"
  reply "kept-thread: $WORKER
needs-me-task: w2
"
  expect_code 2 "$RC" "a message naming both a task and a thread is ambiguous: $OUT"
  reply "kept-thread: $WORKER
kept-thread: $OTHER
"
  expect_code 2 "$RC" "two threads are ambiguous: $OUT"
  reply 'kept-thread: mcp:../s1
'
  expect_code 2 "$RC" "a malformed thread id is refused: $OUT"
  fm_write_meta "$STATE_DIR/s2.meta" kind=scout backend=t3code "t3_thread_id=$WORKER"
  reply "kept-thread: $WORKER
"
  expect_code 2 "$RC" "a thread two records name is ambiguous: $OUT"
  rm -f "$STATE_DIR/s2.meta"
  FM_STATE_OVERRIDE="$STATE_DIR" "$REPLY" a b >/dev/null 2>&1
  expect_code 2 "$?" "more than one argument is invalid use"
  pass "fm-t3-worker-reply.sh: nothing ambiguous or malformed names a task"
}

# A settle, un-settle, snooze, or un-snooze in T3 names the task and its action.
test_a_thread_action_names_its_task_and_action() {
  local action
  for action in settled unsettled unsnoozed; do
    reply "**Settled · Camera options**
kept-thread: $WORKER
thread-action: $action
"
    expect_code 0 "$RC" "a $action message reads: $OUT"
    assert_equals "s1
thread-action: $action" "$OUT" "a $action message names the task, then its action"
  done
  reply "**Snoozed · Camera options**
kept-thread: $WORKER
thread-action: snoozed until 2026-11-20T09:00:00.000Z
"
  expect_code 0 "$RC" "a dated snooze reads: $OUT"
  assert_equals "s1
thread-action: snoozed until 2026-11-20T09:00:00.000Z" "$OUT" "a dated snooze keeps its time"
  reply "**Snoozed · Camera options**
> kept-thread: $WORKER
>   thread-action:   snoozed   until   2026-11-20T09:00Z
"
  expect_code 0 "$RC" "a quoted, spaced snooze reads: $OUT"
  assert_equals "s1
thread-action: snoozed until 2026-11-20T09:00Z" "$OUT" "the action line is normalized"
  reply "**Snoozed · Camera options**
kept-thread: $WORKER
thread-action: snoozed
"
  expect_code 0 "$RC" "an indefinite snooze reads: $OUT"
  assert_equals "s1
thread-action: snoozed" "$OUT" "an indefinite snooze has no time"
  reply "**Settled · Lost**
kept-thread: mcp:00000000-0000-4000-8000-00000000dead
thread-action: settled
"
  expect_code 1 "$RC" "a settle on a thread no task records names no task: $OUT"
  pass "fm-t3-worker-reply.sh: a thread action names its task and the action"
}

test_a_malformed_thread_action_is_refused() {
  local bad
  for bad in 'archived' 'settled now' 'snoozed 2026-11-20T09:00:00Z' 'snoozed until tomorrow' \
    'snoozed until 2026-11-20' 'snoozed until 2026-11-20T09:00:00+01:00' 'unsnoozed until 2026-11-20T09:00Z'; do
    reply "kept-thread: $WORKER
thread-action: $bad
"
    expect_code 2 "$RC" "a malformed action '$bad' is refused: $OUT"
  done
  reply "kept-thread: $WORKER
thread-action: settled
thread-action: unsettled
"
  expect_code 2 "$RC" "two actions are ambiguous: $OUT"
  assert_contains "$OUT" "more than one thread action" "the refusal names the second action"
  pass "fm-t3-worker-reply.sh: a malformed or doubled thread action is refused"
}

test_a_thread_names_its_task
test_a_task_names_itself
test_anything_ambiguous_is_refused
test_a_thread_action_names_its_task_and_action
test_a_malformed_thread_action_is_refused

echo "ok: fm-t3-worker-reply"
