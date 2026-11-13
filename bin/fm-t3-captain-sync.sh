#!/usr/bin/env bash
# fm-t3-captain-sync.sh - keep the captain's list in T3 and the backlog in
# step in real time, both ways (docs/t3code-backend.md "Captain's list").
#
# The backlog is the one record of what waits on the captain;
# bin/fm-t3-needs-me.sh sync pushes the whole list to T3 and is idempotent, so
# a missed or doubled trigger never leaves anything stale. This script owns
# what triggers it and how the captain's own actions in T3 (Snooze, Bring
# back, Archive, and archiving or restoring a thread) reach the backlog.
#
# Usage:
#   fm-t3-captain-sync.sh listen
#     The listener, run only by the process-event runner (source
#     t3-captain-sync, adapter bin/fm-procevent-t3-captain-sync.sh), never
#     in a turn. Its Node half, bin/fm-t3-captain-sync.mjs, watches the
#     backlog file (markdown backend only; another backend relies on the
#     calls below and the ten-minute check), data/needs-me/, each task
#     record's T3 thread and kept-review fields in state/*.meta, and the
#     Bridge's other sources (data/high-level-objectives.md,
#     config/crew-dispatch.json, data/rules/inventory.json); a change runs
#     one sync pass 250 ms after the last event. It also holds a
#     t3_decisions_actions call open (bin/fm-t3-mcp.mjs actions, 25 s at a
#     time) as the signal that the captain acted, and on each action runs
#     apply-pending below. When T3 cannot be reached it retries with backoff
#     (1 s up to 30 s) and, once back, pushes the whole list before it reads
#     the actions T3 kept; a T3 without the action log is asked again every
#     5 minutes. It prints nothing on stdout and logs to
#     state/t3-captain-sync/listen.log.
#   fm-t3-captain-sync.sh apply-pending
#     Apply every action T3 holds unacknowledged, in T3's order, as `apply`
#     below, then one sync pass, then acknowledge them, so by the time T3
#     drops its overlay the list already shows the truth. One round at a
#     time: the listener and `check` share state/t3-captain-sync/actions.lock.
#     An action that fails holds back every later action on the same item
#     until it is applied or refused, and it is refused, with its error, on
#     its third failure (counted in state/t3-captain-sync/attempts.json).
#     Exit 0 every action settled; 75 one still waits, to try again (the
#     listener does in 30 s); 1 T3 could not be read or acknowledged.
#   fm-t3-captain-sync.sh apply --file <action-json>
#     Apply one action from T3's log to the backlog, idempotently, so a
#     replay changes nothing: snooze and unsnooze through
#     bin/fm-captain-hold.sh snooze --at (with --until) and unsnooze; archive
#     and thread-archived through bin/fm-t3-review.sh closed --at for a kept
#     review's thread, else bin/fm-captain-hold.sh archive --at. Archive on an
#     item of a kept review's card archives that card's thread in T3 first,
#     since the card is then gone, so the record and the thread agree.
#     Archive on a decision on a worker still running (its card not
#     finished) also leaves one wake, state/t3-captain-sync/<worker>.wake,
#     asking firstmate to wind the worker down through its normal safe
#     cleanup; the thread itself stays. A thread FirstMate archived itself
#     (fm_backend_t3code_kill in bin/backends/t3code.sh, or the retirement
#     of an item's own thread in bin/fm-t3-mcp.mjs decisions, marks it
#     first) is never the captain's: its
#     thread-archived changes nothing, so its items stay open and move to
#     their own threads on the next pass. thread-unarchived changes nothing
#     (a kept review reopened is the next check's). The item's thread is the
#     one the last accepted pass sent (state/t3-needs-me/list.json). Exit 0
#     applied; 3 refused, with the reason on stdout for T3 to show; 1
#     failed, to retry.
#   fm-t3-captain-sync.sh check
#     The ten-minute safety net: the watcher runs it whenever
#     state/.t3-captain-check is ten minutes old (bin/fm-watch.sh). It
#     arms the listener if it is not registered and confirms it listens;
#     publishes or closes kept reviews (bin/fm-t3-review.sh reconcile); one
#     full push; apply-pending; and every thread the list names
#     that now reads archived or gone, applied as thread-archived, in case
#     T3's record of it was lost; then drops every FirstMate archive mark
#     whose thread no task record, list item, or item thread names any more. FM_T3_CAPTAIN_SYNC_ARM=0 skips the arming,
#     for tests.
#   fm-t3-captain-sync.sh migrate [--t3-settings <settings.json>]
#     One-time move to the sidebar list: every kept review
#     (t3_review pending or waiting) is held To read (a decision already open
#     on it stays one); every report pinned to
#     the Bridge becomes an item with its report attached (its own task when
#     that is open: held To read, or left as it is when it already waits on
#     the captain; else a new To read item `read-<id>`), and is unpinned. A
#     report's link comes from T3's settings file when given (read only),
#     else data/<id>/report.md. Run it before T3 drops its Reports tools.
#     Repeating it changes nothing.
#
# Only a main home with config/t3code-token takes part, as in
# bin/fm-t3-needs-me.sh; elsewhere every verb exits 0 at once.
# Exit: 0; 1 a failure (a line says which); 2 usage; apply as above.
# Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SOURCE_ID=t3-captain-sync
OWN="$STATE/t3-captain-sync"
SENT="$STATE/t3-needs-me/list.json"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA"

usage() {
  sed -n '/^# Usage:/,/^#     Repeating it changes nothing./p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
taking_part() {
  [ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || return 1
  fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 && return 1
  return 0
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in listen|apply-pending|apply|check|migrate) ;; *) usage ;; esac
taking_part || exit 0
command -v jq >/dev/null 2>&1 || { echo "t3-captain-sync: jq is required"; exit 1; }
mkdir -p "$OWN" || { echo "t3-captain-sync: could not create $OWN"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-captain-sync.XXXXXX") || { echo "t3-captain-sync: no temporary directory"; exit 1; }
ACTIONS_LOCK="$OWN/actions.lock"
ACTIONS_LOCK_HELD=0
ATTEMPTS="$OWN/attempts.json"
ACTION_ATTEMPTS=3
release_actions_lock() {
  [ "$ACTIONS_LOCK_HELD" = 0 ] || fm_lock_release "$ACTIONS_LOCK" || true
  ACTIONS_LOCK_HELD=0
}
trap 'release_actions_lock; rm -rf -- "$WORK"' EXIT

hold() { "$SCRIPT_DIR/fm-captain-hold.sh" "$@" </dev/null; }
# shellcheck source=bin/fm-t3-review-lib.sh
. "$SCRIPT_DIR/fm-t3-review-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
mcp() {
  fm_backend_source t3code >/dev/null 2>&1 || { echo "the T3 adapter could not load" >&2; return 1; }
  fm_backend_t3code_mcp "$@" </dev/null
}

# True when FirstMate archived <thread> itself (bin/backends/t3code.sh).
archived_by_firstmate() {  # <thread>
  fm_backend_source t3code >/dev/null 2>&1 || return 1
  [ -e "$(fm_backend_t3code_archive_mark "$1")" ]
}

# The task whose record names <thread>, if exactly one does.
thread_task() {
  local meta id found=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    if [ "$(sed -n 's/^t3_thread_id=//p' "$meta" | tail -n 1)" = "$1" ]; then
      [ -z "$found" ] || return 1
      found=$id
    fi
  done
  [ -n "$found" ] && printf '%s\n' "$found"
}

leave_wind_down_wake() {  # <worker> <item>
  local reason="check: t3-captain $1: the captain archived decision $2 on $1's card while $1 was still working, so $2 was closed as not pursued; wind $1 down through its normal safe cleanup, never discarding unlanded work without asking"
  { printf '%s\n' "$reason" > "$OWN/$1.wake.tmp" && mv -f "$OWN/$1.wake.tmp" "$OWN/$1.wake"; } \
    || echo "t3-captain-sync: could not leave the wind-down notice for $1" >&2
}

cmd_apply() {
  local file='' id type at until thread finished kind worker review out rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -f "$file" ] || usage
  id=$(jq -r '.itemId // ""' "$file") || return 1
  type=$(jq -r '.type // ""' "$file")
  at=$(jq -r '.at // ""' "$file")
  until=$(jq -r '.until // ""' "$file")
  valid_id "$id" || { echo "the item id $id is not one FirstMate uses"; return 3; }
  thread=$(jq -r --arg id "$id" '[.items[]? | select(.id == $id)][0].thread.id // ""' "$SENT" 2>/dev/null)
  finished=$(jq -r --arg id "$id" '[.items[]? | select(.id == $id)][0].thread.finished | if . == false then false else true end' "$SENT" 2>/dev/null)
  kind=$(jq -r --arg id "$id" '[.items[]? | select(.id == $id)][0].kind // ""' "$SENT" 2>/dev/null)
  case "$type" in
    snooze)
      if [ -n "$until" ]; then
        out=$(hold snooze "$id" --at "$at" --until "$until" 2>&1) || rc=$?
      else
        out=$(hold snooze "$id" --at "$at" 2>&1) || rc=$?
      fi
      ;;
    unsnooze) out=$(hold unsnooze "$id" 2>&1) || rc=$? ;;
    archive|thread-archived)
      if [ "$type" = thread-archived ] && [ -n "$thread" ] && archived_by_firstmate "$thread"; then
        echo "FirstMate archived $id's thread itself, so $id stays open"
        return 0
      fi
      worker=''
      [ -z "$thread" ] || worker=$(thread_task "$thread") || worker=''
      review=''
      [ -z "$worker" ] || review=$(fm_t3_review_state "$STATE/$worker.meta")
      if [ -n "$review" ] && [ "$type" = archive ]; then
        out=$(mcp archive --thread "$thread" 2>&1) || rc=$?
      fi
      if [ "$rc" = 0 ] && [ -n "$review" ]; then
        out=$("$SCRIPT_DIR/fm-t3-review.sh" closed "$worker" --at "$at" </dev/null 2>&1) || rc=$?
      fi
      if [ "$rc" = 0 ]; then
        out=$(hold archive "$id" --at "$at" 2>&1) || rc=$?
      fi
      if [ "$rc" = 0 ] && [ -n "$worker" ] && [ -z "$review" ] && [ "$finished" = false ] && [ "$kind" = decision ]; then
        leave_wind_down_wake "$worker" "$id"
      fi
      ;;
    thread-unarchived) out="nothing to do for a restored thread" ;;
    *) echo "FirstMate does not know the action $type"; return 3 ;;
  esac
  if [ "$rc" = 0 ]; then
    printf '%s\n' "$out" | tail -n 1
    return 0
  fi
  # A refusal from the backlog is about the item, not a passing failure.
  case "$out" in
    *'is already closed'*|*'is not held for the captain'*|*'is absent from'*)
      printf '%s\n' "$out" | grep . | tail -n 1 | sed 's/^fm-captain-hold: //' | cut -c1-500
      return 3
      ;;
  esac
  printf '%s\n' "$out" | grep . | tail -n 1 >&2
  return 1
}

# apply-pending: see the header.
apply_pending() {
  local rc=0 n i seq item type out acks='[]' arc held=' ' tries waiting=0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait_max "$ACTIONS_LOCK" 60 \
    || { echo "t3-captain-sync: another round still holds the captain's actions; they wait for the next"; return 75; }
  ACTIONS_LOCK_HELD=1
  mcp actions --after 0 --wait-ms 0 > "$WORK/actions.json" 2>"$WORK/actions.err" || rc=$?
  case "$rc" in
    0) ;;
    4) release_actions_lock; return 0 ;;
    *) release_actions_lock; echo "t3-captain-sync: the captain's actions could not be read: $(head -n 1 "$WORK/actions.err")"; return 1 ;;
  esac
  jq -e 'type == "object"' "$ATTEMPTS" >/dev/null 2>&1 || echo '{}' > "$ATTEMPTS"
  # Counts of actions T3 no longer holds are forgotten.
  jq --slurpfile a "$WORK/actions.json" '($a[0].actions | map(.seq | tostring)) as $live
    | with_entries(select(.key as $k | $live | index($k)))' "$ATTEMPTS" > "$WORK/attempts.json" \
    && mv -f "$WORK/attempts.json" "$ATTEMPTS"
  n=$(jq '.actions | length' "$WORK/actions.json")
  i=0
  while [ "$i" -lt "$n" ]; do
    jq -c "[.actions[]] | sort_by(.seq) | .[$i]" "$WORK/actions.json" > "$WORK/action.json"
    i=$((i + 1))
    seq=$(jq -r '.seq' "$WORK/action.json")
    item=$(jq -r '.itemId // ""' "$WORK/action.json")
    type=$(jq -r '.type // ""' "$WORK/action.json")
    case "$held" in
      *" $item "*) waiting=1; echo "t3-captain-sync: $type on $item (#$seq) waits for the action before it"; continue ;;
    esac
    arc=0
    out=$(cmd_apply --file "$WORK/action.json" 2>&1) || arc=$?
    if [ "$arc" != 0 ] && [ "$arc" != 3 ]; then
      tries=$(( $(jq -r --arg s "$seq" '.[$s] // 0' "$ATTEMPTS") + 1 ))
      if [ "$tries" -ge "$ACTION_ATTEMPTS" ]; then
        arc=3
        out="FirstMate could not apply this: $out"
      else
        jq --arg s "$seq" --argjson n "$tries" '.[$s] = $n' "$ATTEMPTS" > "$WORK/attempts.json" && mv -f "$WORK/attempts.json" "$ATTEMPTS"
        held="$held$item "
        waiting=1
        echo "t3-captain-sync: $type on $item (#$seq) failed, attempt $tries: $out"
        continue
      fi
    fi
    jq --arg s "$seq" 'del(.[$s])' "$ATTEMPTS" > "$WORK/attempts.json" && mv -f "$WORK/attempts.json" "$ATTEMPTS"
    if [ "$arc" = 0 ]; then
      acks=$(jq -c --argjson seq "$seq" '. + [{seq: $seq, outcome: "applied"}]' <<< "$acks")
      echo "t3-captain-sync: applied $type on $item (#$seq)"
    else
      acks=$(jq -c --argjson seq "$seq" --arg m "$out" '. + [{seq: $seq, outcome: "refused", message: ($m | .[:500])}]' <<< "$acks")
      echo "t3-captain-sync: refused $type on $item (#$seq): $out"
    fi
  done
  if [ "$acks" != '[]' ]; then
    "$SCRIPT_DIR/fm-t3-needs-me.sh" sync </dev/null >/dev/null 2>&1 || true
    printf '%s\n' "$acks" > "$WORK/ack.json"
    mcp actions --after 0 --wait-ms 0 --ack-file "$WORK/ack.json" >/dev/null 2>"$WORK/actions.err" \
      || { release_actions_lock; echo "t3-captain-sync: the applied actions could not be acknowledged: $(head -n 1 "$WORK/actions.err")"; return 1; }
  fi
  release_actions_lock
  [ "$waiting" = 0 ] || return 75
}

# Every listed thread that now reads archived or gone, applied as T3 would
# have logged it.
lost_archives() {
  local id thread out rc=0 now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -f "$SENT" ] || return 0
  while IFS=$'\t' read -r id thread; do
    [ -n "$id" ] && [ -n "$thread" ] || continue
    out=$(mcp state --thread "$thread" 2>/dev/null) || continue
    if [ "$(printf '%s' "$out" | jq -r '.exists')" = false ] || [ "$(printf '%s' "$out" | jq -r '.archived')" = true ]; then
      jq -n --arg id "$id" --arg at "$now" '{seq: 1, itemId: $id, revision: 1, type: "thread-archived", at: $at}' > "$WORK/lost.json"
      cmd_apply --file "$WORK/lost.json" >/dev/null 2>"$WORK/lost.err" \
        || { echo "t3-captain-sync: $id's archived thread could not be applied: $(head -n 1 "$WORK/lost.err")"; rc=1; }
    fi
  done <<< "$(jq -r '.items[]? | select(.thread != null) | [.id, .thread.id] | @tsv' "$SENT")"
  return "$rc"
}

# FirstMate's archive marks outlive their task record only while the list or
# an item thread still names their thread.
prune_archive_marks() {
  local dir mark named
  fm_backend_source t3code >/dev/null 2>&1 || return 0
  dir=$(fm_backend_t3code_archive_mark x)
  dir=${dir%/*}
  [ -d "$dir" ] || return 0
  named=$( {
    jq -r '.items[]?.thread.id // empty' "$SENT" 2>/dev/null
    jq -r '.[]? | strings' "$STATE/t3-needs-me/threads.json" 2>/dev/null
    for mark in "$STATE"/*.meta; do [ -f "$mark" ] && sed -n 's/^t3_thread_id=//p' "$mark"; done
  } | while IFS= read -r mark; do
    [ -z "$mark" ] || basename "$(fm_backend_t3code_archive_mark "$mark")"
  done )
  for mark in "$dir"/*; do
    [ -f "$mark" ] || continue
    printf '%s\n' "$named" | grep -qxF -- "${mark##*/}" || rm -f -- "$mark"
  done
}

# Registered once: registering again would start a new generation.
# FM_T3_CAPTAIN_SYNC_ARM=0 leaves the listener alone (tests).
arm() {
  [ "${FM_T3_CAPTAIN_SYNC_ARM:-1}" != 0 ] || return 0
  [ -f "$STATE/procevent/$SOURCE_ID.source" ] \
    || "$SCRIPT_DIR/fm-procevent.sh" register "$SOURCE_ID" "$SOURCE_ID" -- "$SCRIPT_DIR/fm-t3-captain-sync.sh" listen >/dev/null \
    || { echo "t3-captain-sync: the listener could not be registered"; return 1; }
  "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$SOURCE_ID" >/dev/null 2>&1 \
    || { echo "t3-captain-sync: the listener did not confirm it is listening; the watcher's next cycle starts it"; return 1; }
}

cmd_check() {
  local rc=0
  [ "$#" = 0 ] || usage
  arm || rc=1
  "$SCRIPT_DIR/fm-t3-review.sh" reconcile </dev/null || rc=1
  "$SCRIPT_DIR/fm-t3-needs-me.sh" sync </dev/null || rc=1
  apply_pending || rc=1
  lost_archives || rc=1
  prune_archive_marks
  return "$rc"
}

cmd_listen() {
  local file=''
  [ "$#" = 0 ] || usage
  command -v node >/dev/null 2>&1 || { echo "t3-captain-sync: node is required" >&2; sleep 60; exit 1; }
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  if fm_backlog_tasks_axi_addressing "$DATA" 2>/dev/null; then file=$FM_BACKLOG_AXI_FILE; fi
  exec node "$SCRIPT_DIR/fm-t3-captain-sync.mjs" --home "$FM_HOME" --state "$STATE" --data "$DATA" \
    --config "$CONFIG" --backlog "$file" --bin "$SCRIPT_DIR"
}

# The first line of a kept review's summary, from its newest handoff.
review_summary() {  # <id>
  local f='' n best=0 candidate
  for candidate in "$DATA/$1"/handoff-r*.md; do
    [ -f "$candidate" ] || continue
    n=${candidate##*/handoff-r}
    n=${n%.md}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$best" ] || { best=$n; f=$candidate; }
  done
  [ -n "$f" ] || return 1
  awk 'found && NF { print; exit } /^\*\*Firstmate summary\*\*/ { found = 1 }' "$f" | cut -c1-4000
}

cmd_migrate() {
  local settings='' meta id review reason rc=0 pinned n i title location item summary
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --t3-settings) settings=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    review=$(fm_t3_review_state "$meta")
    case "$review" in pending|waiting) ;; *) continue ;; esac
    reason=$(review_summary "$id") || reason="Report ready: data/$id/report.md"
    if hold hold "$id" --read --reason "$reason" >/dev/null 2>"$WORK/hold.err"; then
      echo "t3-captain-sync: kept review $id waits on the captain"
    else
      echo "t3-captain-sync: kept review $id could not be held To read: $(grep . "$WORK/hold.err" | tail -n 1)"
      rc=1
    fi
  done
  # The pinned reports: unpinning an id nobody pinned answers the whole list.
  pinned=$(mcp reports-unpin --id fm-migrate-list 2>"$WORK/unpin.err") || {
    if [ "$(printf '%s' "$pinned" | jq -r '.error.code // ""' 2>/dev/null)" = reports_unsupported ]; then
      echo "t3-captain-sync: this T3 has no pinned reports to move"
      return "$rc"
    fi
    echo "t3-captain-sync: the pinned reports could not be read: $(head -n 1 "$WORK/unpin.err")"
    return 1
  }
  n=$(printf '%s' "$pinned" | jq '.reports | length')
  i=0
  while [ "$i" -lt "$n" ]; do
    id=$(printf '%s' "$pinned" | jq -r ".reports[$i].id")
    title=$(printf '%s' "$pinned" | jq -r ".reports[$i].title")
    i=$((i + 1))
    location=''
    summary=''
    if [ -n "$settings" ] && [ -f "$settings" ]; then
      location=$(jq -r --arg id "$id" '.pinnedReports[$id].location // ""' "$settings" 2>/dev/null)
      summary=$(jq -r --arg id "$id" '.pinnedReports[$id].summary // ""' "$settings" 2>/dev/null)
    fi
    if valid_id "$id" && [ -z "$location" ] && [ -f "$DATA/$id/report.md" ]; then location="$DATA/$id/report.md"; fi
    [ -n "$summary" ] || summary=$title
    if valid_id "$id" && hold open "$id" >/dev/null 2>&1; then
      # Already an open item: a decision stays one, since reading is part of
      # deciding.
      item=$id
    elif valid_id "$id" && "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null | grep -q '^  state: \(queued\|in_flight\)$'; then
      item=$id
      hold hold "$item" --read --reason "$summary" >/dev/null 2>"$WORK/hold.err" \
        || { echo "t3-captain-sync: pinned report $id could not be held To read: $(grep . "$WORK/hold.err" | tail -n 1)"; rc=1; continue; }
    else
      item="read-$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
      hold hold "$item" --read --title "$(printf '%s' "$title" | tr '\n' ' ' | cut -c1-200)" --reason "$summary" >/dev/null 2>"$WORK/hold.err" \
        || { echo "t3-captain-sync: pinned report $id could not be held To read: $(grep . "$WORK/hold.err" | tail -n 1)"; rc=1; continue; }
    fi
    if [ -n "$location" ]; then
      printf '%s\n' "$summary" > "$WORK/summary.md"
      # An item already raised with other words keeps them; the report then
      # stays where its raise points.
      hold context "$item" --text-file "$WORK/summary.md" --attach "report=$location" --label "$(printf '%s' "$title" | cut -c1-200)" >/dev/null 2>"$WORK/ctx.err" \
        || echo "t3-captain-sync: pinned report $id's link was not attached to $item: $(grep . "$WORK/ctx.err" | tail -n 1)"
    fi
    mcp reports-unpin --id "$id" >/dev/null 2>"$WORK/unpin.err" \
      || { echo "t3-captain-sync: pinned report $id could not be unpinned: $(head -n 1 "$WORK/unpin.err")"; rc=1; continue; }
    echo "t3-captain-sync: pinned report $id is To read as $item and unpinned"
  done
  return "$rc"
}

case "$VERB" in
  listen) cmd_listen "$@" ;;
  apply-pending) [ "$#" = 0 ] || usage; apply_pending ;;
  apply) cmd_apply "$@" ;;
  check) cmd_check "$@" ;;
  migrate) cmd_migrate "$@" ;;
esac
