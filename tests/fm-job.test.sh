#!/usr/bin/env bash
# tests/fm-job.test.sh - bin/fm-job.sh, the detached-job launcher.
#
# Drives the real executable against hermetic homes and pins:
#   1. A started job runs detached: its runner is reparented to init in a
#      session of its own, the command runs in the requested directory, its
#      output lands in the log, and the record ends with the exit code and a
#      passed or failed outcome.
#   2. A job past its timeout is stopped and reads timed-out; a stopped job
#      reads stopped; a process the command left in its group is stopped when
#      the command ends.
#   3. `live` lists exactly the running jobs whose runner is still the process
#      that recorded itself.
#   4. `deliver` sends each ended job's result once, through the task's
#      durable steering inbox (the real bin/fm-send.sh over a stub tmux),
#      records a job whose runner vanished as lost, and leaves running jobs
#      and jobs of tasks no longer recorded alone.
#   5. `reap` stops a task's running jobs and removes their records.
#   6. A start for a task this home does not record is refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JOB="$ROOT/bin/fm-job.sh"
TMP_ROOT=$(fm_test_tmproot fm-job)

# Stub tmux: the doorbell fm-send rings is logged and every other call passes.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

STARTED_PIDS=()
cleanup_jobs() {
  local p
  for p in ${STARTED_PIDS[@]+"${STARTED_PIDS[@]}"}; do
    kill -KILL -- "-$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
}

new_home() {  # <name> -> home with task t1 recorded
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/wt"
  fm_write_meta "$h/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" "worktree=$h/wt"
  printf '%s\n' "$h"
}

job() {  # <home> <args...>
  local h=$1
  shift
  env PATH="$FAKEBIN:$PATH" FM_HOME="$h" FM_SEND_SETTLE=0 FM_JOB_KILL_GRACE=1 "$JOB" "$@"
}

rec() { printf '%s\n' "$1/state/t1.jobs/$2/record"; }  # <home> <job>

field() {  # <record> <key>: last value
  awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { print v }' "$1"
}

wait_outcome() {  # <record> [seconds]
  local i
  for ((i = 0; i < ${2:-20} * 10; i++)); do
    [ -n "$(field "$1" outcome)" ] && return 0
    sleep 0.1
  done
  return 1
}

remember_runner() {  # <record>
  local pid
  pid=$(field "$1" runner_pid)
  [ -z "$pid" ] || STARTED_PIDS+=("$pid")
  pid=$(field "$1" command_pgid)
  [ -z "$pid" ] || STARTED_PIDS+=("$pid")
}

test_start_runs_detached_and_records_the_result() {
  local h out r runner ppid sess own_sess
  h=$(new_home start)
  mkdir -p "$h/wt/sub"
  out=$(job "$h" start t1 --cwd "$h/wt/sub" -- bash -c 'pwd; echo to-stderr >&2; sleep 1; exit 3') \
    || fail "start failed: $out"
  assert_contains "$out" "job: 1" "start names the job number"
  assert_contains "$out" "log: $h/state/t1.jobs/1/log" "start names the log"
  r=$(rec "$h" 1)
  remember_runner "$r"
  runner=$(field "$r" runner_pid)
  ppid=$(ps -o ppid= -p "$runner" | tr -d ' ')
  [ "$ppid" = 1 ] || fail "the runner should be reparented to init, parent is $ppid"
  sess=$(ps -o sess= -p "$runner" | tr -d ' ')
  own_sess=$(ps -o sess= -p "$$" | tr -d ' ')
  if [ -n "$sess" ] && [ "$sess" != 0 ]; then
    [ "$sess" != "$own_sess" ] || fail "the runner should not share the caller's session"
  fi
  [ "$(ps -o pgid= -p "$runner" | tr -d ' ')" != "$(ps -o pgid= -p "$$" | tr -d ' ')" ] \
    || fail "the runner should not share the caller's process group"
  wait_outcome "$r" || fail "the job never recorded an outcome"
  [ "$(field "$r" outcome)" = failed ] || fail "a nonzero exit should read failed: $(cat "$r")"
  [ "$(field "$r" exit)" = 3 ] || fail "the exit code should be recorded: $(cat "$r")"
  [ "$(head -n 1 "$h/state/t1.jobs/1/log")" = "$h/wt/sub" ] || fail "the command should run in the requested directory" "the command should run in the requested directory"
  assert_grep "to-stderr" "$h/state/t1.jobs/1/log" "stderr should land in the log"
  out=$(job "$h" start t1 --cwd "$h/wt" -- true) || fail "second start failed: $out"
  assert_contains "$out" "job: 2" "a second job takes the next number"
  r=$(rec "$h" 2)
  wait_outcome "$r" || fail "the second job never ended"
  [ "$(field "$r" outcome)" = passed ] || fail "exit 0 should read passed: $(cat "$r")"
  out=$(job "$h" status t1)
  assert_contains "$out" $'1\tfailed\texit=3' "status lists the failed job"
  assert_contains "$out" $'2\tpassed\texit=0' "status lists the passed job"
  pass "a job runs detached in its own session, logs its output, and records its outcome"
}

test_timeout_stop_and_leftovers() {
  local h r out left i
  h=$(new_home stop)
  job "$h" start t1 --timeout 1 -- sleep 30 >/dev/null || fail "timeout job did not start"
  r=$(rec "$h" 1)
  remember_runner "$r"
  wait_outcome "$r" 15 || fail "a job past its timeout was not stopped"
  [ "$(field "$r" outcome)" = timed-out ] || fail "a job past its timeout should read timed-out: $(cat "$r")"

  job "$h" start t1 -- sleep 30 >/dev/null || fail "stop job did not start"
  r=$(rec "$h" 2)
  remember_runner "$r"
  out=$(job "$h" stop t1 2) || fail "stop failed: $out"
  [ "$(field "$r" outcome)" = stopped ] || fail "a stopped job should read stopped: $(cat "$r")"

  job "$h" start t1 -- bash -c "sleep 300 & echo \$! > '$h/left.pid'; exit 0" >/dev/null || fail "leftover job did not start"
  r=$(rec "$h" 3)
  remember_runner "$r"
  wait_outcome "$r" 15 || fail "the leftover job never ended"
  left=$(cat "$h/left.pid")
  STARTED_PIDS+=("$left")
  for ((i = 0; i < 50; i++)); do kill -0 "$left" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$left" 2>/dev/null || fail "a process the command left in its group should be stopped with the job"
  [ "$(field "$r" outcome)" = passed ] || fail "the command itself passed: $(cat "$r")"
  pass "a job is stopped at its timeout or on request, and leaves nothing running when it ends"
}

test_live_deliver_and_lost() {
  local h r out msg body
  h=$(new_home deliver)
  job "$h" start t1 -- bash -c 'echo all 12 tests passed' >/dev/null || fail "quick job did not start"
  wait_outcome "$(rec "$h" 1)" || fail "quick job never ended"
  job "$h" start t1 -- sleep 30 >/dev/null || fail "running job did not start"
  r=$(rec "$h" 2)
  remember_runner "$r"
  out=$(job "$h" live)
  [ "$out" = "t1"$'\t'"$(field "$r" runner_pid)" ] || fail "live should list exactly the running job: $out"

  # A third job whose runner vanished without an outcome, as after a reboot.
  mkdir -p "$h/state/t1.jobs/3"
  : > "$h/state/t1.jobs/3/log"
  printf 'task=t1\njob=3\ncommand=make test\ncwd=%s\nlog=%s\ntimeout=60\nstarted=100\nrunner_identity=gone\nrunner_pid=999999\n' \
    "$h/wt" "$h/state/t1.jobs/3/log" > "$h/state/t1.jobs/3/record"

  job "$h" deliver || fail "deliver failed"
  [ -n "$(field "$(rec "$h" 1)" notified)" ] || fail "the ended job should be marked delivered"
  [ -z "$(field "$r" notified)" ] || fail "a running job must not be delivered"
  [ "$(field "$(rec "$h" 3)" outcome)" = lost ] || fail "a vanished runner should read lost"
  msg=$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg' | sort -V)
  [ "$(printf '%s\n' "$msg" | wc -l | tr -d ' ')" = 2 ] || fail "two results should be in the inbox: $msg"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(printf '%s\n' "$msg" | head -1)")
  assert_contains "$body" "Your detached job 1 ended: passed (exit 0)" "the result names the job and outcome"
  assert_contains "$body" "Log: $h/state/t1.jobs/1/log" "the result names the log"
  assert_contains "$body" "all 12 tests passed" "the result carries the log's last lines"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(printf '%s\n' "$msg" | tail -1)")
  assert_contains "$body" "Your detached job 3 ended: lost" "a lost job is reported as lost"

  job "$h" deliver || fail "second deliver failed"
  [ "$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 2 ] \
    || fail "a delivered result must not be sent twice"

  # A job of a task no longer recorded is left alone.
  mkdir -p "$h/state/t9.jobs/1"
  printf 'task=t9\njob=1\noutcome=passed\nexit=0\n' > "$h/state/t9.jobs/1/record"
  job "$h" deliver || fail "deliver with an unrecorded task failed"
  [ -z "$(field "$h/state/t9.jobs/1/record" notified)" ] || fail "an unrecorded task's job must not be delivered"
  [ ! -e "$h/state/t9.inbox" ] || fail "no inbox should be created for an unrecorded task"
  pass "deliver sends each ended or lost job's result once through the steering inbox"
}

test_watcher_tick_delivers() {
  local h
  h=$(new_home watcher)
  mkdir -p "$h/state/t1.jobs/1"
  printf 'done\n' > "$h/state/t1.jobs/1/log"
  printf 'task=t1\njob=1\ncommand=make test\ncwd=%s\nlog=%s\nstarted=100\nexit=0\nfinished=160\noutcome=passed\n' \
    "$h/wt" "$h/state/t1.jobs/1/log" > "$h/state/t1.jobs/1/record"
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  env PATH="$FAKEBIN:$PATH" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_SEND_SETTLE=0 bash -eu -c '
    . "$1/bin/fm-watch.sh"
    detached_job_tick
  ' _ "$ROOT" || fail "the watcher's detached-job tick failed"
  [ -f "$h/state/t1.inbox/001.msg" ] || fail "the watcher tick should deliver an ended job's result"
  [ -n "$(field "$h/state/t1.jobs/1/record" notified)" ] || fail "the watcher tick should mark the result delivered"
  pass "the watcher's cycle delivers ended jobs' results"
}

test_reap_stops_and_removes() {
  local h r runner pgid
  h=$(new_home reap)
  job "$h" start t1 -- sleep 30 >/dev/null || fail "reap job did not start"
  r=$(rec "$h" 1)
  remember_runner "$r"
  runner=$(field "$r" runner_pid)
  pgid=$(field "$r" command_pgid)
  job "$h" reap t1 || fail "reap failed"
  [ ! -e "$h/state/t1.jobs" ] || fail "reap should remove the task's job records"
  ! kill -0 -- "-$pgid" 2>/dev/null || fail "reap should stop the job's command"
  sleep 0.5
  ! kill -0 "$runner" 2>/dev/null || fail "the runner should exit once its command is stopped"
  job "$h" reap t1 || fail "reap with nothing to reap should succeed"
  pass "reap stops a task's running jobs and removes their records"
}

test_unknown_task_refused() {
  local h rc
  h=$(new_home refuse)
  rc=0
  job "$h" start nope -- true >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a start for an unrecorded task should be refused"
  [ ! -e "$h/state/nope.jobs" ] || fail "a refused start must not create records"
  rc=0
  job "$h" start t1 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a start with no command should be refused"
  pass "a start for an unrecorded task or with no command is refused"
}

trap 'cleanup_jobs; fm_test_cleanup' EXIT
test_start_runs_detached_and_records_the_result
test_timeout_stop_and_leftovers
test_live_deliver_and_lost
test_watcher_tick_delivers
test_reap_stops_and_removes
test_unknown_task_refused
