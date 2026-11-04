#!/usr/bin/env bash
# fm-t3-captain-label.sh - show "Waiting for captain" on a live T3 worker's card
# (docs/t3code-backend.md "Waiting for captain").
#
# Only Firstmate knows when a worker waits on the captain, so it says so in the
# thread title, the one thing on the card it can set. The wait is a captain hold
# (bin/fm-captain-hold.sh) on the worker's own task, or on a task whose --origin
# is the worker; a worker's needs-decision line alone does not count, because
# firstmate settles most of those itself. A hold on a task with no live T3
# worker has no card and records nothing, so other backends do nothing here.
#
# Usage:
#   fm-t3-captain-label.sh note <held-task-id> [<origin-id>]
#     bin/fm-captain-hold.sh hold runs this. For each named task that is a
#     recorded T3 ship or scout, records the hold. Touches no server.
#   fm-t3-captain-label.sh sync
#     bin/fm-captain-hold.sh runs this after every hold, answer, and reconcile,
#     and bin/fm-watch.sh about once a minute while any record exists. For each
#     record, sets the title to match the holds still open, and removes the
#     record once the title is restored or the worker or its thread is gone.
#   fm-t3-captain-label.sh clear <worker-id>
#     bin/fm-teardown.sh runs this before it archives the thread: the title
#     comes back whatever the holds say, since the card is about to go.
#
# Record: <state>/t3-captain-wait/<worker-id>/<held-task-id>, one empty file per
# hold, so a hold and a sync never rewrite each other's entry.
#
# Sync is level-triggered and takes the base title from the live thread, so it
# keeps no copy that could go stale: a rename that failed or a server that was
# down converges on a later pass, and a record stays until its title is proven.
# The rename is durable in T3, so a restart alone changes nothing. A hold whose
# state cannot be read leaves the title as it is. Title and record are display
# only: no selector, recovery, or T3 lineage reads them, and crew membership
# stays T3's crewOf.
#
# Exit: 0, or 1 when a title could not be set (a line on stdout says which; the
# record stays for the next pass); usage errors exit 2. A home with no
# config/t3code-token exits 0 at once. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WAITS="$STATE/t3-captain-wait"
LABEL='Waiting for captain'

usage() {
  sed -n '12,24p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB:$#" in
  note:1|note:2|sync:0|clear:1) ;;
  *) usage ;;
esac

[ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# The thread of a recorded T3 ship or scout, or nothing. A secondmate's thread
# is its home's, not one task's card.
worker_thread() {  # <task-id>
  local meta="$STATE/$1.meta" kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_backend_of_meta "$meta")" = t3code ] || return 1
  kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
  case "${kind:-ship}" in ship|scout) ;; *) return 1 ;; esac
  fm_backend_target_of_meta "$meta"
}

# Print the helper's one-word outcome: on|off (set), gone (no card: the thread
# is missing, or archived and so unlabelled).
set_label() {  # <thread-id> <on|off>
  local out
  out=$(fm_backend_t3code_title_label "$1" "$LABEL" "$2" 2>/dev/null) || return 1
  case "$out" in
    *'"exists":false'*|*'"archived":true'*) printf 'gone' ;;
    *) printf '%s' "$2" ;;
  esac
}

# Bring one worker's title in line with its open holds.
sync_worker() {  # <worker-id>
  local worker=$1 thread entry state=off unknown=0 rc outcome
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
      0) state=on ;;
      1) rm -f -- "$entry" ;;
      *) unknown=1 ;;
    esac
  done
  [ "$state" = on ] || [ "$unknown" = 0 ] || return 0
  outcome=$(set_label "$thread" "$state") || {
    echo "t3-captain-label: could not set the title of $worker's thread $thread; the next pass retries"
    return 1
  }
  [ "$outcome" = on ] || rm -rf -- "${WAITS:?}/$worker"
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
    if [ -n "$thread" ] && ! set_label "$thread" off >/dev/null; then
      echo "t3-captain-label: could not restore the title of $1's thread $thread before cleanup"
      exit 1
    fi
    rm -rf -- "${WAITS:?}/$1"
    rmdir "$WAITS" 2>/dev/null
    ;;
esac
exit 0
