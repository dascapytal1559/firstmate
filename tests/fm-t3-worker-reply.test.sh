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

test_a_thread_names_its_task
test_a_task_names_itself
test_anything_ambiguous_is_refused

echo "ok: fm-t3-worker-reply"
