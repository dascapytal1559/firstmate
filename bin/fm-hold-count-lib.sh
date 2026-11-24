#!/usr/bin/env bash
# fm-hold-count-lib.sh - the one rule for which open backlog holds count for
# which task, and as what: a captain call that is due, a snooze, or a deferral.
#
# The input is bin/fm-fleet-snapshot.sh's JSON (its --contribution-input form
# is enough), whose hold_bucket is the backlog's one date rule. A hold counts
# while its structured row is open (not Done), for the row's own task and for
# the task it was raised for (its hold_origin). The counted kinds are:
#   captain  a captain hold that is due: any hold_bucket but "dated", so a live,
#            aged, or blocked call counts. The captain moves next.
#   dated    a captain hold whose hold_until date has not yet arrived: the
#            captain put the call off to that date. On the date it counts as
#            captain again, with no other action.
#   parked   a parked hold, with or without a date: the captain snoozed the
#            task (a T3 snooze, or "snooze" in chat).
#   future   a future hold, and also bedtime when its reason starts
#            "At bedtime".
# A task is snoozed when a parked or a dated hold counts for it.
#
# Readers: bin/fm-t3-crew-status.sh labels each live T3 worker's card from these
# counts ("Waiting for captain" from a captain count, the snooze rows from the
# snooze), and bin/fm-wake-drain.sh presents the same counts as its WAITING FOR
# CAPTAIN section and as the snooze marks on OPEN DECISIONS, so firstmate reads
# the captain's waiting calls by the rule T3 shows them by.
#
# Source this file; it defines functions only. Bash 3.2 compatible.

# fm_hold_counts: read the snapshot JSON on stdin and print one TSV line per
# counted hold and task it counts for:
#   <kind> <task> <row-id> <hold-origin> <hold-until> <unresolved blockers, comma-joined> <title>
# in backlog order, the row's own line first. An absent origin, date, or blocker
# is "-", so no column is ever empty and a tab-splitting read keeps every column in
# place. Exit nonzero when the JSON cannot be read.
fm_hold_counts() {
  jq -r '
    .backlog.records[]
    | select(.structured and .state != "done"
        and (.hold_kind == "captain" or .hold_kind == "parked" or .hold_kind == "future"))
    | (if .hold_bucket == "dated" then "dated" else .hold_kind end) as $kind
    | . as $row
    | ($kind, (if $kind == "future" and ((.hold_reason // "") | startswith("At bedtime")) then "bedtime" else empty end)) as $counted
    | ($row.id, ($row.hold_origin // empty)) as $task
    | [$counted, $task, $row.id, ($row.hold_origin // "-"), ($row.hold_until // "-"),
        (($row.unresolved_blocker_ids // []) | if length == 0 then "-" else join(",") end),
        (($row.title // "") | gsub("[[:cntrl:]]+"; " "))]
    | @tsv'
}

# fm_hold_snoozed <task>: read fm_hold_counts lines on stdin; exit 0 when the
# task is snoozed and print the date the snooze runs to, or nothing for a snooze
# with no date. With several snoozes, one with no date wins, else the latest
# date. Exit 1 when no snooze counts for the task.
fm_hold_snoozed() {  # <task>
  awk -F '\t' -v task="$1" '
    $2 == task && ($1 == "parked" || $1 == "dated") {
      found = 1
      if ($5 == "-") undated = 1
      else if ($5 > latest) latest = $5
    }
    END {
      if (!found) exit 1
      if (!undated) print latest
    }'
}
