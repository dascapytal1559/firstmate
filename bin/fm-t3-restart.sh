#!/usr/bin/env bash
# fm-t3-restart.sh - reconcile this home's T3 workers after a T3 Code server
# restart (docs/t3code-backend.md "Server restart").
#
# T3 owns the restart event: it resumes the runs it cut where it can, wakes a
# worker whose marked background wait it cut, leaves every other thread asleep,
# and tells every pinned coordinator to run session start again. What it cannot
# see is a worker's last `working:` or `paused:` line, which still reads as
# current after the session behind it ended. This script reconciles only the
# workers T3 itself shows as cut off. The restart identity is T3's
# serverStartedAt (bin/fm-t3-mcp.mjs status), set once per server process.
#
# Usage:
#   fm-t3-restart.sh check
#     Read-only verdict, one line:
#       t3-restart: off        this home has no config/t3code-token
#       t3-restart: unknown    T3's restart identity cannot be read
#                              (unreachable, refused, or no t3_restart_status)
#       t3-restart: first      no identity recorded yet
#       t3-restart: same       the recorded identity is current
#       t3-restart: restarted  the server restarted since it was recorded
#   fm-t3-restart.sh recover
#     The locked session start runs this (bin/fm-session-start.sh). Silent
#     unless it has something to report. On first, records the identity. On
#     restarted, it goes through every ship or scout recorded on
#     backend=t3code whose current claim is `working:`, `paused:`, or nothing
#     yet, and reads that worker's thread status from T3:
#       - A turn T3 shows as cut off and not picked up again (the status word
#         `interrupted`: cancelled, interrupted, or rolled back) gets the
#         marker below and one recovery steer through bin/fm-send.sh, whose
#         T3 doorbell reopens the idle session.
#       - A thread the server no longer has, or has archived, is reported and
#         not rung.
#       - A thread that cannot be read leaves the restart unhandled, so the
#         next session start retries.
#       - Every other worker is left asleep with its last claim still
#         trusted: a turn T3 resumed or woke (the thread no longer reads cut),
#         a failed run (usage-limit handling owns it), and an idle worker that
#         lost nothing, such as one waiting on the captain, on firstmate, or
#         on a detached fm-job.sh job.
#     The new identity is recorded only when every thread was readable and
#     every steer was recorded, so a rerun retries exactly those workers. A
#     worker whose claim is an open decision, a captain-held wait, or a
#     terminal line is not looked at: its claim stays true, and firstmate's
#     own answer reopens it.
#     Every recover first pins this home's own live T3 thread as its
#     project's coordinator where the server offers it (bin/fm-t3-mcp.mjs
#     pin-coordinator), so T3's note reaches it after every restart; that
#     pin is silent and never stops recovery.
#
# Marker (written only for a steered worker): <state>/<id>.t3-restart, owned
# here, removed by teardown.
#   server=<the restarted server's identity>
#   offset=<the status file's byte size when the restart was handled>
#   doorbell=pending|sent|failed   (whether the recovery steer was recorded)
# While no status event other than a resolved line follows that offset, the
# worker has not answered: status_restart_unanswered in bin/fm-classify-lib.sh
# reads it, so supervisors stop treating the worker's earlier pause as a
# declared wait and bin/fm-crew-state.sh reports its earlier working or paused
# claim as unknown. The worker's next status line is its answer.
#
# The record of the last handled identity is <state>/.t3code-server-started.
#
# Every verb exits 0; usage errors exit 2. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.t3code-server-started"

usage() {
  sed -n '12,49p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
VERB=$1
case "$VERB" in check|recover) ;; *) usage ;; esac

if [ ! -e "$CONFIG/t3code-token" ] && [ ! -L "$CONFIG/t3code-token" ]; then
  [ "$VERB" = recover ] || echo "t3-restart: off"
  exit 0
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
fm_backend_source t3code >/dev/null 2>&1 || {
  [ "$VERB" = recover ] || echo "t3-restart: unknown (the t3code adapter did not load)"
  exit 0
}

if [ "$VERB" = recover ] && HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
  fm_backend_t3code_mcp pin-coordinator --root "$HOME_REAL" >/dev/null 2>&1 || true
fi

CURRENT=$(fm_backend_t3code_mcp status 2>/dev/null | fm_backend_t3code_json_get serverStartedAt) || CURRENT=
RECORDED=
[ ! -f "$RECORD" ] || [ -L "$RECORD" ] || RECORDED=$(head -n 1 "$RECORD" 2>/dev/null)

if [ -z "$CURRENT" ]; then
  VERDICT=unknown
elif [ -z "$RECORDED" ]; then
  VERDICT=first
elif [ "$RECORDED" = "$CURRENT" ]; then
  VERDICT=same
else
  VERDICT=restarted
fi

record_current() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$CURRENT" > "$tmp" && mv -f "$tmp" "$RECORD"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

if [ "$VERB" = check ]; then
  echo "t3-restart: $VERDICT"
  exit 0
fi

case "$VERDICT" in
  unknown|same) exit 0 ;;
  first)
    record_current || echo "t3-restart: could not record the T3 server identity in $RECORD"
    exit 0
    ;;
esac

marker_value() {  # <marker> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

write_marker() {  # <marker> <offset> <doorbell>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf 'server=%s\noffset=%s\ndoorbell=%s\n' "$CURRENT" "$2" "$3" > "$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

STEER="Firstmate: the T3 server restarted at $CURRENT and ended your session, so anything that lived only in it is gone: background commands, waits, and monitors, and any command you ran in the foreground. A detached job you started with fm-job.sh is not one of them: it is still running or has already sent you its result, so check it with fm-job.sh status <your task id> and never rerun it; if it is still running, re-attach with fm-job.sh follow <your task id> <job> --from-end in the foreground. Check where your task really stands now: if you were waiting on something, check that condition directly, then continue or start the wait again; if you were mid-step, verify what actually finished before you go on. Then append one status line saying where you are (working, paused with its until, or your terminal state), because firstmate no longer trusts your earlier working or paused line until you do."

echo "t3-restart: the T3 server restarted at $CURRENT; it ended every T3 session, this one included."
FAILED=0
WOKEN=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$(fm_backend_of_meta "$meta")" = t3code ] || continue
  kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
  case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
  thread=$(fm_backend_target_of_meta "$meta")
  [ -n "$thread" ] || continue
  statusf="$STATE/$id.status"
  line=$(status_current_line "$statusf" "${kind:-ship}" 2>/dev/null)
  verb=$(status_line_verb "$line")
  if [ -n "$verb" ] && ! status_is_paused "$line"; then
    case "$verb" in working) ;; *) continue ;; esac
  fi
  marker="$STATE/$id.t3-restart"
  if [ -f "$marker" ] && [ "$(marker_value "$marker" server)" = "$CURRENT" ] \
    && [ "$(marker_value "$marker" doorbell)" = sent ]; then
    continue
  fi
  # T3 resumes or wakes the workers it means to, so a thread that still reads
  # cut off is the one nothing picked up again. Anything else lost nothing, or
  # is another owner's to recover.
  case "$(fm_backend_t3code_probe "$thread")" in
    interrupted) ;;
    archived|http-404)
      echo "t3-restart: $id: its T3 thread $thread is gone or archived; nothing to wake"
      continue
      ;;
    closing|http-failure)
      echo "t3-restart: $id: its T3 thread $thread could not be read; rerun bin/fm-t3-restart.sh recover"
      FAILED=1
      continue
      ;;
    *) continue ;;
  esac
  offset=0
  [ ! -f "$statusf" ] || offset=$(wc -c < "$statusf" | tr -d ' ')
  if ! write_marker "$marker" "$offset" pending; then
    echo "t3-restart: $id: could not write $marker; its earlier claims still read as current"
    FAILED=1
    continue
  fi
  if send_out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$id" "$STEER" 2>&1); then
    write_marker "$marker" "$offset" sent || true
    WOKEN=$((WOKEN + 1))
    echo "t3-restart: $id: sent the restart steer; its last claim (${line:-no status line yet}) is untrusted until it appends a new status line"
  else
    write_marker "$marker" "$offset" failed || true
    FAILED=1
    echo "t3-restart: $id: the restart steer was not recorded ($(printf '%s' "$send_out" | tail -n 1)); rerun bin/fm-t3-restart.sh recover"
  fi
done

if [ "$FAILED" -eq 0 ]; then
  record_current || echo "t3-restart: could not record the T3 server identity in $RECORD; the next session start repeats this recovery"
  [ "$WOKEN" -gt 0 ] || echo "t3-restart: no T3 worker needed a steer."
fi
exit 0
