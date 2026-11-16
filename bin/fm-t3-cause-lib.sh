#!/usr/bin/env bash
# fm-t3-cause-lib.sh - the T3 prompt that caused a Firstmate action.
#
# T3 Code's Usage counts a worker's tokens to the phone or computer prompt
# that started it by following causedBy: the prompt a launch or a message
# names as its cause (docs/t3code-backend.md "Work causes"). This library is
# the one place Firstmate decides that cause at its durable boundaries:
#   - bin/fm-spawn.sh records it in the task record (caused_by=) and sends it
#     on the worker's launch and its brief; a relaunch reuses the recorded one;
#   - bin/fm-send.sh records it in the steer's inbox record (caused-by=), and
#     every doorbell for that record carries it (bin/fm-task-inbox-lib.sh);
#   - bin/fm-inbox.sh note records the prompt that made an agent write a note
#     (caused-by=), so firstmate can name it when it acts on that note;
#   - bin/fm-procevent-when.sh arm records the prompt behind a condition-then-
#     action follow-up in its spec (caused_by=), which bin/fm-wake-drain.sh
#     claims when that follow-up's fired result wakes firstmate;
#   - bin/fm-tasks-axi.sh add records the prompt that queued a backlog item
#     (state/<id>.queued-cause), which bin/fm-spawn.sh sends when it launches
#     that item later, from whatever turn, and then removes;
#   - a landing (bin/fm-merge-local.sh, bin/fm-merge-outcome-lib.sh) keeps
#     the landed task's cause as the latest landed cause
#     (state/t3-landed-cause), which bin/fm-t3-restart-request.sh names.
# bin/fm-t3-usage-claim.sh reads these records to claim usage T3 cannot trace.
# A cause is the compact JSON {"threadId","runId"?,"messageId"} T3 takes.
# bin/backends/t3code.sh sends FM_T3CODE_CAUSED_BY as causedBy when it holds
# such JSON and never resolves one itself, so a re-ring or any other send
# outside these boundaries carries a cause only when its caller hands one in.
#
# FM_T3CODE_CAUSED_BY, read at each boundary:
#   unset or empty  the prompt of the calling agent's current T3 turn: the
#                   message that started it (a wake's notification
#                   included), or the latest prompt the turn received before
#                   the command began (bin/fm-t3-mcp.mjs cause owns that rule,
#                   which answers nothing rather than guess), or nothing when this process
#                   runs in no T3 thread ($T3CODE_THREAD_ID unset), the home
#                   has no T3 credential, or T3 cannot be read;
#   off             no cause;
#   a cause JSON    that cause as given, such as an earlier prompt of a turn
#                   that received several, or an action a recorded note caused; T3 checks
#                   the ids when the cause is sent.
# Anything else is refused (status 2) before the boundary acts.
# A cause that could not be established is left out silently, and the action
# goes ahead without one. Message text is never read.

_FM_T3_CAUSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_t3_cause_resolve <token-file> -> the cause JSON on stdout, or nothing.
# Status 2 when FM_T3CODE_CAUSED_BY is malformed; 0 otherwise.
fm_t3_cause_resolve() {
  local token=$1 given=${FM_T3CODE_CAUSED_BY:-} out
  case "$given" in
    off) return 0 ;;
    '') ;;
    *)
      if ! out=$(node "$_FM_T3_CAUSE_LIB_DIR/fm-t3-mcp.mjs" cause-check --json "$given" 2>/dev/null); then
        echo "error: FM_T3CODE_CAUSED_BY must be off or a JSON object of exactly threadId, messageId, and optional runId (bin/fm-t3-cause-lib.sh)" >&2
        return 2
      fi
      _fm_t3_cause_field "$out"
      return 0
      ;;
  esac
  if [ -z "${T3CODE_THREAD_ID:-}" ] || [ ! -f "$token" ] || ! command -v node >/dev/null 2>&1; then
    return 0
  fi
  out=$(node "$_FM_T3_CAUSE_LIB_DIR/fm-t3-mcp.mjs" cause --thread "$T3CODE_THREAD_ID" --token-file "$token" 2>/dev/null) || return 0
  _fm_t3_cause_field "$out" || true
  return 0
}

# _fm_t3_cause_field <helper-json>: the causedBy JSON; status 1 without one.
_fm_t3_cause_field() {
  printf '%s' "$1" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true || !d.causedBy) process.exit(1);
process.stdout.write(JSON.stringify(d.causedBy));
'
}

# _fm_t3_cause_task_id_ok <task-id>: a task id that names a file in state/.
_fm_t3_cause_task_id_ok() {
  case "$1" in ''|.*|*/*|*[[:space:]]*) return 1 ;; esac
  return 0
}

# _fm_t3_cause_first_line <file>: the file's first line, or nothing.
_fm_t3_cause_first_line() {
  local line=''
  [ -f "$1" ] || return 0
  IFS= read -r line < "$1" 2>/dev/null || true
  printf '%s' "$line"
}

# fm_t3_cause_queue_record <state-dir> <task-id> <token-file>: record the cause
# of the turn queueing backlog item <task-id> (fm_t3_cause_resolve's rule) as
# state/<task-id>.queued-cause. Best effort: no cause, a malformed
# FM_T3CODE_CAUSED_BY, or a failed write records nothing and never fails.
fm_t3_cause_queue_record() {
  local state=$1 id=$2 cause tmp
  _fm_t3_cause_task_id_ok "$id" && [ -d "$state" ] || return 0
  cause=$(fm_t3_cause_resolve "$3" 2>/dev/null) || return 0
  [ -n "$cause" ] || return 0
  tmp="$state/.$id.queued-cause.$$"
  if printf '%s\n' "$cause" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state/$id.queued-cause" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# fm_t3_cause_queued <state-dir> <task-id>: the cause recorded when backlog
# item <task-id> was queued, or nothing.
fm_t3_cause_queued() {
  _fm_t3_cause_task_id_ok "$2" || return 0
  _fm_t3_cause_first_line "$1/$2.queued-cause"
}

# fm_t3_cause_queue_forget <state-dir> <task-id>: drop that record.
fm_t3_cause_queue_forget() {
  _fm_t3_cause_task_id_ok "$2" || return 0
  rm -f "$1/$2.queued-cause" 2>/dev/null || true
}

# fm_t3_cause_of_task <state-dir> <task-id>: the cause behind task <task-id>:
# its record's caused_by= (the last one), else the cause recorded when its
# backlog item was queued, else nothing.
fm_t3_cause_of_task() {
  local state=$1 id=$2 line value=''
  _fm_t3_cause_task_id_ok "$id" || return 0
  if [ -f "$state/$id.meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in caused_by=*) value=${line#caused_by=} ;; esac
    done < "$state/$id.meta" 2>/dev/null || true
  fi
  [ -n "$value" ] || value=$(fm_t3_cause_queued "$state" "$id")
  printf '%s' "$value"
}

# fm_t3_cause_landed_record <state-dir> <task-id>: <task-id>'s work just
# landed, so its cause (possibly none) becomes the latest landed cause, one
# line "<epoch> TAB <task-id> TAB <cause-json-or-empty>" in
# state/t3-landed-cause. Best effort; never fails the landing.
fm_t3_cause_landed_record() {
  local state=$1 id=$2 tmp
  _fm_t3_cause_task_id_ok "$id" && [ -d "$state" ] || return 0
  tmp="$state/.t3-landed-cause.$$"
  if printf '%s\t%s\t%s\n' "$(date +%s)" "$id" "$(fm_t3_cause_of_task "$state" "$id")" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state/t3-landed-cause" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# fm_t3_cause_landed <state-dir>: the latest landed task's cause, or nothing.
fm_t3_cause_landed() {
  local line tab
  tab=$(printf '\t')
  line=$(_fm_t3_cause_first_line "$1/t3-landed-cause")
  case "$line" in *"$tab"*"$tab"*) printf '%s' "${line##*"$tab"}" ;; esac
}
