#!/usr/bin/env bash
# fm-job.sh - run a worker's long command as a detached job, outside the
# process tree of the agent and the app that hosts it, and hand its result back
# through the task's durable steering inbox.
#
# Usage:
#   fm-job.sh start <task-id> [--timeout <secs>] [--cwd <dir>] -- <command> [args...]
#   fm-job.sh status <task-id> [<job>]
#   fm-job.sh stop <task-id> <job>
#   fm-job.sh deliver
#   fm-job.sh live
#   fm-job.sh reap <task-id>
#
# start    Run <command> (an argv, executed directly with no shell; pass
#          `bash -c '...'` for shell syntax) in <dir> (default: the current
#          directory) as job <n> of <task-id>, a task recorded in this home.
#          The command keeps the caller's environment, reads /dev/null, and
#          writes stdout and stderr to the job's log. It is started through a
#          double fork and setsid, so its runner is reparented to init in its
#          own session: restarting the app that hosts the worker (T3 Code
#          stops every process it started) or closing the worker's pane does
#          not stop it. The job is stopped after --timeout seconds (default
#          FM_JOB_TIMEOUT, 7200). Prints the job number and log path, then the
#          worker declares a paused wait naming the job and ends its turn.
# status   Print one line per job of <task-id> (or just <job>): its number,
#          outcome (running until it ends), exit code, start time, log path,
#          and command.
# stop     Stop a running job: TERM to its process group, then KILL after
#          FM_JOB_KILL_GRACE seconds (default 10). Its outcome reads stopped,
#          and its result is still delivered.
# deliver  Firstmate's watcher runs this on every cycle while any job record
#          exists. Each ended job whose result has not been delivered is sent
#          to its task with bin/fm-send.sh (a durable steering-inbox record
#          that survives an app restart, plus a doorbell that starts the
#          worker's next turn): its outcome, exit code, run time, log path, and
#          the log's last lines. A job whose runner is gone without recording
#          an outcome (the machine restarted, or it was killed) is recorded as
#          lost and delivered the same way. A failed send is retried on the
#          next cycle. Silent; exits 0 unless the state directory is unusable.
# live     Print "<task-id><TAB><runner-pid>" for every job still running whose
#          runner is the process that recorded itself (pid plus start
#          identity). bin/fm-fleet-idle.sh reads it to leave a running job out
#          of its "is this worker mid-turn" verdict.
# reap     Teardown's step: stop every running job of <task-id>, then remove
#          its job records. Exits 1, keeping the records, when a job's process
#          group survives KILL.
#
# Records live in this home's state/<task-id>.jobs/<n>/: `record` holds
# key=value lines read last-value-wins (task, job, command, cwd, log,
# timeout, started, runner_pid, runner_identity, command_pgid, exit, finished,
# outcome, notified), `argv` holds the NUL-separated command, and `log` its
# output. Lines are only ever appended. `outcome=` (passed, failed, timed-out,
# stopped, or lost) is written last and is what marks a job ended; `notified=`
# marks its result delivered.
#
# Process shape: the runner (`fm-job.sh _run <dir>`, never called directly)
# leads its own session, and starts the command in a process group of its own
# so a timeout or stop can signal the whole command tree without touching the
# runner, which then records the outcome. When the command's leader exits, any
# process it left behind in its group is stopped the same way, so an ended job
# leaves nothing running. Before signalling, stop and reap check that the
# recorded runner is still the same process; a runner that is gone is never
# signalled on its recorded pid.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SELF="$SCRIPT_DIR/fm-job.sh"

JOB_TIMEOUT=${FM_JOB_TIMEOUT:-7200}
KILL_GRACE=${FM_JOB_KILL_GRACE:-10}
TAIL_LINES=${FM_JOB_TAIL_LINES:-20}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'fm-job: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; esac; }

job_get() {  # <record> <key>: the last value of key=, or empty
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

job_put() { printf '%s=%s\n' "$2" "$3" >> "$1"; }  # <record> <key> <value>

now() { local t; fm_epoch_seconds_to t; printf '%s' "$t"; }

valid_task() {  # <task-id>: a path-safe id with a task record in this home
  fm_task_id_path_safe "${1-}" || die "invalid task id: ${1-}" 2
  [ -f "$STATE/$1.meta" ] || die "no task $1 is recorded in this home ($STATE)" 2
}

job_dir() {  # <task-id> <job>
  case "${2-}" in ''|*[!0-9]*) die "invalid job number: ${2-}" 2 ;; esac
  [ -f "$STATE/$1.jobs/$2/record" ] || die "task $1 has no job $2" 2
  printf '%s' "$STATE/$1.jobs/$2"
}

# runner_live <record>: the recorded runner is alive and is still the process
# that recorded itself.
runner_live() {
  local pid identity
  pid=$(job_get "$1" runner_pid)
  identity=$(job_get "$1" runner_identity)
  [ -n "$pid" ] && [ -n "$identity" ] && fm_pid_alive "$pid" || return 1
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ]
}

group_alive() { [ -n "${1-}" ] && kill -0 -- "-$1" 2>/dev/null; }

# stop_group <pgid> <grace>: TERM the group, KILL whatever is left after the
# grace. Returns 1 when the group still exists afterwards.
stop_group() {
  local pgid=$1 grace=$2 i
  group_alive "$pgid" || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for ((i = 0; i < grace * 10; i++)); do
    group_alive "$pgid" || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    group_alive "$pgid" || return 0
    sleep 0.1
  done
  return 1
}

cmd_start() {
  local id=${1-} timeout=$JOB_TIMEOUT cwd jobs n dir display i
  [ "$#" -gt 0 ] && shift
  valid_task "$id"
  cwd=$(pwd -P)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) [ "$#" -ge 2 ] || die "--timeout needs seconds" 2; timeout=$2; shift 2 ;;
      --cwd) [ "$#" -ge 2 ] || die "--cwd needs a directory" 2; cwd=$2; shift 2 ;;
      --) shift; break ;;
      *) die "unknown option before --: $1" 2 ;;
    esac
  done
  [ "$#" -gt 0 ] || die "no command given after --" 2
  positive_int "$timeout" || die "--timeout must be a positive number of seconds: $timeout" 2
  cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || die "working directory is unavailable: $cwd" 2
  jobs="$STATE/$id.jobs"
  mkdir -p "$jobs" || die "cannot create $jobs"
  n=1
  until mkdir "$jobs/$n" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -le 100000 ] || die "cannot claim a job number under $jobs"
  done
  dir="$jobs/$n"
  printf '%s\0' "$@" > "$dir/argv" || die "cannot write $dir/argv"
  display=$(printf '%q ' "$@")
  display=${display% }
  : > "$dir/log" || die "cannot create $dir/log"
  {
    printf 'task=%s\njob=%s\ncommand=%s\ncwd=%s\nlog=%s\ntimeout=%s\nstarted=%s\n' \
      "$id" "$n" "$display" "$cwd" "$dir/log" "$timeout" "$(now)"
  } > "$dir/record" || die "cannot write $dir/record"
  # Double fork with setsid: the middle child leads a new session and exits,
  # so the runner is reparented to init with no controlling terminal and no
  # tie to the caller's process tree, process group, or session. Every
  # descriptor above stderr is closed so the caller's pipes see EOF at once.
  # shellcheck disable=SC2016 # Perl code, not shell.
  perl -MPOSIX -e '
    defined(my $p = fork) or die "fork: $!\n";
    if ($p) { waitpid($p, 0); exit($? >> 8); }
    POSIX::setsid() or POSIX::_exit(1);
    defined(my $q = fork) or POSIX::_exit(1);
    POSIX::_exit(0) if $q;
    open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">&", \*STDOUT);
    POSIX::close($_) for 3 .. 255;
    exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
  ' "$BASH" "$SELF" _run "$dir" || die "could not start the detached runner for job $n"
  for ((i = 0; i < 100; i++)); do
    [ -z "$(job_get "$dir/record" runner_pid)" ] || break
    sleep 0.1
  done
  if [ -z "$(job_get "$dir/record" runner_pid)" ]; then
    job_put "$dir/record" outcome lost
    job_put "$dir/record" notified "$(now)"
    die "job $n's runner did not start within 10 seconds; nothing is running"
  fi
  printf 'job: %s\nlog: %s\nruns: %s\nin: %s\ntimeout: %ss\n' "$n" "$dir/log" "$display" "$cwd" "$timeout"
}

cmd_run() {
  local dir=${1-} rec cwd log timeout cpid tpid rc outcome a
  local -a argv=()
  rec="$dir/record"
  [ -f "$rec" ] || exit 2
  job_put "$rec" runner_identity "$(fm_pid_identity "$$" 2>/dev/null)"
  job_put "$rec" runner_pid "$$"
  cwd=$(job_get "$rec" cwd)
  log=$(job_get "$rec" log)
  timeout=$(job_get "$rec" timeout)
  while IFS= read -r -d '' a; do argv+=("$a"); done < "$dir/argv"
  if [ "${#argv[@]}" -eq 0 ] || ! cd "$cwd" 2>/dev/null; then
    printf 'fm-job: cannot start: missing command or working directory %s\n' "$cwd" >> "$log"
    job_put "$rec" exit 126
    job_put "$rec" finished "$(now)"
    job_put "$rec" outcome failed
    exit 0
  fi
  # Job control gives the command and the timer each a process group of their
  # own, so either can be signalled as a whole without signalling this runner.
  set -m
  "${argv[@]}" < /dev/null >> "$log" 2>&1 &
  cpid=$!
  job_put "$rec" command_pgid "$cpid"
  (
    sleep "$timeout"
    : > "$dir/timed-out"
    kill -TERM -- "-$cpid" 2>/dev/null
    sleep "$KILL_GRACE"
    kill -KILL -- "-$cpid" 2>/dev/null
  ) < /dev/null > /dev/null 2>&1 &
  tpid=$!
  wait "$cpid"
  rc=$?
  kill -TERM -- "-$tpid" 2>/dev/null
  # The leader is reaped; whatever it left in its group still holds the pgid,
  # which the system never reuses while the group exists.
  stop_group "$cpid" "$KILL_GRACE" || true
  if [ -e "$dir/timed-out" ]; then
    outcome='timed-out'
  elif [ -e "$dir/stopped" ]; then
    outcome=stopped
  elif [ "$rc" -eq 0 ]; then
    outcome=passed
  else
    outcome=failed
  fi
  job_put "$rec" exit "$rc"
  job_put "$rec" finished "$(now)"
  job_put "$rec" outcome "$outcome"
}

# stop_job <dir>: stop a running job and wait for its runner to record the
# outcome. Returns 1 when its command group survives.
stop_job() {
  local dir=$1 rec pgid i
  rec="$dir/record"
  [ -z "$(job_get "$rec" outcome)" ] || return 0
  runner_live "$rec" || return 0
  for ((i = 0; i < 50; i++)); do
    pgid=$(job_get "$rec" command_pgid)
    [ -z "$pgid" ] || break
    sleep 0.1
  done
  : > "$dir/stopped"
  stop_group "$pgid" "$KILL_GRACE" || return 1
  for ((i = 0; i < 100; i++)); do
    [ -z "$(job_get "$rec" outcome)" ] || return 0
    sleep 0.1
  done
  return 0
}

status_line() {  # <dir>
  local rec="$1/record" outcome
  outcome=$(job_get "$rec" outcome)
  [ -n "$outcome" ] || outcome=running
  printf '%s\t%s\texit=%s\tstarted=%s\tlog=%s\t%s\n' "$(job_get "$rec" job)" "$outcome" \
    "$(job_get "$rec" exit)" "$(job_get "$rec" started)" "$(job_get "$rec" log)" "$(job_get "$rec" command)"
}

cmd_status() {
  local id=${1-} dir
  valid_task "$id"
  if [ -n "${2-}" ]; then
    status_line "$(job_dir "$id" "$2")"
    return 0
  fi
  for dir in "$STATE/$id.jobs"/*/; do
    [ -f "$dir/record" ] || continue
    status_line "${dir%/}"
  done
}

cmd_stop() {
  local id=${1-} dir
  valid_task "$id"
  dir=$(job_dir "$id" "${2-}")
  stop_job "$dir" || die "job $2's process group survived KILL"
  status_line "$dir"
}

cmd_live() {
  local rec id
  for rec in "$STATE"/*.jobs/*/record; do
    [ -f "$rec" ] || continue
    [ -z "$(job_get "$rec" outcome)" ] || continue
    runner_live "$rec" || continue
    id=${rec%/*/record}
    id=${id##*/}
    printf '%s\t%s\n' "${id%.jobs}" "$(job_get "$rec" runner_pid)"
  done
}

result_message() {  # <record>
  local rec=$1 outcome code started finished secs log tail_text
  outcome=$(job_get "$rec" outcome)
  code=$(job_get "$rec" exit)
  started=$(job_get "$rec" started)
  finished=$(job_get "$rec" finished)
  log=$(job_get "$rec" log)
  secs=''
  case "$started$finished" in ''|*[!0-9]*) ;; *) secs=$((finished - started)) ;; esac
  printf 'Your detached job %s ended: %s' "$(job_get "$rec" job)" "$outcome"
  [ -z "$code" ] || printf ' (exit %s)' "$code"
  [ -z "$secs" ] || printf ' after %sm%02ds' "$((secs / 60))" "$((secs % 60))"
  printf '.\nCommand: %s\nLog: %s\n' "$(job_get "$rec" command)" "$log"
  [ "$outcome" != lost ] || printf 'Its runner is gone without recording a result (the machine restarted or it was killed); rerun it if you still need it.\n'
  tail_text=$(tail -n "$TAIL_LINES" "$log" 2>/dev/null | sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c1-300)
  [ -z "$tail_text" ] || printf 'Last lines of the log:\n%s\n' "$tail_text"
  printf 'The paused wait you declared for this job has cleared: resolve it and carry on with your task.'
}

cmd_deliver() {
  local rec dir id started
  [ -d "$STATE" ] || return 2
  for rec in "$STATE"/*.jobs/*/record; do
    [ -f "$rec" ] || continue
    [ -z "$(job_get "$rec" notified)" ] || continue
    dir=${rec%/record}
    id=${dir%/*}
    id=${id##*/}
    id=${id%.jobs}
    [ -f "$STATE/$id.meta" ] || continue
    if [ -z "$(job_get "$rec" outcome)" ]; then
      runner_live "$rec" && continue
      # A runner that has not recorded itself yet may still be starting.
      started=$(job_get "$rec" started)
      if [ -z "$(job_get "$rec" runner_pid)" ] && [ -n "$started" ] && [ "$(($(now) - started))" -lt 30 ]; then
        continue
      fi
      # Re-read: the runner may have recorded its outcome and exited since.
      if [ -z "$(job_get "$rec" outcome)" ]; then
        job_put "$rec" finished "$(now)"
        job_put "$rec" outcome lost
      fi
    fi
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$id" "$(result_message "$rec")" >/dev/null 2>&1; then
      job_put "$rec" notified "$(now)"
    fi
  done
  return 0
}

cmd_reap() {
  local id=${1-} dir failed=''
  fm_task_id_path_safe "$id" || die "invalid task id: $id" 2
  [ -d "$STATE/$id.jobs" ] || return 0
  for dir in "$STATE/$id.jobs"/*/; do
    [ -f "$dir/record" ] || continue
    dir=${dir%/}
    if ! stop_job "$dir"; then
      failed="$failed ${dir##*/}"
      continue
    fi
  done
  [ -z "$failed" ] || die "task $id's job(s)$failed kept running after KILL; job records kept in $STATE/$id.jobs"
  rm -rf -- "$STATE/$id.jobs"
}

case "${1-}" in
  start) shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  deliver) shift; cmd_deliver ;;
  live) shift; cmd_live ;;
  reap) shift; cmd_reap "$@" ;;
  _run) shift; cmd_run "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
