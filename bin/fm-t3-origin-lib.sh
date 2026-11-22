#!/usr/bin/env bash
# fm-t3-origin-lib.sh - where a Firstmate action's work comes from, for T3
# Code's Usage.
#
# Firstmate does not decide where work counts. At each durable boundary it
# records an origin reference, the T3 thread the work comes from and when:
#   {"threadId":"<T3 thread id>","at":"<ISO time>"}       (at optional)
# which is exactly what T3's fromThread takes, so it is passed through
# untouched, and T3 turns it into a label when the work launches or the claim
# is made (docs/t3code-backend.md "Where work comes from"). Writing one needs
# no T3 call: the thread is $T3CODE_THREAD_ID and the time is now. This
# library is the one owner of those references:
#   - bin/fm-spawn.sh sends "this thread, now" on the worker's launch and
#     records nothing, since the thread carries its birth; with --upkeep,
#     --journal or --incident it sends that word instead (below);
#   - bin/fm-send.sh records it in the steer's inbox record (from-thread=), and
#     every doorbell for that record sends it (bin/fm-task-inbox-lib.sh);
#   - bin/fm-inbox.sh note records the writer's own thread and time
#     (from-thread=), which the wake about that note claims;
#   - bin/fm-procevent-when.sh arm records it in the follow-up's spec
#     (from_thread=), which the wake about its fired result claims;
#   - bin/fm-tasks-axi.sh add records it as state/<id>.queued-origin, which
#     the item's first launch sends, whatever turn launches it;
#   - a wake about a task claims with that task's own thread and no time
#     (fm_t3_origin_of_task): where that task counts now;
#   - a landing (bin/fm-merge-local.sh, bin/fm-merge-outcome-lib.sh) keeps
#     the landed task's thread as state/t3-landed-origin, which
#     bin/fm-t3-restart-request.sh sends.
# bin/backends/t3code.sh sends FM_T3_FROM_THREAD when it holds a JSON value
# and never resolves one itself, so a re-ring or any other send outside these
# boundaries carries one only when its caller hands one in.
#
# Three origins are words, labels rather than references
# (docs/t3code-backend.md "Where work comes from"):
#   upkeep    work Firstmate runs because of a process set up on the
#             computer, such as the bedtime routine, which counts to the
#             computer as upkeep whichever turn starts it;
#   journal   work from a voice journal's items started outside the
#             journal's own filing turn, which counts to the phone as
#             journal work whichever turn starts it;
#   incident  a fix Firstmate starts on its own from a production alert,
#             which counts to the computer as incident work whichever turn
#             starts it.
# Only bin/fm-spawn.sh --upkeep, --journal or --incident writes one, as a
# deferred item's queued origin (fm_t3_origin_queue_label), so the item's
# later launch is that too; a launch sends it as T3's label of that name,
# and a wake about the item, before it has a thread, claims the computer,
# the phone, or incident work (bin/fm-t3-usage-claim.sh).
#
# Things written before this library existed still carry a cause, the JSON
# {"threadId","runId"?,"messageId"} T3's causedBy takes: a queued item's
# state/<id>.queued-cause, a note's caused-by=, a steer's caused-by=, and a
# follow-up's caused_by=. Each is passed through as causedBy unchanged, with
# no lookup, until it fires (fm_t3_origin_flag tells the two shapes apart).
#
# FM_T3_FROM_THREAD, read at each boundary:
#   unset or empty  this thread, now: {"threadId":$T3CODE_THREAD_ID,"at":now},
#                   or nothing when this process runs in no T3 thread;
#   off             no reference;
#   a reference     that reference as given, such as the one a note recorded;
#                   T3 checks the thread when it is sent.
# Anything else is refused (status 2) before the boundary acts.

_FM_T3_ORIGIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_t3_origin_here: the reference for this thread, now, or nothing when this
# process runs in no T3 thread.
fm_t3_origin_here() {
  [ -n "${T3CODE_THREAD_ID:-}" ] && command -v node >/dev/null 2>&1 || return 0
  node -e 'process.stdout.write(JSON.stringify({ threadId: process.env.T3CODE_THREAD_ID, at: new Date().toISOString() }))' 2>/dev/null || true
}

# fm_t3_origin_resolve -> the reference on stdout, or nothing (the header's
# FM_T3_FROM_THREAD rule). Status 2 when FM_T3_FROM_THREAD is malformed.
fm_t3_origin_resolve() {
  local given=${FM_T3_FROM_THREAD:-}
  case "$given" in
    off) return 0 ;;
    '') fm_t3_origin_here; return 0 ;;
  esac
  if ! node "$_FM_T3_ORIGIN_LIB_DIR/fm-t3-mcp.mjs" from-thread-check --json "$given" 2>/dev/null \
    | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(JSON.stringify(d.fromThread));' 2>/dev/null; then
    echo "error: FM_T3_FROM_THREAD must be off or a JSON object of a threadId and an optional zoned ISO time at (bin/fm-t3-origin-lib.sh)" >&2
    return 2
  fi
}

# fm_t3_origin_flag <value>: the helper flag that sends <value>: --caused-by
# for a cause written before references existed (it names a messageId),
# --from-thread for a reference.
fm_t3_origin_flag() {
  case "$1" in
    *'"messageId"'*) printf '%s' --caused-by ;;
    *) printf '%s' --from-thread ;;
  esac
}

# _fm_t3_origin_task_id_ok <task-id>: a task id that names a file in state/.
_fm_t3_origin_task_id_ok() {
  case "$1" in ''|.*|*/*|*[[:space:]]*) return 1 ;; esac
  return 0
}

# _fm_t3_origin_first_line <file>: the file's first line, or nothing.
_fm_t3_origin_first_line() {
  local line=''
  [ -f "$1" ] || return 0
  IFS= read -r line < "$1" 2>/dev/null || true
  printf '%s' "$line"
}

# _fm_t3_origin_write <file> <line>: replace <file> with <line>, atomically.
# Best effort: a failed write leaves nothing behind.
_fm_t3_origin_write() {
  local tmp="${1%/*}/.${1##*/}.$$"
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# fm_t3_origin_queue_record <state-dir> <task-id>: record the reference of the
# turn queueing backlog item <task-id> (fm_t3_origin_resolve's rule) as
# state/<task-id>.queued-origin. Best effort: no reference, a malformed
# FM_T3_FROM_THREAD, or a failed write records nothing and never fails.
fm_t3_origin_queue_record() {
  local state=$1 id=$2 ref
  _fm_t3_origin_task_id_ok "$id" && [ -d "$state" ] || return 0
  ref=$(fm_t3_origin_resolve 2>/dev/null) || return 0
  [ -n "$ref" ] || return 0
  _fm_t3_origin_write "$state/$id.queued-origin" "$ref"
  return 0
}

# fm_t3_origin_queue_label <state-dir> <task-id> <upkeep|journal|incident>:
# record that label as backlog item <task-id>'s queued origin (the header's
# label rule), replacing any reference. Any other word records nothing. Best
# effort, like fm_t3_origin_queue_record.
fm_t3_origin_queue_label() {
  _fm_t3_origin_task_id_ok "$2" && [ -d "$1" ] || return 0
  case "${3:-}" in upkeep|journal|incident) ;; *) return 0 ;; esac
  _fm_t3_origin_write "$1/$2.queued-origin" "$3"
  return 0
}

# fm_t3_origin_queued <state-dir> <task-id>: what backlog item <task-id> was
# queued with: its reference or label, else a cause recorded before
# references existed, else nothing.
fm_t3_origin_queued() {
  local value
  _fm_t3_origin_task_id_ok "$2" || return 0
  value=$(_fm_t3_origin_first_line "$1/$2.queued-origin")
  [ -n "$value" ] || value=$(_fm_t3_origin_first_line "$1/$2.queued-cause")
  printf '%s' "$value"
}

# fm_t3_origin_queue_forget <state-dir> <task-id>: drop those records.
fm_t3_origin_queue_forget() {
  _fm_t3_origin_task_id_ok "$2" || return 0
  rm -f "$1/$2.queued-origin" "$1/$2.queued-cause" 2>/dev/null || true
}

# fm_t3_origin_of_task <state-dir> <task-id>: where task <task-id>'s work
# counts now: {"threadId":<its t3_thread_id>}, with no time; for a backlog
# item with no thread yet, what it was queued with (possibly a label); else
# nothing.
fm_t3_origin_of_task() {
  local state=$1 id=$2 line thread=''
  _fm_t3_origin_task_id_ok "$id" || return 0
  if [ -f "$state/$id.meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in t3_thread_id=*) thread=${line#t3_thread_id=} ;; esac
    done < "$state/$id.meta" 2>/dev/null || true
  fi
  case "$thread" in
    '') fm_t3_origin_queued "$state" "$id" ;;
    *[!A-Za-z0-9:._-]*) ;;
    *) printf '{"threadId":"%s"}' "$thread" ;;
  esac
}

# fm_t3_origin_landed_record <state-dir> <task-id>: <task-id>'s work just
# landed, so its thread (possibly none) becomes the latest landed origin, one
# line "<epoch> TAB <task-id> TAB <reference-or-empty>" in
# state/t3-landed-origin. Best effort; never fails the landing.
fm_t3_origin_landed_record() {
  local state=$1 id=$2 ref
  _fm_t3_origin_task_id_ok "$id" && [ -d "$state" ] || return 0
  ref=$(fm_t3_origin_of_task "$state" "$id")
  # Only a reference names where a restart's work counts.
  case "$ref" in *'"messageId"'*|upkeep|journal|incident) ref= ;; esac
  _fm_t3_origin_write "$state/t3-landed-origin" "$(printf '%s\t%s\t%s' "$(date +%s)" "$id" "$ref")"
  # The cause file a landing kept before references existed.
  rm -f "$state/t3-landed-cause" 2>/dev/null || true
  return 0
}

# fm_t3_origin_landed <state-dir>: the latest landed task's reference, or
# nothing.
fm_t3_origin_landed() {
  local line tab
  tab=$(printf '\t')
  line=$(_fm_t3_origin_first_line "$1/t3-landed-origin")
  case "$line" in *"$tab"*"$tab"*) printf '%s' "${line##*"$tab"}" ;; esac
}
