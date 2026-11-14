#!/usr/bin/env bash
# fm-usage-limit.sh - act on a T3 worker stopped by a provider usage limit.
# Usage:
#   fm-usage-limit.sh move <task-id> --instance <instance-id>
#   fm-usage-limit.sh resume <instance-id>
#   fm-usage-limit.sh list
#
# move: carry out firstmate's move of a stopped worker to another account, at
#   once. It rebinds the task's T3 thread to provider instance <instance-id>
#   with the same model and options, effort included, checked against T3's
#   catalog and proven by reading the binding back (bin/fm-t3-mcp.mjs move owns
#   the checks and refusals; a running, archived, or missing thread is
#   refused), records the move in the task's usage-limit record
#   (bin/fm-usage-limit-lib.sh), then sends the continuation through the
#   ordinary steer (bin/fm-send.sh), which rings a failed thread. Choosing the
#   instance is firstmate's, under the captain's account rules; this command
#   never chooses or waits. A moved worker stays on its new account.
# resume: for the captain's word that the account <instance-id> was reset,
#   ring every worker whose record says it is stopped on that account (not
#   moved since) and whose thread still reads failed, through the ordinary
#   steer, and note resumed_at. Nothing detects a reset on its own.
# list: one line per usage-limit record in this home: task, account, window,
#   reset (UTC), and where it was moved, or that it was resumed.
#
# Needs an explicit FM_HOME, as bin/fm-send.sh does. Exit 0 when everything
# asked was done; 1 when a move, record, or steer failed (each says which);
# 2 invalid use; a move refusal exits with bin/fm-t3-mcp.mjs's own status (3
# T3 refused the change, 4 a check refused it; nothing was moved either way).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
case "$1" in -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-usage-limit refuses to act without an explicit firstmate home" >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-usage-limit-lib.sh
. "$SCRIPT_DIR/fm-usage-limit-lib.sh"

MOVE_TEXT="Your last run stopped on a provider usage limit, so firstmate moved this thread to another account. Continue the task from where you left off; your brief, status file and work on disk are unchanged."
RESUME_TEXT="The account your last run stopped on has been reset. Continue the task from where you left off."

# t3_thread_of <task>: the task's T3 thread, refusing a task this home does not
# record on the t3code backend.
t3_thread_of() {
  local meta="$STATE/$1.meta" backend thread
  [ -f "$meta" ] || { echo "error: no task $1 recorded in $STATE" >&2; return 1; }
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = t3code ] || { echo "error: $1 runs on backend=$backend; only a T3 Code worker can be moved between accounts" >&2; return 1; }
  thread=$(fm_backend_target_of_meta "$meta")
  [ -n "$thread" ] || { echo "error: $1 records no T3 thread" >&2; return 1; }
  printf '%s' "$thread"
}

steer() {  # <task> <text>
  "$SCRIPT_DIR/fm-send.sh" "$1" "$2"
}

cmd_move() {
  local id thread target out rc=0 rec from
  [ "$#" -eq 3 ] && [ "$2" = --instance ] && [ -n "$3" ] || usage
  id=$1 target=$3
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: '$id' is not a task id" >&2; exit 2 ;; esac
  thread=$(t3_thread_of "$id") || exit 1
  fm_backend_source t3code || exit 1
  out=$(fm_backend_t3code_move "$thread" "$target") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
    echo "error: $id was not moved to $target" >&2
    exit "$rc"
  fi
  from=$(printf '%s' "$out" | fm_backend_t3code_json_get from) || from=
  rec=$(fm_usage_limit_path "$STATE" "$id")
  if [ ! -f "$rec" ]; then
    printf 'thread=%s\ninstance=%s\nat=%s\n' "$thread" "$from" "$(date +%s)" > "$rec" || {
      echo "error: $id moved from ${from:-its account} to $target, but the move could not be recorded at $rec; the continuation was not sent" >&2
      exit 1
    }
  fi
  if ! { fm_usage_limit_note "$rec" moved_to "$target" && fm_usage_limit_note "$rec" moved_at "$(date +%s)"; }; then
    echo "error: $id moved from ${from:-its account} to $target, but the move could not be recorded at $rec; the continuation was not sent" >&2
    exit 1
  fi
  if ! steer "$id" "$MOVE_TEXT"; then
    echo "error: $id moved from ${from:-its account} to $target, but the continuation steer failed; resend it with bin/fm-send.sh" >&2
    exit 1
  fi
  echo "moved $id from ${from:-its account} to $target and sent the continuation"
}

cmd_resume() {
  local account rec id thread meta n=0 failed=0
  [ "$#" -eq 1 ] && [ -n "$1" ] || usage
  account=$1
  fm_backend_source t3code || exit 1
  for rec in "$STATE"/*.usage-limit; do
    [ -f "$rec" ] || continue
    id=$(basename "$rec" .usage-limit)
    [ "$(fm_usage_limit_get "$rec" instance)" = "$account" ] || continue
    [ -z "$(fm_usage_limit_get "$rec" moved_to)" ] || continue
    meta="$STATE/$id.meta"
    [ -f "$meta" ] || continue
    [ "$(fm_backend_of_meta "$meta")" = t3code ] || continue
    thread=$(fm_backend_target_of_meta "$meta")
    [ -n "$thread" ] && [ "$thread" = "$(fm_usage_limit_get "$rec" thread)" ] || continue
    if [ "$(fm_backend_t3code_probe "$thread")" != error ]; then
      echo "skipped $id: its thread no longer reads stopped"
      continue
    fi
    n=$((n + 1))
    if steer "$id" "$RESUME_TEXT"; then
      fm_usage_limit_note "$rec" resumed_at "$(date +%s)" || echo "error: $id was rung but resumed_at could not be recorded in $rec" >&2
      echo "resumed $id"
    else
      echo "error: the resume steer to $id failed; resend it with bin/fm-send.sh" >&2
      failed=1
    fi
  done
  [ "$n" -gt 0 ] || echo "no worker is recorded as stopped on account $account"
  return "$failed"
}

cmd_list() {
  local rec id moved state
  [ "$#" -eq 0 ] || usage
  for rec in "$STATE"/*.usage-limit; do
    [ -f "$rec" ] || continue
    id=$(basename "$rec" .usage-limit)
    moved=$(fm_usage_limit_get "$rec" moved_to)
    if [ -n "$moved" ]; then
      state="moved_to=$moved"
    elif [ -n "$(fm_usage_limit_get "$rec" resumed_at)" ]; then
      state=resumed
    else
      state=stopped
    fi
    printf '%s\taccount=%s\twindow=%s\tresets=%s\t%s\n' "$id" "$(fm_usage_limit_get "$rec" instance)" \
      "$(fm_usage_limit_get "$rec" window)" "$(fm_usage_limit_reset_text "$(fm_usage_limit_get "$rec" reset)")" "$state"
  done
}

sub=$1
shift
case "$sub" in
  move) cmd_move "$@" ;;
  resume) cmd_resume "$@" ;;
  list) cmd_list "$@" ;;
  *) usage ;;
esac
