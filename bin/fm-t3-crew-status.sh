#!/usr/bin/env bash
# fm-t3-crew-status.sh - keep each live T3 worker's crew card status in line
# with what Firstmate knows about it (docs/t3code-backend.md "Crew card status").
#
# The label is a projection and this script keeps no record of its own: every
# pass computes it afresh for every recorded T3 ship and scout from the
# authoritative reads, and compares it with the live card. Those reads are the
# worker's current state, as bin/fm-crew-state.sh reads it; its steering
# inbox; and its thread in T3. What waits on the captain is not a label: T3
# shows it on the card from the captain's list (bin/fm-t3-needs-me.sh).
#
# Labels, first match wins:
#   Testing              a ship's no-mistakes run is active: crew-state reads
#                        working or parked from the run step. It shows while
#                        the worker works too.
#   Waiting              between turns, with an open decision, a blocker, or a
#                        declared pause: crew-state reads parked, blocked, or
#                        paused.
#   Ready                between turns, and crew-state reads the work done.
#   Failed               between turns, and crew-state reads it failed.
#   none                 otherwise, and while the worker works, so T3 shows
#                        its own Working.
# The worker works while T3 reads its thread busy or while its steering inbox
# holds an unhandled message, as when the captain's reply has just landed. A
# run crew-state cannot read, or a turn T3 cannot report where the label
# depends on it, leaves the card as it is.
#
# Usage:
#   fm-t3-crew-status.sh sync
#     One pass over every card. bin/fm-captain-hold.sh runs it after every
#     hold, answer, and reconcile close; bin/fm-watch.sh about once a minute
#     as the backstop, and at once when a T3 run ends; and a doorbell
#     delivered to a T3 worker starts one (fm_task_inbox_ring). One pass runs
#     at a time; a pass that finds another running asks it to go again and
#     leaves, so the last pass to write a card always read it after the
#     newest event.
#   fm-t3-crew-status.sh clear <worker-id>
#     bin/fm-teardown.sh runs this before it archives the thread: the label
#     comes off whatever the records say, since the card is about to go.
#
# <state>/.t3-crew-status.lock, a symlink naming the running pass's pid, is the
# one publisher lock, and <state>/.t3-crew-status.again asks its holder for
# another pass. A lock whose pid is gone is a killed pass and is taken over.
#
# A label that failed or a T3 that was down converges on a later pass, and a
# label T3 lost, as a restart could, is set again by the next pass. A T3 with
# no status label shows nothing and changes nothing; its cards catch up on the
# first pass after T3 is updated. The label is display only: no selector,
# recovery, or T3 lineage reads it, and crew membership stays T3's crewOf.
#
# Exit: 0, or 1 when the records could not be read or a card could not be
# brought in line (a line on stdout says which; the next pass retries); usage
# errors exit 2. A home with no config/t3code-token exits 0 at once. Bash 3.2
# compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '/^# Usage:/,/^#     comes off/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}:$#" in
  sync:1|clear:2) ;;
  *) usage ;;
esac
VERB=$1

[ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo "t3-crew-status: jq is required"; exit 1; }

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-crew-status.XXXXXX") || { echo "t3-crew-status: no temporary directory"; exit 1; }
trap 'rm -rf -- "$WORK"' EXIT

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

# One JSON label: the text, "" for none, null to leave the card.
json_label() {  # <label|-> where - leaves the card
  if [ "$1" = - ]; then printf 'null'; else printf '"%s"' "$1"; fi
}

# Send <cards-file> to T3 and report each card it could not bring in line.
publish() {  # <cards-file>
  local rc=0 worker thread message failed=0
  fm_backend_source t3code >/dev/null 2>&1 || { echo "t3-crew-status: the T3 adapter could not load"; return 1; }
  fm_backend_t3code_mcp crew-status --file "$1" > "$WORK/out.json" 2>"$WORK/out.err" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "t3-crew-status: T3 could not take the crew cards: $(head -n 1 "$WORK/out.err" | grep . || echo "exit $rc"); the next pass retries"
    return 1
  fi
  while IFS=$'\t' read -r worker thread message; do
    [ -n "$worker" ] || continue
    echo "t3-crew-status: could not set the status of $worker's card, thread $thread: $message; the next pass retries"
    failed=1
  done <<< "$(jq -r --slurpfile in "$1" '
    .cards as $out | $in[0].cards | to_entries[]
    | select($out[.key].outcome == "failed")
    | [.value.worker, .value.thread, ($out[.key].error.message // "?")] | @tsv' "$WORK/out.json")"
  return "$failed"
}

# One pass: every live T3 ship and scout's wanted labels, sent in one session.
sync_pass() {
  local meta worker thread line state run working between pids='' n=0
  : > "$WORK/workers.tsv"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    worker=${meta##*/}
    worker=${worker%.meta}
    thread=$(worker_thread "$worker") || continue
    [ -n "$thread" ] || continue
    printf '%s\t%s\n' "$worker" "$thread" >> "$WORK/workers.tsv"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$worker" > "$WORK/$n.state" 2>/dev/null </dev/null &
    pids="$pids $!"
    n=$((n + 1))
  done
  if [ "$n" = 0 ]; then
    # shellcheck disable=SC2086  # one pid per word
    [ -z "$pids" ] || wait $pids
    return 0
  fi
  # shellcheck disable=SC2086  # one pid per word
  wait $pids
  n=0
  while IFS=$'\t' read -r worker thread; do
    line=$(head -n 1 "$WORK/$n.state")
    n=$((n + 1))
    state=${line#state: }
    state=${state%% *}
    case "$line" in
      'state: working · source: run-step'*|'state: parked · source: run-step'*) run=Testing ;;
      'state: unknown · source: run-step'*|'') run=- ;;
      *) run='' ;;
    esac
    working=$run
    if [ -n "$run" ]; then
      between=$run
    else
      case "$state" in
        parked|blocked|paused) between=Waiting ;;
        done) between=Ready ;;
        failed) between=Failed ;;
        *) between='' ;;
      esac
    fi
    ! fm_task_inbox_has_unhandled "$STATE" "$worker" || between=$working
    jq -cn --arg worker "$worker" --arg thread "$thread" \
      --argjson between "$(json_label "$between")" --argjson working "$(json_label "$working")" \
      '{worker: $worker, thread: $thread, between: $between, working: $working}'
  done < "$WORK/workers.tsv" | jq -s '{cards: .}' > "$WORK/cards.json" \
    || { echo "t3-crew-status: the crew cards could not be staged"; return 1; }
  publish "$WORK/cards.json"
}

# Run the pass above once at a time. A pass that finds another holding the
# lock asks it for one more pass and leaves; the holder repeats while asked,
# and looks again after letting go, so no request is lost between its last
# pass and its release.
sync_serialized() {
  local lock="$STATE/.t3-crew-status.lock" again="$STATE/.t3-crew-status.again" holder rc=0
  : > "$again" || return 1
  while [ -e "$again" ]; do
    if ! ln -s "$$" "$lock" 2>/dev/null; then
      if ! holder=$(readlink "$lock" 2>/dev/null); then
        [ -e "$lock" ] || continue
        echo "t3-crew-status: $lock is not a pass lock; leaving the cards as they are"
        return 1
      fi
      if kill -0 "$holder" 2>/dev/null; then
        return "$rc"
      fi
      rm -f -- "$lock"
      continue
    fi
    while [ -e "$again" ]; do
      rm -f -- "$again"
      sync_pass || rc=1
    done
    rm -f -- "$lock"
  done
  return "$rc"
}

case "$VERB" in
  sync)
    sync_serialized
    exit
    ;;
  clear)
    thread=$(worker_thread "$2") || exit 0
    [ -n "$thread" ] || exit 0
    jq -n --arg worker "$2" --arg thread "$thread" '{cards: [{worker: $worker, thread: $thread, between: "", working: ""}]}' \
      > "$WORK/cards.json" || exit 1
    publish "$WORK/cards.json" || {
      echo "t3-crew-status: could not clear the status of $2's card before cleanup"
      exit 1
    }
    ;;
esac
exit 0
