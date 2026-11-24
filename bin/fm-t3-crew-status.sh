#!/usr/bin/env bash
# fm-t3-crew-status.sh - keep each live T3 worker's crew card status in line
# with what Firstmate knows about it (docs/t3code-backend.md "Crew card status").
#
# The label is a projection and this script keeps no record of its own: every
# pass computes it afresh for every recorded T3 ship and scout from the
# authoritative reads, and compares it with the live card. Those reads are the
# backlog's holds, as bin/fm-fleet-snapshot.sh reads them; the worker's current
# state, as bin/fm-crew-state.sh reads it; its open decisions, as
# bin/fm-classify-lib.sh's status_open_decisions folds them; its recorded yolo;
# its steering inbox; the Lavish boards it owns, as bin/fm-procevent.sh records
# them; and its thread in T3. Which holds count for a worker, and as what
# (captain, dated, parked, future, bedtime), is bin/fm-hold-count-lib.sh's one
# rule, which bin/fm-wake-drain.sh presents to firstmate too; a parked or dated
# hold is the worker's snooze.
#
# A worker holds an open board while a task-owned process-event registration
# names it as owner and no captured round of that source is unacknowledged. The
# listening board is itself the fact that the captain moves next, whatever the
# worker's status log says. A round the captain sent or a session the captain
# ended is the worker's to handle, and a concluded or retired board has no
# registration, so neither counts. A registry that cannot be read counts no board.
#
# A card between turns says who moves next. Labels, first match wins:
#   Waiting for captain  a live hold of kind captain (not dated) counts for
#                        the worker; or an open needs-decision with key
#                        board-review and no parked or dated hold; or
#                        crew-state reads done, parked, or paused and the
#                        worker holds an open board with no parked, dated, or
#                        future hold; or a finished ship that has not landed,
#                        whose recorded yolo is not on, and that has no parked
#                        or dated hold, since landing it needs the captain's
#                        approval.
#   Testing              a ship's no-mistakes run is active: crew-state reads
#                        working or parked from the run step. It shows while
#                        the worker works too.
#   Failed               crew-state reads it failed, whatever future, parked,
#                        or dated hold counts, so a broken worker never looks
#                        calm.
#   ☾︎ Scheduled          a hold of kind future whose reason starts "At bedtime"
#                        counts, and crew-state reads done, parked, or paused.
#                        A blocked worker never reads this. The
#                        glyph is U+263E plus U+FE0E (text presentation), so
#                        T3 draws it in the label's own colour, not an emoji.
#   Waiting              a snoozed worker (parked or dated hold, no future
#                        hold) that reads done, parked, or paused holds an
#                        open board, or reads done with no other open decision.
#   Queued               firstmate moves next: crew-state reads done or blocked,
#                        or parked with an open decision other than
#                        board-review, or a hold of kind future counts.
#   Waiting              any other declared wait: crew-state reads parked or
#                        paused, or a hold of kind parked or a dated captain
#                        hold (the captain snoozed it) counts.
#   none                 otherwise, and while the worker works, so T3 shows
#                        its own Working.
# The worker works while T3 reads its thread busy or while its steering inbox
# holds an unhandled message, as when the captain's reply has just landed. A
# run crew-state cannot read, a status log that cannot be folded, or a turn T3
# cannot report where the label depends on it, leaves the card as it is.
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
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-hold-count-lib.sh
. "$SCRIPT_DIR/fm-hold-count-lib.sh"

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

# Whether a hold of <kind> counts for <worker> (bin/fm-hold-count-lib.sh).
has_hold() {  # <kind> <worker>
  awk -F '\t' -v kind="$1" -v task="$2" '$1 == kind && $2 == task { found = 1; exit } END { exit !found }' "$WORK/holds"
}

# Whether the captain snoozed <worker> (bin/fm-hold-count-lib.sh).
snoozed() {  # <worker>
  fm_hold_snoozed "$1" < "$WORK/holds" >/dev/null
}

# List in $WORK/boards each task that holds an open board. One read of the
# registry per pass; the round inbox is read only when a task-owned board exists.
read_open_boards() {
  local reg inbox rec id line kind owner complete result
  : > "$WORK/boards"
  : > "$WORK/board-owners"
  : > "$WORK/open-rounds"
  reg=$(fm_procevent_registry_dir "$STATE")
  inbox=$(fm_procevent_inbox_dir "$STATE")
  [ -d "$reg" ] && [ ! -L "$reg" ] && [ -r "$reg" ] && [ -x "$reg" ] || return 0
  for rec in "$reg"/*.source; do
    [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ] || continue
    id=${rec##*/}
    id=${id%.source}
    kind='' owner='' complete=0
    while IFS= read -r line; do
      case "$line" in
        kind=*) kind=${line#kind=} ;;
        owner_task=*) owner=${line#owner_task=} ;;
        argv:) complete=1; break ;;
      esac
    done 2>/dev/null < "$rec"
    [ "$complete" = 1 ] && [ "$kind" = task-owned ] && [ -n "$owner" ] || continue
    printf '%s\t%s\n' "$id" "$owner" >> "$WORK/board-owners"
  done
  [ -s "$WORK/board-owners" ] || return 0
  if [ -e "$inbox" ] || [ -L "$inbox" ]; then
    [ -d "$inbox" ] && [ ! -L "$inbox" ] && [ -r "$inbox" ] && [ -x "$inbox" ] || return 0
  fi
  fm_procevent_pending "$STATE" > "$WORK/pending-rounds"
  while IFS= read -r result; do
    fm_procevent_result_source_id "$result"
  done < "$WORK/pending-rounds" > "$WORK/open-rounds"
  while IFS=$'\t' read -r id owner; do
    grep -Fqx -- "$id" "$WORK/open-rounds" || printf '%s\n' "$owner"
  done < "$WORK/board-owners" > "$WORK/boards"
}

# True when a finished ship's work is already in: crew-state read its PR merged,
# the merge poll recorded its recorded PR merged, or the commit its newest ready
# report names is on a local-only project's default branch. Unreadable evidence
# is not landed.
ship_landed() {  # <worker> <crew-state-line>
  local worker=$1 meta="$STATE/$1.meta" project branch ready head default
  case "$2" in
    'state: done · source: run-step · run passed: PR merged'*|'state: done · source: run-step · checks green: PR merged'*)
      return 0
      ;;
  esac
  if fm_pr_url_parse "$(fm_meta_get "$meta" pr)" \
    && fm_pr_poll_merge_already_notified "$STATE" "$worker" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
    return 0
  fi
  [ "$(fm_meta_get "$meta" mode)" = local-only ] || return 1
  project=$(fm_meta_get "$meta" project)
  [ -n "$project" ] || return 1
  branch=$(fm_meta_get "$meta" branch)
  ready=$(fm_dod_local_newest_ready "$STATE/$worker.status") || return 1
  head=$(fm_dod_local_ready_head "$project" "$ready" "${branch:-fm/$worker}") || return 1
  default=$(fm_dod_local_default_branch "$project") || return 1
  git -C "$project" merge-base --is-ancestor "$head" "refs/heads/$default" 2>/dev/null
}

# The label for <worker> between turns, or - to leave its card. <run> is the
# run's label: Testing, - when the run cannot be read, or empty. <line> is
# crew-state's reading.
between_label() {  # <worker> <state> <run> <line>
  local worker=$1 state=$2 run=$3 line=$4 log="$STATE/$1.status" meta="$STATE/$1.meta"
  local kind open key verb board=0 other=0 open_board=0
  if has_hold captain "$worker"; then
    printf 'Waiting for captain'
    return
  fi
  if [ -e "$log" ] || [ -L "$log" ]; then
    if [ -L "$log" ] || [ ! -f "$log" ] || [ ! -r "$log" ]; then
      printf -- -
      return
    fi
  fi
  kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
  kind=${kind:-ship}
  open=$(status_open_decisions "$log" "$kind")
  while IFS=$'\t' read -r key verb _; do
    [ "$verb" = needs-decision ] || continue
    if [ "$key" = board-review ]; then board=1; else other=1; fi
  done <<EOF
$open
EOF
  case "$state" in
    done|parked|paused)
      if grep -Fqx -- "$worker" "$WORK/boards" && ! has_hold future "$worker"; then
        open_board=1
      fi
      ;;
  esac
  if ! snoozed "$worker" && { [ "$board" = 1 ] || [ "$open_board" = 1 ] \
    || { [ "$state" = "done" ] && [ "$kind" = ship ] \
      && [ "$(fm_meta_get "$meta" yolo)" != on ] && ! ship_landed "$worker" "$line"; }; }; then
    printf 'Waiting for captain'
  elif [ -n "$run" ]; then
    printf '%s' "$run"
  elif [ "$state" = failed ]; then
    printf 'Failed'
  elif has_hold bedtime "$worker" \
    && { [ "$state" = "done" ] || [ "$state" = parked ] || [ "$state" = paused ]; }; then
    printf '☾︎ Scheduled'
  elif [ "$open_board" = 1 ] || { [ "$state" = "done" ] && [ "$other" = 0 ] \
    && snoozed "$worker" && ! has_hold future "$worker"; }; then
    printf 'Waiting'
  elif [ "$state" = "done" ] || [ "$state" = blocked ] \
    || { [ "$state" = parked ] && [ "$other" = 1 ]; } || has_hold future "$worker"; then
    printf 'Queued'
  elif [ "$state" = parked ] || [ "$state" = paused ] || snoozed "$worker"; then
    printf 'Waiting'
  fi
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
  if ! { "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$WORK/snapshot.json" 2>"$WORK/snapshot.err" \
    && fm_hold_counts < "$WORK/snapshot.json" > "$WORK/holds"; }; then
    # shellcheck disable=SC2086  # one pid per word
    wait $pids
    echo "t3-crew-status: the backlog could not be read: $(head -n 1 "$WORK/snapshot.err" | grep . || echo unreadable); the next pass retries"
    return 1
  fi
  # shellcheck disable=SC2086  # one pid per word
  wait $pids
  read_open_boards
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
    between=$(between_label "$worker" "$state" "$run" "$line")
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
