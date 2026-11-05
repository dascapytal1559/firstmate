#!/usr/bin/env bash
# fm-t3-captain-label.sh - keep a live T3 worker's card status on "Waiting for
# captain" or "Testing" (docs/t3code-backend.md "Crew card status").
#
# Only Firstmate knows when a worker waits on the captain or sits in a
# no-mistakes run, so it says so in T3's crew card status label. The wait is a
# captain hold (bin/fm-captain-hold.sh) on the worker's own task, or on a task
# whose --origin is the worker; a worker's needs-decision line alone does not
# count, because firstmate settles most of those itself. Testing is a ship whose
# run bin/fm-crew-state.sh reads as working or parked, and a wait outranks it. A
# hold on a task with no live T3 worker has no card and records nothing, so
# other backends do nothing here.
#
# Usage:
#   fm-t3-captain-label.sh note <held-task-id> [<origin-id>]
#     bin/fm-captain-hold.sh hold runs this. For each named task that is a
#     recorded T3 ship or scout, records the hold. Touches no server.
#   fm-t3-captain-label.sh sync [--runs]
#     bin/fm-captain-hold.sh runs this after every hold, answer, and reconcile.
#     For each record, sets the label to match the holds still open and the
#     worker's run, and removes the record once the card is proven clear or the
#     worker or its thread is gone. bin/fm-watch.sh adds --runs about once a
#     minute, which first records every T3 ship with an active run.
#   fm-t3-captain-label.sh clear <worker-id>
#     bin/fm-teardown.sh runs this before it archives the thread: the label
#     comes off whatever the holds say, since the card is about to go.
#
# Record: <state>/t3-captain-wait/<worker-id>/ while that card may carry a
# label, holding one empty file per hold (<held-task-id>), so a hold and a sync
# never rewrite each other's entry. A record is written before its label.
#
# Sync is level-triggered and compares against the live thread, so it keeps no
# copy that could go stale: a label that failed or a server that was down
# converges on a later pass, and a record stays until its card is proven. The
# label is durable in T3, so a restart alone changes nothing. A hold or run
# whose state cannot be read leaves the card as it is. Label and record are
# display only: no selector, recovery, or T3 lineage reads them, and crew
# membership stays T3's crewOf.
#
# A T3 with no status label shows nothing: sync keeps the record quietly, so the
# card catches up once T3 is updated, and clear has nothing to take off.
#
# Exit: 0, or 1 when a label could not be set (a line on stdout says which; the
# record stays for the next pass); usage errors exit 2. A home with no
# config/t3code-token exits 0 at once. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WAITS="$STATE/t3-captain-wait"
WAITING_LABEL='Waiting for captain'
TESTING_LABEL='Testing'

usage() {
  sed -n '14,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB:$#:${1:-}" in
  note:1:*|note:2:*|sync:0:|sync:1:--runs|clear:1:*) ;;
  *) usage ;;
esac

[ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

worker_kind() {  # <task-id>
  local kind
  kind=$(sed -n 's/^kind=//p' "$STATE/$1.meta" | head -n 1)
  printf '%s' "${kind:-ship}"
}

# The thread of a recorded T3 ship or scout, or nothing. A secondmate's thread
# is its home's, not one task's card.
worker_thread() {  # <task-id>
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_backend_of_meta "$meta")" = t3code ] || return 1
  case "$(worker_kind "$1")" in ship|scout) ;; *) return 1 ;; esac
  fm_backend_target_of_meta "$meta"
}

# Print active, ended, or unknown for the worker's no-mistakes run. A
# bin/fm-crew-state.sh reading off any other source means no run is attributed,
# and its done covers a run left only watching a ready PR. Scouts run none.
run_state() {  # <worker-id>
  [ "$(worker_kind "$1")" = ship ] || { printf 'ended'; return 0; }
  case "$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null)" in
    'state: working · source: run-step'*|'state: parked · source: run-step'*) printf 'active' ;;
    'state: unknown · source: run-step'*) printf 'unknown' ;;
    *) printf 'ended' ;;
  esac
}

# Print the helper's one-word outcome: on|off (set), gone (no card: the thread
# is missing, or archived and so unlabelled), unsupported (a T3 with no label).
set_label() {  # <thread-id> [label]
  local out rc=0
  out=$(fm_backend_t3code_status_label "$1" "${2:-}" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    4) printf 'unsupported'; return 0 ;;
    *) return 1 ;;
  esac
  case "$out" in
    *'"exists":false'*|*'"archived":true'*) printf 'gone' ;;
    *) if [ -n "${2:-}" ]; then printf 'on'; else printf 'off'; fi ;;
  esac
}

# Bring one worker's card in line with its open holds and its run.
sync_worker() {  # <worker-id>
  local worker=$1 thread entry held=0 unknown=0 rc label='' outcome
  thread=$(worker_thread "$worker")
  if [ -z "$thread" ]; then
    rm -rf -- "${WAITS:?}/$worker"
    return 0
  fi
  for entry in "$WAITS/$worker"/*; do
    [ -e "$entry" ] || continue
    rc=0
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" open "${entry##*/}" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) held=1 ;;
      1) rm -f -- "$entry" ;;
      *) unknown=1 ;;
    esac
  done
  if [ "$held" = 1 ]; then
    label=$WAITING_LABEL
  else
    [ "$unknown" = 0 ] || return 0
    case "$(run_state "$worker")" in
      active) label=$TESTING_LABEL ;;
      ended) ;;
      *) return 0 ;;
    esac
  fi
  outcome=$(set_label "$thread" "$label") || {
    echo "t3-captain-label: could not set the status of $worker's card, thread $thread; the next pass retries"
    return 1
  }
  case "$outcome" in
    off|gone) rm -rf -- "${WAITS:?}/$worker" ;;
  esac
}

# Record every T3 ship with an active run, so the pass below labels it.
note_active_runs() {
  local meta worker
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    worker=${meta##*/}
    worker=${worker%.meta}
    [ ! -d "$WAITS/$worker" ] || continue
    [ -n "$(worker_thread "$worker")" ] || continue
    [ "$(run_state "$worker")" = active ] || continue
    mkdir -p "$WAITS/$worker" \
      || echo "t3-captain-label: could not record $worker's run; its card will not show Testing"
  done
}

case "$VERB" in
  note)
    for worker in "$@"; do
      [ -n "$(worker_thread "$worker")" ] || continue
      mkdir -p "$WAITS/$worker" && : > "$WAITS/$worker/$1" \
        || echo "t3-captain-label: could not record $1's hold for $worker; its card will not show the wait"
    done
    ;;
  sync)
    [ "$#" = 0 ] || note_active_runs
    [ -d "$WAITS" ] || exit 0
    fm_backend_source t3code >/dev/null 2>&1 || exit 1
    failed=0
    for dir in "$WAITS"/*/; do
      [ -d "$dir" ] || continue
      dir=${dir%/}
      sync_worker "${dir##*/}" || failed=1
    done
    rmdir "$WAITS" 2>/dev/null
    exit "$failed"
    ;;
  clear)
    [ -d "$WAITS/$1" ] || exit 0
    fm_backend_source t3code >/dev/null 2>&1 || exit 1
    thread=$(worker_thread "$1")
    if [ -n "$thread" ] && ! set_label "$thread" >/dev/null; then
      echo "t3-captain-label: could not clear the status of $1's card, thread $thread, before cleanup"
      exit 1
    fi
    rm -rf -- "${WAITS:?}/$1"
    rmdir "$WAITS" 2>/dev/null
    ;;
esac
exit 0
