#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

# backlog_home <case> -> echoes a case directory that is also a firstmate home
# with an empty tasks-axi markdown backlog, so the drain reads its holds.
backlog_home() {
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf '%s\n' "$dir"
}

in_home() {  # <dir> <command...>
  local dir=$1
  shift
  (cd "$dir" && FM_HOME="$dir" "$@")
}

# The captain snoozed two tasks that each have an open review-board decision:
# one in T3 with no date (a parked hold), one as a captain call put off to a
# later date. Neither may read as waiting on the captain, but both stay listed,
# marked, after the decision that is still waiting.
test_snoozed_task_decision_is_not_shown_as_waiting() {
  local dir out later
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return; }
  dir=$(backlog_home snoozed-decisions)
  out="$dir/drain.out"
  later=$(date -v+14d +%Y-%m-%d 2>/dev/null || date -d '+14 days' +%Y-%m-%d)
  in_home "$dir" tasks-axi add board-w "Summary board" --repo s >/dev/null || fail "seeding board-w failed"
  in_home "$dir" tasks-axi add groove-w "Chords groove" --repo s >/dev/null || fail "seeding groove-w failed"
  in_home "$dir" tasks-axi add plain-w "Plain worker" --repo s >/dev/null || fail "seeding plain-w failed"
  in_home "$dir" tasks-axi hold board-w --kind parked --reason "Snoozed in T3" >/dev/null || fail "parking board-w failed"
  in_home "$dir" "$ROOT/bin/fm-captain-hold.sh" hold groove-w --reason "pick a groove" --until "$later" >/dev/null \
    || fail "putting groove-w off failed"
  printf 'needs-decision [key=board-review]: review the summary board\n' > "$dir/state/board-w.status"
  printf 'needs-decision [key=board-review]: review the groove board\n' > "$dir/state/groove-w.status"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/state/plain-w.status"

  FM_HOME="$dir" "$DRAIN" > "$out" || fail "drain failed over snoozed decisions"

  grep -Fx 'board-w [key=board-review] needs-decision (snoozed, no date, not waiting on the captain): review the summary board' "$out" >/dev/null \
    || fail "an undated snooze's decision was not marked snoozed with no date: $(cat "$out")"
  grep -Fx "groove-w [key=board-review] needs-decision (snoozed until $later, not waiting on the captain): review the groove board" "$out" >/dev/null \
    || fail "a dated snooze's decision was not marked with its return date: $(cat "$out")"
  grep -Fx 'plain-w [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "a decision on a task nobody snoozed gained a mark: $(cat "$out")"
  [ "$(grep -n 'plain-w \[key=' "$out" | cut -d: -f1)" -lt "$(grep -n 'board-w \[key=' "$out" | cut -d: -f1)" ] \
    || fail "a snoozed decision was listed ahead of one still waiting: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "the answerer-closes hint went missing: $(cat "$out")"
  if sed -n '/^WAITING FOR CAPTAIN (/,/^OPEN DECISIONS (/p' "$out" | grep -E '^(board-w|groove-w)( |:)' >/dev/null; then
    fail "a snoozed task was listed as waiting for the captain: $(cat "$out")"
  fi
  grep -Fx "WAITING FOR CAPTAIN: put off by the captain, not waiting: groove-w until $later" "$out" >/dev/null \
    || fail "the call put off to a date was not named with its date: $(cat "$out")"
  pass "a snoozed task's decision is marked with its return date and never shown as waiting on the captain"
}

# A worker's call moved to a captain-held backlog row closes its status key, so
# OPEN DECISIONS no longer lists it; the call is still waiting on the captain
# and must be presented, with the worker it was raised for. A captain call whose
# date has arrived is due again with no other action.
test_captain_held_call_with_an_open_hold_appears() {
  local dir out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return; }
  dir=$(backlog_home captain-held-calls)
  out="$dir/drain.out"
  in_home "$dir" tasks-axi add numbers-w "UI numbers" --repo s >/dev/null || fail "seeding numbers-w failed"
  in_home "$dir" "$ROOT/bin/fm-captain-hold.sh" hold chart-call --title "Which aspects become charts?" \
    --reason "which charts" --origin numbers-w >/dev/null || fail "holding chart-call failed"
  in_home "$dir" tasks-axi add due-call "Due again today" --repo s >/dev/null || fail "seeding due-call failed"
  in_home "$dir" "$ROOT/bin/fm-captain-hold.sh" hold due-call --reason "revisit" --until "$(date +%Y-%m-%d)" >/dev/null \
    || fail "holding due-call to today failed"
  printf 'needs-decision [key=chart-call]: which aspects become charts\n' > "$dir/state/numbers-w.status"
  printf 'captain-held [key=chart-call]: held for the captain as chart-call\n' >> "$dir/state/numbers-w.status"

  FM_HOME="$dir" "$DRAIN" > "$out" || fail "drain failed over a captain-held call"

  grep -F 'WAITING FOR CAPTAIN (' "$out" >/dev/null || fail "no WAITING FOR CAPTAIN section printed: $(cat "$out")"
  grep -Fx 'chart-call (for numbers-w): Which aspects become charts?' "$out" >/dev/null \
    || fail "the captain-held call was not presented with its worker: $(cat "$out")"
  grep -Fx 'due-call: Due again today' "$out" >/dev/null \
    || fail "a captain call whose date has arrived was not presented as due: $(cat "$out")"
  if grep -F 'OPEN DECISIONS (' "$out" >/dev/null; then
    fail "a key closed by its captain-held transfer still read as an open status decision: $(cat "$out")"
  fi
  pass "a captain-held call with an open hold is presented as waiting on the captain"
}

# A drain whose backlog cannot be read says so rather than presenting no
# captain calls, and still prints OPEN DECISIONS.
test_unreadable_backlog_is_disclosed() {
  local dir out
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return; }
  dir=$(backlog_home unreadable-backlog)
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/state/plain-w.status"
  chmod 000 "$dir/data/backlog.md"
  if [ -r "$dir/data/backlog.md" ]; then
    chmod 644 "$dir/data/backlog.md"
    pass "skip: this user can read a mode-000 file"
    return
  fi

  FM_HOME="$dir" "$DRAIN" > "$out" || fail "drain failed when the backlog could not be read"
  chmod 644 "$dir/data/backlog.md"

  grep -F 'WAITING FOR CAPTAIN: the backlog could not be read' "$out" >/dev/null \
    || fail "an unreadable backlog was not disclosed: $(cat "$out")"
  grep -Fx 'plain-w [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS did not still print when the backlog could not be read: $(cat "$out")"
  pass "a backlog that cannot be read is disclosed and OPEN DECISIONS still prints"
}

test_snoozed_task_decision_is_not_shown_as_waiting
test_captain_held_call_with_an_open_hold_appears
test_unreadable_backlog_is_disclosed
test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
