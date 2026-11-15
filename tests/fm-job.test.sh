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
#   6. `follow` streams a job's log until it ends, exits with its code, leaves
#      the job running when cut, and re-attaches to a running or ended job;
#      `follow --from-end` re-attaches at the log's last FM_JOB_TAIL_LINES
#      lines instead of repeating it from the start.
#      A follow of a job still running after FM_JOB_FOLLOW_MAX seconds ends by
#      itself, says the job is still running and the worker should declare the
#      wait, exits 75, and leaves the result undelivered for `deliver`.
#   7. A start for a task this home does not record is refused.
#   8. `deliver` holds a just-ended result for FM_JOB_DELIVER_GRACE seconds, so
#      a follower that saw the end marks it first and no second copy is sent,
#      while a result no follower took is still sent on a later cycle.
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

job() {  # <home> <args...>: deliver's grace is 0 unless DELIVER_GRACE is set
  local h=$1
  shift
  env PATH="$FAKEBIN:$PATH" FM_HOME="$h" FM_SEND_SETTLE=0 FM_JOB_KILL_GRACE=1 \
    FM_JOB_DELIVER_GRACE="${DELIVER_GRACE:-0}" "$JOB" "$@"
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
  # A Linux user session's systemd is a subreaper and adopts orphans in init's
  # place, which bin/fm-fleet-idle.sh accepts as detached too.
  if [ "$ppid" != 1 ]; then
    case "$(ps -o comm= -p "$ppid" 2>/dev/null)" in
      systemd|*/systemd) ;;
      *) fail "the runner should be reparented to init, parent is $ppid" ;;
    esac
  fi
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

test_timer_ends_with_its_runner() {
  local h r runner cpgid p kids timer i
  h=$(new_home timer)
  FM_JOB_TIMER_POLL=1 job "$h" start t1 --timeout 600 -- sleep 300 >/dev/null || fail "timer job did not start"
  r=$(rec "$h" 1)
  remember_runner "$r"
  runner=$(field "$r" runner_pid)
  cpgid=$(field "$r" command_pgid)
  for ((i = 0; i < 50; i++)); do
    kids=$(ps -axo pid=,ppid= | awk -v r="$runner" -v c="$cpgid" '$2 == r && $1 != c {print $1}')
    [ -n "$kids" ] && break
    sleep 0.1
  done
  [ -n "$kids" ] || fail "the runner has no timer process to check"
  timer=$(printf '%s\n' "$kids" | head -n 1)
  STARTED_PIDS+=("$timer")
  kill -KILL "$runner" || fail "could not kill the runner"
  for ((i = 0; i < 100; i++)); do kill -0 "$timer" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$timer" 2>/dev/null || fail "a timer must exit once its runner is gone, not wait out the timeout and signal a stale process group"
  [ ! -e "$(dirname "$r")/timed-out" ] || fail "an orphaned timer must not mark the job timed out"
  pass "a job's timeout timer exits when its runner is killed"
}

# A runner killed outright leaves its command running in its own group; deliver
# stops that command before reporting the job lost, so the worker's rerun is
# never a second copy, and a group whose leader is no longer the recorded
# process is never signalled.
test_deliver_stops_a_command_its_runner_left() {
  local h r runner cpgid i
  h=$(new_home orphan)
  job "$h" start t1 -- sleep 300 >/dev/null || fail "orphan job did not start"
  r=$(rec "$h" 1)
  remember_runner "$r"
  runner=$(field "$r" runner_pid)
  for ((i = 0; i < 50; i++)); do
    [ -n "$(field "$r" command_pgid)" ] && break
    sleep 0.1
  done
  cpgid=$(field "$r" command_pgid)
  [ -n "$cpgid" ] || fail "the runner never recorded its command"
  kill -KILL "$runner" || fail "could not kill the runner"
  for ((i = 0; i < 50; i++)); do kill -0 "$runner" 2>/dev/null || break; sleep 0.1; done
  kill -0 -- "-$cpgid" 2>/dev/null || fail "the command should outlive a killed runner until something stops it"
  job "$h" deliver || fail "deliver failed"
  ! kill -0 -- "-$cpgid" 2>/dev/null || fail "deliver must stop the command a dead runner left running before reporting it lost"
  [ "$(field "$r" outcome)" = lost ] || fail "the job should read lost: $(cat "$r")"
  [ -n "$(field "$r" notified)" ] || fail "the lost result should be delivered"

  # A record whose command group leader is not the process it started (pid
  # reuse) is reported lost without signalling that group.
  set -m
  sleep 300 &
  cpgid=$!
  set +m
  STARTED_PIDS+=("$cpgid")
  kill -0 -- "-$cpgid" 2>/dev/null || fail "the stand-in process should lead its own group"
  mkdir -p "$h/state/t1.jobs/2"
  : > "$h/state/t1.jobs/2/log"
  printf 'task=t1\njob=2\ncommand=sleep 300\ncwd=%s\nlog=%s\ntimeout=60\nstarted=100\nrunner_identity=gone\nrunner_pid=999999\ncommand_start=Thu Jan  1 00:00:00 1970\ncommand_pgid=%s\n' \
    "$h/wt" "$h/state/t1.jobs/2/log" "$cpgid" > "$h/state/t1.jobs/2/record"
  job "$h" deliver || fail "deliver with a reused command pid failed"
  [ "$(field "$(rec "$h" 2)" outcome)" = lost ] || fail "the job with a reused command pid should read lost"
  kill -0 -- "-$cpgid" 2>/dev/null || fail "a process that only reuses the recorded pid must never be signalled"
  kill -KILL "$cpgid" 2>/dev/null || true
  pass "deliver stops a command its killed runner left running, and never signals a reused pid"
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

test_follow_streams_survives_a_cut_and_reattaches() {
  local h r out rc fpid
  h=$(new_home follow)
  job "$h" start t1 -- bash -c 'echo first; sleep 2; echo second; exit 4' >/dev/null || fail "start failed"
  r=$(rec "$h" 1)
  remember_runner "$r"
  # A follow cut mid-job leaves the job running.
  job "$h" follow t1 1 > "$h/cut.out" 2>&1 &
  fpid=$!
  sleep 0.5
  kill -KILL "$fpid" 2>/dev/null
  wait "$fpid" 2>/dev/null
  [ -z "$(field "$r" outcome)" ] || fail "the job should still run after its follow was cut"
  # A new follow re-attaches, streams the whole log, and ends with the job.
  rc=0
  out=$(env FM_JOB_FOLLOW_POLL=0.2 PATH="$FAKEBIN:$PATH" FM_HOME="$h" "$JOB" follow t1 1) || rc=$?
  expect_code 4 "$rc" "follow exits with the job's exit code"
  assert_contains "$out" "first" "follow prints the log from its start"
  assert_contains "$out" "second" "follow prints lines written while it waits"
  assert_contains "$out" "job 1 ended: failed (exit 4)" "follow prints the result"
  assert_contains "$out" "log: $h/state/t1.jobs/1/log" "follow names the log"
  [ -n "$(field "$r" notified)" ] || fail "a follow that saw the end marks the result delivered"
  # Following an ended job prints the result at once.
  rc=0
  out=$(job "$h" follow t1 1) || rc=$?
  expect_code 4 "$rc" "a follow of an ended job still exits with its code"
  assert_contains "$out" "job 1 ended: failed (exit 4)" "a follow of an ended job prints its result"
  pass "follow streams a job, survives being cut, re-attaches, and returns the job's exit code"
}

test_follow_from_end_reattaches_at_the_last_lines() {
  local h r out rc i
  h=$(new_home from-end)
  # shellcheck disable=SC2016 # Expanded by the inner shell.
  job "$h" start t1 -- bash -c 'for i in 01 02 03 04 05 06 07 08 09 10; do echo "row-$i"; done; sleep 2; echo after; exit 0' >/dev/null \
    || fail "start failed"
  r=$(rec "$h" 1)
  remember_runner "$r"
  for ((i = 0; i < 50; i++)); do
    grep -q row-10 "$h/state/t1.jobs/1/log" 2>/dev/null && break
    sleep 0.1
  done
  rc=0
  out=$(env FM_JOB_TAIL_LINES=3 FM_JOB_FOLLOW_POLL=0.2 PATH="$FAKEBIN:$PATH" FM_HOME="$h" "$JOB" follow t1 1 --from-end) || rc=$?
  expect_code 0 "$rc" "a re-attach exits with the job's exit code"
  assert_not_contains "$out" "row-01" "a re-attach does not repeat the log from its start"
  assert_not_contains "$out" "row-07" "a re-attach starts at the last FM_JOB_TAIL_LINES lines"
  assert_contains "$out" "row-08"$'\n'"row-09"$'\n'"row-10" "a re-attach shows the last FM_JOB_TAIL_LINES lines"
  assert_contains "$out" "earlier output is in $h/state/t1.jobs/1/log" "a re-attach names where the earlier output is"
  assert_contains "$out" "after" "a re-attach streams lines written while it waits"
  assert_contains "$out" "job 1 ended: passed (exit 0)" "a re-attach prints the result"
  rc=0
  job "$h" follow t1 1 --tail >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown follow option is refused"
  pass "follow --from-end re-attaches at the log's last lines"
}

test_deliver_waits_for_a_follower_to_take_the_result() {
  local h out rc j
  h=$(new_home grace)
  # Job 1 has just ended and a follower is watching it; job 2 just ended with
  # nobody watching.
  for j in 1 2; do
    mkdir -p "$h/state/t1.jobs/$j"
    printf 'done %s\n' "$j" > "$h/state/t1.jobs/$j/log"
    printf 'task=t1\njob=%s\ncommand=make test\ncwd=%s\nlog=%s\nstarted=%s\nexit=0\nfinished=%s\noutcome=passed\n' \
      "$j" "$h/wt" "$h/state/t1.jobs/$j/log" "$(($(date +%s) - 60))" "$(date +%s)" > "$h/state/t1.jobs/$j/record"
  done
  DELIVER_GRACE=2 job "$h" deliver || fail "deliver failed"
  [ ! -e "$h/state/t1.inbox" ] || fail "a result that ended moments ago must wait for a follower: $(ls "$h/state/t1.inbox")"
  rc=0
  out=$(job "$h" follow t1 1) || rc=$?
  expect_code 0 "$rc" "the follower exits with the job's code"
  assert_contains "$out" "job 1 ended: passed (exit 0)" "the follower shows the result"
  sleep 3
  DELIVER_GRACE=2 job "$h" deliver || fail "deliver after the grace failed"
  [ "$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "exactly the result no follower took should be sent"
  out=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg')")
  assert_contains "$out" "Your detached job 2 ended: passed" "the unwatched job's result is delivered after the grace"
  [ -n "$(field "$(rec "$h" 2)" notified)" ] || fail "the unwatched job should be marked delivered"
  pass "deliver leaves a just-ended result to its follower and sends one nobody took"
}

test_follow_ends_at_its_bound_and_leaves_the_result_for_deliver() {
  local h r out rc
  h=$(new_home bound)
  job "$h" start t1 -- bash -c 'echo working; sleep 5; echo finished; exit 3' >/dev/null || fail "start failed"
  r=$(rec "$h" 1)
  remember_runner "$r"
  rc=0
  out=$(FM_JOB_FOLLOW_MAX=2 FM_JOB_FOLLOW_POLL=0.2 job "$h" follow t1 1) || rc=$?
  expect_code 75 "$rc" "a follow that reaches its bound exits 75"
  assert_contains "$out" "working" "a bounded follow still streams the log"
  assert_contains "$out" "job 1 is still running after 2s of following" "a bounded follow says the job is still running"
  assert_contains "$out" "Declare the wait and end your turn" "a bounded follow tells the worker to declare the wait"
  assert_contains "$out" "log: $h/state/t1.jobs/1/log" "a bounded follow names the log"
  assert_not_contains "$out" "ended:" "a bounded follow does not report an outcome"
  [ -z "$(field "$r" outcome)" ] || fail "the job should keep running after its follow reached the bound"
  [ -z "$(field "$r" notified)" ] || fail "a follow that reached its bound must not mark the result delivered"
  wait_outcome "$r" 20 || fail "the job should end on its own"
  job "$h" deliver || fail "deliver failed"
  [ "$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "deliver should send the result of a job whose follow reached its bound"
  out=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(find "$h/state/t1.inbox" -maxdepth 1 -name '*.msg')")
  assert_contains "$out" "Your detached job 1 ended: failed (exit 3)" "the result arrives as an instruction"
  # A job that ends inside the bound is reported as before, with its own code.
  job "$h" start t1 -- bash -c 'echo quick; exit 4' >/dev/null || fail "second start failed"
  r=$(rec "$h" 2)
  remember_runner "$r"
  rc=0
  out=$(FM_JOB_FOLLOW_MAX=30 FM_JOB_FOLLOW_POLL=0.2 job "$h" follow t1 2) || rc=$?
  expect_code 4 "$rc" "a job that ends inside the bound keeps its own exit code"
  assert_contains "$out" "job 2 ended: failed (exit 4)" "a job that ends inside the bound prints its result"
  [ -n "$(field "$r" notified)" ] || fail "a follow that saw the end marks the result delivered"
  rc=0
  FM_JOB_FOLLOW_MAX=soon job "$h" follow t1 2 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unusable FM_JOB_FOLLOW_MAX is refused"
  pass "follow ends by itself at its bound, exits 75, and leaves the result for deliver"
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
test_timer_ends_with_its_runner
test_deliver_stops_a_command_its_runner_left
test_live_deliver_and_lost
test_watcher_tick_delivers
test_reap_stops_and_removes
test_follow_streams_survives_a_cut_and_reattaches
test_follow_from_end_reattaches_at_the_last_lines
test_deliver_waits_for_a_follower_to_take_the_result
test_follow_ends_at_its_bound_and_leaves_the_result_for_deliver
test_unknown_task_refused
