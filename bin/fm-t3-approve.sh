#!/usr/bin/env bash
# Answer a T3 Code worker's pending permission approval as the supervisor.
# Usage: fm-t3-approve.sh <task-id> <request-id> allow|deny [--feedback <text>]
#   Allows or denies that approval through T3's pending-request respond tool,
#   exactly as T3 Code's own buttons would. --feedback, the text the worker
#   sees, is accepted only with deny. bin/fm-t3-answer.sh <task-id> lists the
#   pending approvals (approvalRequests) with their command or file, reason,
#   and override.
# Refuses (exit 4) when the T3 server does not advertise approvalResponses or
# the request is not a pending approval; the fallback is to interrupt the
# worker with bin/fm-control.sh and steer it with bin/fm-send.sh. On success
# appends one JSON line (at, taskId, threadId, requestId, decision, feedback,
# approval) to the task's durable record data/<task-id>/t3-approvals.jsonl.
# The task must be recorded in this home with backend=t3code. The decision is
# the supervisor's own, never the worker's (stuck-crewmate-recovery owns the
# policy); bin/backends/t3code.sh owns the transport.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -eq 3 ] || [ "$#" -eq 5 ] || usage
ID=$1 REQUEST=$2 DECISION=$3
FEEDBACK=
HAS_FEEDBACK=0
if [ "$#" -eq 5 ]; then
  [ "$4" = --feedback ] || usage
  FEEDBACK=$5
  HAS_FEEDBACK=1
fi
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: '$ID' is not a task id" >&2; exit 2 ;; esac
[ -n "$REQUEST" ] || usage
case "$DECISION" in allow|deny) ;; *) echo "error: decision must be allow or deny, not '$DECISION'" >&2; exit 2 ;; esac
if [ "$HAS_FEEDBACK" = 1 ] && [ "$DECISION" != deny ]; then
  echo "error: --feedback is the text the worker sees on a deny; it is accepted only with deny" >&2
  exit 2
fi
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task $ID recorded in $STATE" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = t3code ] || { echo "error: $ID runs on backend=$BACKEND; only T3 Code threads have pending approvals to answer" >&2; exit 1; }
THREAD=$(fm_backend_target_of_meta "$META")
[ -n "$THREAD" ] || { echo "error: $ID records no T3 thread" >&2; exit 1; }
fm_backend_source t3code || exit 1

FEEDBACK_FILE=
trap '[ -z "$FEEDBACK_FILE" ] || rm -f "$FEEDBACK_FILE"' EXIT
if [ "$HAS_FEEDBACK" = 1 ]; then
  FEEDBACK_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-t3-approve.XXXXXX")
  printf '%s' "$FEEDBACK" > "$FEEDBACK_FILE"
fi

rc=0
OUT=$(fm_backend_t3code_approve_request "$THREAD" "$REQUEST" "$DECISION" "$FEEDBACK_FILE") || rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$OUT"
  if [ "$rc" -eq 4 ]; then
    echo "error: approval $REQUEST was not answered; when this T3 cannot answer approvals, interrupt the worker with bin/fm-control.sh $ID interrupt and steer it with bin/fm-send.sh" >&2
  fi
  exit "$rc"
fi

mkdir -p "$DATA/$ID"
printf '%s' "$OUT" | node -e '
const out = JSON.parse(require("fs").readFileSync(0, "utf8"));
const [taskId] = process.argv.slice(1);
const line = { at: new Date().toISOString(), taskId, threadId: out.threadId, requestId: out.requestId, decision: out.decision, feedback: out.feedback ?? null, approval: out.approval ?? null };
process.stdout.write(JSON.stringify(line) + "\n");
' "$ID" >> "$DATA/$ID/t3-approvals.jsonl" || {
  echo "error: approval $REQUEST was answered ($DECISION) but could not be recorded in $DATA/$ID/t3-approvals.jsonl" >&2
  exit 1
}
echo "answered $ID approval $REQUEST on T3 thread $THREAD: $DECISION"
