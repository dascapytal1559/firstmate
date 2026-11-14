#!/usr/bin/env bash
# fm-t3-restart-request.sh - restart T3 Code cleanly through the T3 Code
# fork's restart registry (docs/t3code-backend.md "Clean restart"): ask T3
# for the restart, wait until every turn has finished, and only then let the
# caller restart it, so no running turn is ever cut.
#
# While a restart request is pending T3 starts no new turn anywhere: every
# message queues, held, and turns already running finish normally. T3 never
# restarts itself; the requester restarts it once T3 reports drained (the
# request pending and no turn in flight, FirstMate's own included). A server
# start clears the request and releases the held messages.
#
# Usage:
#   fm-t3-restart-request.sh drain --reason <text> [--within <secs>] [--interval <secs>]
#     Request the restart with <reason> (shown to the captain in T3's notice,
#     such as "install T3 build staged-20261113-x"; 1 to 500 characters),
#     then poll T3 every --interval seconds (default 5) until it reports
#     drained. A request already pending with exactly this reason is adopted
#     rather than requested again, so a rerun continues the same wait.
#     Exit:
#       0  drained: restart T3 now; the request stays pending, holding
#          messages, until the new server starts, so a caller that then
#          cannot restart T3 must run `cancel` itself.
#       1  not drained within --within seconds (default 1800): the request
#          was cancelled, so held messages run; nothing is to be restarted.
#       2  usage, or T3's restart registry could not be read or written
#          (unreachable, refused, or a T3 without the registry); a request
#          this run made is cancelled where T3 can still be reached.
#       3  the request ended before T3 drained: it was cancelled in T3 (the
#          notice's Cancel restart) or replaced, or T3 restarted on its own.
#          Do not restart.
#       4  another restart, with a different reason, was already pending;
#          nothing was requested or cancelled. Do not restart.
#     A TERM, INT, or HUP before drained (a retired watch, or an action
#     timeout) cancels this run's request from a detached process, so the
#     cancel survives the caller killing this run's whole process group, and
#     exits 128+n.
#   fm-t3-restart-request.sh cancel --reason <text>
#     Cancel the pending request only while its reason is exactly <text>,
#     so a newer request is never cancelled by an older one's cleanup. Exits
#     0 when no request with that reason remains (cancelled, or none was
#     pending), 2 when T3 could not be read or the cancel was not proven.
#
# Every outcome prints one line on stdout, which a watch's captured outcome
# carries to firstmate. This home's T3 credential (config/t3code-token) is
# required; bin/fm-t3-mcp.mjs owns the transport and the registry's shape.
# Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

usage() {
  sed -n '13,43p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

say() { printf 't3-restart-request: %s\n' "$*"; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in drain|cancel) ;; *) usage ;; esac

REASON='' WITHIN=1800 INTERVAL=5
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) [ "$#" -ge 2 ] || usage; REASON=$2; shift 2 ;;
    --within) [ "$VERB" = drain ] && [ "$#" -ge 2 ] && positive_int "$2" || usage; WITHIN=$2; shift 2 ;;
    --interval) [ "$VERB" = drain ] && [ "$#" -ge 2 ] && positive_int "$2" || usage; INTERVAL=$2; shift 2 ;;
    *) usage ;;
  esac
done
# T3 trims the reason as JavaScript does; compare and send that same form so
# an adopted or cancelled request matches the one T3 holds.
REASON=$(node -e 'process.stdout.write(process.argv[1].trim())' "$REASON") || usage
[ -n "$REASON" ] && [ "${#REASON}" -le 500 ] || usage

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source t3code >/dev/null 2>&1 || { say "error: the t3code adapter did not load"; exit 2; }

# registry <verb> [args...]: one restart-registry call. On success sets
# PENDING (true|false), OURS (true when the pending reason is exactly
# REASON), ACTIVE (turns in flight), DRAINED (true|false), STARTED (the
# server's start time), and OTHER (the pending reason, JSON-quoted, when it
# is not ours); on failure sets FAILURE to the helper's last stderr line.
registry() {
  local out errf fields
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-t3-restart-request.XXXXXX") || { FAILURE="cannot create a temporary file"; return 1; }
  out=$(fm_backend_t3code_mcp "$@" 2>"$errf")
  FAILURE=$(tail -n 1 "$errf" 2>/dev/null)
  rm -f "$errf"
  fields=$(printf '%s' "$out" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true) process.exit(1);
const ours = d.pending === true && d.reason === process.argv[1];
process.stdout.write([d.pending, ours, d.activeTurns, d.drained, d.serverStartedAt, ours || !d.pending ? "" : JSON.stringify(d.reason)].join("\n"));
' "$REASON") || { [ -n "$FAILURE" ] || FAILURE="T3 gave no readable answer"; return 1; }
  PENDING=$(printf '%s\n' "$fields" | sed -n 1p)
  OURS=$(printf '%s\n' "$fields" | sed -n 2p)
  ACTIVE=$(printf '%s\n' "$fields" | sed -n 3p)
  DRAINED=$(printf '%s\n' "$fields" | sed -n 4p)
  STARTED=$(printf '%s\n' "$fields" | sed -n 5p)
  OTHER=$(printf '%s\n' "$fields" | sed -n '6,$p')
  FAILURE=''
}

# cancel_ours: cancel the pending request while it is still ours. Returns 0
# when no request of ours remains.
cancel_ours() {
  registry restart-status || return 1
  [ "$OURS" = true ] || return 0
  registry restart-cancel || return 1
  [ "$PENDING" = false ]
}

if [ "$VERB" = cancel ]; then
  if cancel_ours; then
    say "no restart request for \"$REASON\" is pending"
    exit 0
  fi
  say "error: could not cancel the restart request for \"$REASON\": ${FAILURE:-T3 still reports it pending}"
  exit 2
fi

# --- drain -------------------------------------------------------------------

MINE=0

# A signal before drained: cancel from a process outside this run's process
# group and session, so the group KILL that follows a retire's TERM cannot
# stop it, then exit as the signal.
on_signal() {
  trap - TERM INT HUP
  if [ "$MINE" = 1 ]; then
    say "stopped before T3 drained; cancelling the restart request for \"$REASON\""
    # shellcheck disable=SC2016 # Perl code, not shell.
    perl -MPOSIX -e '
      defined(my $p = fork) or exit 1;
      if ($p) { waitpid($p, 0); exit($? >> 8); }
      POSIX::setsid() or POSIX::_exit(1);
      defined(my $q = fork) or POSIX::_exit(1);
      POSIX::_exit(0) if $q;
      open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">&", \*STDOUT);
      POSIX::close($_) for 3 .. 255;
      exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
    ' "$BASH" "$SELF" cancel --reason "$REASON" || true
  fi
  exit $((128 + $1))
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT
trap 'on_signal 1' HUP

# give_up <exit> <message>: cancel this run's request, then report.
give_up() {
  if [ "$MINE" = 1 ] && ! cancel_ours; then
    say "$2; cancelling the request also failed (${FAILURE:-T3 still reports it pending}), so T3 may still hold messages: run bin/fm-t3-restart-request.sh cancel --reason \"$REASON\""
    exit "$1"
  fi
  say "$2"
  exit "$1"
}

registry restart-status || { say "error: cannot read T3's restart registry: $FAILURE"; exit 2; }
if [ "$PENDING" = true ] && [ "$OURS" != true ]; then
  say "another restart is already pending (reason $OTHER); nothing requested"
  exit 4
fi
if [ "$PENDING" = true ]; then
  MINE=1
  say "adopted the pending restart request for \"$REASON\""
else
  # Ours from the moment it is sent: a stop or failure while T3 answers must
  # still cancel it, and cancel_ours touches only a request with this reason.
  MINE=1
  registry restart-request --reason "$REASON" || give_up 2 "error: could not request the restart: $FAILURE"
  say "requested the restart (\"$REASON\"); T3 now holds new messages"
fi
SERVER=$STARTED
DEADLINE=$(( $(date +%s) + WITHIN ))
FAILURES=0

while :; do
  if [ "$PENDING" = true ] && [ "$OURS" = true ] && [ "$DRAINED" = true ]; then
    say "drained: every turn has finished; restart T3 now"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    give_up 1 "T3 did not drain within ${WITHIN}s (${ACTIVE} turn(s) still running); restart request cancelled and held messages released"
  fi
  sleep "$INTERVAL"
  if ! registry restart-status; then
    FAILURES=$((FAILURES + 1))
    [ "$FAILURES" -lt 6 ] || give_up 2 "error: cannot read T3's restart registry: $FAILURE"
    continue
  fi
  FAILURES=0
  if [ "$STARTED" != "$SERVER" ]; then
    MINE=0
    say "T3 restarted on its own before it drained, which ended the request; do not restart it again"
    exit 3
  fi
  if [ "$PENDING" != true ]; then
    MINE=0
    say "the restart request was cancelled in T3 before it drained; do not restart"
    exit 3
  fi
  if [ "$OURS" != true ]; then
    MINE=0
    say "the restart request was replaced in T3 (reason now $OTHER); do not restart"
    exit 3
  fi
done
