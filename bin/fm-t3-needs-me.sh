#!/usr/bin/env bash
# fm-t3-needs-me.sh - keep the captain's T3 decision threads in line with his
# open captain calls (docs/t3code-backend.md "Decision threads").
#
# Each captain-held task gets one agent-less T3 thread under FirstMate's own,
# carrying the call's question, options, its project (the task's repo), and
# the words Firstmate raised and
# updated it with, so the captain's sidebar shows what needs him. The
# wanted state comes from structured records only: the backlog's captain holds
# and their hold_bucket (bin/fm-fleet-snapshot.sh), the call's context record
# (data/needs-me/<task-id>.json, written only by bin/fm-captain-hold.sh
# context), and this script's own sync records. No prose is read.
#
# Usage:
#   fm-t3-needs-me.sh sync
#     bin/fm-captain-hold.sh runs this after every hold, answer, reconcile, and
#     context, and bin/fm-watch.sh about once a minute. One pass, one T3 call.
#   fm-t3-needs-me.sh status
#     Read-only, no T3 call: whether the last pass matched the records, how
#     many decisions wait in the sidebar, and which of them are new
#     or changed since `mentioned` last recorded them. Prints
#       in_sync: yes|no
#       waiting: <n>
#     then one TAB-separated line per waiting decision not yet mentioned at
#     its current revision: new <task-id> <title>, or changed <task-id>
#     <title> <the newest update's one-line what-changed>.
#   fm-t3-needs-me.sh mentioned <task-id>...
#     Records that Firstmate named these decisions to the captain at their
#     current revision, so status stops listing them until they change.
#   fm-t3-needs-me.sh reply-task [<message-file>]
#     Prints the task id a captain reply from a decision thread names on its
#     `needs-me-task: <task-id>` line (stdin without a file). Exit 1 when the
#     message names none, 2 when it names more than one or a malformed id.
#
# Wanted state, per task: a live or aged hold is an active thread (top level; a
# call that has waited long still waits on him); a dated hold (--until) is
# snoozed until 00:00 UTC on that date, when the snapshot's bucket turns live; a
# blocked hold is parked in Settled, kept, and un-settled when it unblocks; a call
# that closed or was released is settled, then archived a day after that
# settle was proven. The payload is the context record from this hold (same
# hold-set stamp) or, without one, the hold reason as the question and the
# only entry. The payload's revision is the record's plus one (1 with no
# record), always positive as T3 requires, so every raise and update reaches
# T3 as a new revision. A pass marks a thread unread when the newest entry is
# an update at a revision the thread had not had.
#
# Level-triggered, like bin/fm-t3-captain-label.sh: a pass compares each task's
# wanted state, hashed, with the hash its last proven pass stored under
# state/t3-needs-me/<task-id>.json, and reads every recorded thread back.
# A changed hash applies the whole state; an equal one only restores a lost
# payload, so a thread the captain settled (as his reply does), snoozed, or
# archived himself stays so until Firstmate's records change. A failed call,
# a lost reply, or a T3 restart keeps the old hash, and the next pass applies
# it again; thread creation is retried under the same request id, so it lands
# on the thread T3 already made. An item that failed three times in a row is
# retried every 15 minutes rather than every pass. A pass whose every item
# was proven writes state/t3-needs-me/.synced, the hash of the whole wanted
# set, which is what status compares. state/needs-me-mentioned/<task-id>
# holds "<hold-set>#<revision>" as last named in chat.
#
# Only a main home with config/t3code-token takes part: a secondmate's calls
# reach the captain through its parent. With no FirstMate thread in T3 (none
# pinned as coordinator and none live), a pass changes nothing. A T3 without
# decision threads makes sync a no-op.
#
# Exit: 0, or 1 when the records could not be read or a decision could not be
# brought in line (a line on stdout says which; the next pass retries); usage
# errors exit 2. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONTEXTS="$DATA/needs-me"
SYNCS="$STATE/t3-needs-me"
MENTIONED="$STATE/needs-me-mentioned"
NOW=${FM_NEEDS_ME_NOW:-$(date +%s)}
ARCHIVE_AFTER=86400
BACKOFF_FAILURES=3
BACKOFF_SECONDS=900

usage() {
  sed -n '13,32p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB:$#" in
  sync:0|status:0|reply-task:0|reply-task:1) ;;
  mentioned:*) [ "$#" -ge 1 ] || usage ;;
  *) usage ;;
esac

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

slug_ok() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

if [ "$VERB" = reply-task ]; then
  ids=$(sed -n 's/^[[:space:]>]*needs-me-task:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' ${1:+"$1"} | sort -u)
  [ -n "$ids" ] || exit 1
  [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] || { echo "reply names more than one task: $(printf '%s' "$ids" | tr '\n' ' ')" >&2; exit 2; }
  slug_ok "$ids" || { echo "reply names a malformed task id: $ids" >&2; exit 2; }
  printf '%s\n' "$ids"
  exit 0
fi

# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
taking_part() {
  [ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || return 1
  fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 && return 1
  return 0
}

if [ "$VERB" = mentioned ]; then
  for id in "$@"; do slug_ok "$id" || { echo "not a task id: $id" >&2; exit 2; }; done
fi

command -v jq >/dev/null 2>&1 || { echo "t3-needs-me: jq is required"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-needs-me.XXXXXX") || { echo "t3-needs-me: no temporary directory"; exit 1; }
LOCK_HELD=0
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$SYNCS/.lock" || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

# Every JSON object in <dir>/*.json, as one array; an unreadable file is left
# out rather than failing the pass.
slurp_dir() {  # <dir>
  local f
  for f in "$1"/*.json; do
    [ -f "$f" ] || continue
    jq -c 'select(type == "object")' "$f" 2>/dev/null
  done | jq -s '.'
}

# The wanted state, one item per task, into $WORK/plan.json, and each item's
# hash beside it in $WORK/hashes.tsv (task id, hash).
plan() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$WORK/snapshot.json" 2>"$WORK/snapshot.err" \
    || { echo "t3-needs-me: the backlog could not be read: $(head -n 1 "$WORK/snapshot.err")"; return 1; }
  slurp_dir "$CONTEXTS" > "$WORK/contexts.json" || return 1
  slurp_dir "$SYNCS" > "$WORK/locals.json" || return 1
  jq -n --slurpfile snap "$WORK/snapshot.json" --slurpfile ctx "$WORK/contexts.json" \
    --slurpfile loc "$WORK/locals.json" --arg home "$FM_HOME" --argjson now "$NOW" --argjson archiveAfter "$ARCHIVE_AFTER" '
    def iso: if . == null then null elif test("T") then . else . + "T00:00:00Z" end;
    def abs: if .kind == "link" or (.path | startswith("/")) then . else .path = ($home + "/" + .path) end;
    def entry: {at, kind} + (if .changed then {changed} else {} end) + {text}
      + {attachments: [(.attachments // [])[] | abs | {kind, path} + (if .label then {label} else {} end)]};
    ([$snap[0].backlog.records[]? | select(.structured and .hold_kind == "captain" and .state != "done")]) as $held
    | ($ctx[0] | map({key: .taskId, value: .}) | from_entries) as $ctxs
    | ($loc[0] | map(select(.taskId != null)) | map({key: .taskId, value: .}) | from_entries) as $locs
    | ([$held[] | .id]) as $heldIds
    | [ ($held[]
         | . as $r
         | ($ctxs[$r.id] | if . != null and .holdSet == ($r.hold_set // "") then . else null end) as $c
         | ($locs[$r.id]) as $l
         | (if $c != null and ($c.entries | length) > 0 then $c.entries else
              [{at: ($r.hold_set // $r.since | iso), kind: "raised", text: ($r.hold_reason[:8192]), attachments: []}] end) as $entries
         | (if $r.hold_bucket == "live" or $r.hold_bucket == "aged" then "active" elif $r.hold_bucket == "dated" then "snoozed" else "parked" end) as $phase
         | {taskId: $r.id, title: ($r.title[:200]), phase: $phase,
            snoozedUntil: (if $phase == "snoozed" then ($r.hold_until | iso) else null end),
            holdSet: ($r.hold_set // ""),
            decision: ({taskId: $r.id, title: ($r.title[:200])}
              + (if ($r.repo // "" | gsub("^\\s+|\\s+$"; "")) as $repo | $repo != "" and $repo != "-" then {projectName: ($r.repo[:200])} else {} end)
              + {question: ((($c.question // null) // $r.hold_reason)[:4000]),
              options: [($c.options // [])[] | {label} + (if .detail then {detail} else {} end)],
              entries: [$entries[] | entry],
              revision: (($c.revision // 0) + 1)}),
            newestKind: ($entries[-1].kind),
            newestChanged: ($entries[-1].changed // null),
            local: $l}),
        ($locs | to_entries[] | select(.key | IN($heldIds[]) | not) | .value
         | . as $l
         | {taskId: $l.taskId, title: ($l.title // $l.taskId),
            phase: (if $l.closedAt != null and ($now - $l.closedAt) >= $archiveAfter then "archived" else "closed" end),
            snoozedUntil: null, holdSet: ($l.holdSet // ""), decision: $l.decision,
            newestKind: null, newestChanged: null, local: $l})
      ]
  ' > "$WORK/plan.json" || { echo "t3-needs-me: the wanted state could not be built"; return 1; }
  : > "$WORK/hashes.tsv"
  local id wanted
  while IFS=$'\t' read -r id wanted; do
    [ -n "$id" ] || continue
    printf '%s\t%s\n' "$id" "$(printf '%s' "$wanted" | sha)" >> "$WORK/hashes.tsv"
  done <<< "$(jq -r '.[] | [.taskId, ({phase, snoozedUntil, decision} | tojson)] | @tsv' "$WORK/plan.json")"
}

# The hash of the whole wanted set (default: this plan's): what a fully proven
# pass stores and status compares.
set_hash() {  # [<hashes-tsv>]
  sort "${1:-$WORK/hashes.tsv}" | sha
}

if [ "$VERB" = status ] || [ "$VERB" = mentioned ]; then
  if ! taking_part; then
    [ "$VERB" = mentioned ] && exit 0
    printf 'in_sync: no\nwaiting: 0\n'
    exit 0
  fi
  plan || exit 1
  if [ "$VERB" = mentioned ]; then
    mkdir -p "$MENTIONED" || exit 1
    for id in "$@"; do
      mark=$(jq -r --arg id "$id" '.[] | select(.taskId == $id and .phase == "active") | "\(.holdSet)#\(.decision.revision)"' "$WORK/plan.json")
      [ -n "$mark" ] || continue
      printf '%s\n' "$mark" > "$MENTIONED/$id.tmp" && mv -f "$MENTIONED/$id.tmp" "$MENTIONED/$id"
    done
    exit 0
  fi
  synced=''
  [ ! -f "$SYNCS/.synced" ] || synced=$(cat "$SYNCS/.synced")
  if [ -n "$synced" ] && [ "$synced" = "$(set_hash)" ]; then echo 'in_sync: yes'; else echo 'in_sync: no'; fi
  printf 'waiting: %s\n' "$(jq '[.[] | select(.phase == "active")] | length' "$WORK/plan.json")"
  while IFS=$'\t' read -r id hold rev title changed; do
    [ -n "$id" ] || continue
    seen=''
    [ ! -f "$MENTIONED/$id" ] || seen=$(cat "$MENTIONED/$id")
    [ "$seen" != "$hold#$rev" ] || continue
    if [ "${seen%#*}" = "$hold" ] && [ -n "$seen" ]; then
      printf 'changed\t%s\t%s\t%s\n' "$id" "$title" "$changed"
    else
      printf 'new\t%s\t%s\n' "$id" "$title"
    fi
  done <<< "$(jq -r '.[] | select(.phase == "active") | [.taskId, .holdSet, .decision.revision, .title, (.newestChanged // "")] | @tsv' "$WORK/plan.json")"
  exit 0
fi

# --- sync ------------------------------------------------------------------

taking_part || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$SYNCS" || { echo "t3-needs-me: could not create $SYNCS"; exit 1; }
fm_lock_acquire_wait_max "$SYNCS/.lock" 30 || { echo "t3-needs-me: another pass holds the lock; the next pass catches up"; exit 0; }
LOCK_HELD=1
plan || exit 1

home_key=$(printf '%s' "$(cd "$FM_HOME" && pwd -P)" | sha | cut -c1-12)
parent=''
[ ! -f "$SYNCS/.parent" ] || parent=$(cat "$SYNCS/.parent")
jq -n --slurpfile plan "$WORK/plan.json" --rawfile hashes "$WORK/hashes.tsv" --arg root "$(cd "$FM_HOME" && pwd -P)" \
  --arg parent "$parent" --arg key "$home_key" --argjson now "$NOW" \
  --argjson failures "$BACKOFF_FAILURES" --argjson backoff "$BACKOFF_SECONDS" '
  ($hashes | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $h
  | {root: $root, parent: (if $parent == "" then null else $parent end),
     items: [$plan[0][]
       | . as $p
       | select(($p.local.failures // 0) < $failures or ($now - ($p.local.failedAt // 0)) >= $backoff)
       | {taskId, title, phase, snoozedUntil, decision,
          thread: ($p.local.thread // null), generation: ($p.local.generation // 0),
          requestId: "fm-needs-me:\($key):\($p.taskId)",
          apply: ($h[$p.taskId] != ($p.local.hash // null)),
          markUnread: ($p.local != null and ($p.local.holdSet // "") == $p.holdSet
            and $p.newestKind == "update" and ($p.decision.revision // 0) > ($p.local.revision // 0))}]}
' > "$WORK/input.json" || { echo "t3-needs-me: the pass could not be staged"; exit 1; }

# Nothing recorded and nothing held: no T3 call at all.
if [ "$(jq '.items | length' "$WORK/input.json")" = 0 ] && [ "$(jq 'length' "$WORK/plan.json")" = 0 ]; then
  set_hash > "$SYNCS/.synced"
  exit 0
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source t3code >/dev/null 2>&1 || { echo "t3-needs-me: the T3 adapter could not load"; exit 1; }
rc=0
fm_backend_t3code_mcp decisions --file "$WORK/input.json" > "$WORK/out.json" 2>"$WORK/out.err" || rc=$?
case "$rc" in
  0) ;;
  4) rm -f -- "$SYNCS/.synced"; exit 0 ;;
  *) echo "t3-needs-me: T3 could not take the pass: $(head -n 1 "$WORK/out.err"); the next pass retries"; rm -f -- "$SYNCS/.synced"; exit 1 ;;
esac
out_parent=$(jq -r '.parent // ""' "$WORK/out.json")
if [ -z "$out_parent" ]; then
  rm -f -- "$SYNCS/.synced"
  exit 0
fi
printf '%s\n' "$out_parent" > "$SYNCS/.parent.tmp" && mv -f "$SYNCS/.parent.tmp" "$SYNCS/.parent"

failed=0
: > "$WORK/kept.tsv"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  hash=$(awk -F '\t' -v id="$id" '$1 == id {print $2}' "$WORK/hashes.tsv")
  jq --arg id "$id" --arg hash "$hash" --argjson now "$NOW" --slurpfile plan "$WORK/plan.json" '
    (.items[] | select(.taskId == $id)) as $r
    | ($plan[0][] | select(.taskId == $id)) as $p
    | ($p.local // {}) as $l
    | if $r.ok then
        if $p.phase == "archived" or ($p.phase == "closed" and $r.thread == null) then {drop: true}
        else {record: {taskId: $id, title: $p.title, thread: $r.thread, generation: $r.generation, hash: $hash,
               phase: $p.phase, revision: ($p.decision.revision // 0), holdSet: $p.holdSet, decision: $p.decision,
               closedAt: (if $p.phase == "closed" then ($l.closedAt // $now) else null end),
               failures: 0, failedAt: null}}
        end
      else {failed: $r.error.message,
            record: ($l + {taskId: $id, title: $p.title, thread: $r.thread, generation: $r.generation,
                           decision: ($l.decision // $p.decision),
                           failures: (($l.failures // 0) + 1), failedAt: $now})}
      end
  ' "$WORK/out.json" > "$WORK/result.json" || { echo "t3-needs-me: the result for $id could not be read"; failed=1; continue; }
  if jq -e '.drop == true' "$WORK/result.json" >/dev/null; then
    rm -f -- "$SYNCS/$id.json"
    continue
  fi
  jq '.record' "$WORK/result.json" > "$SYNCS/.$id.tmp" && mv -f "$SYNCS/.$id.tmp" "$SYNCS/$id.json" \
    || { echo "t3-needs-me: could not record $id"; failed=1; }
  if jq -e '.failed != null' "$WORK/result.json" >/dev/null; then
    echo "t3-needs-me: decision $id: $(jq -r '.failed' "$WORK/result.json"); the next pass retries"
    failed=1
  else
    printf '%s\t%s\n' "$id" "$hash" >> "$WORK/kept.tsv"
  fi
done <<< "$(jq -r '.items[].taskId' "$WORK/out.json")"

# An item held back by the backoff is not proven this pass.
[ "$(jq '.items | length' "$WORK/input.json")" = "$(jq 'length' "$WORK/plan.json")" ] || failed=1
if [ "$failed" = 0 ]; then
  set_hash "$WORK/kept.tsv" > "$SYNCS/.synced"
else
  rm -f -- "$SYNCS/.synced"
fi

# A decision no longer waiting needs no mention record.
if [ -d "$MENTIONED" ]; then
  for f in "$MENTIONED"/*; do
    [ -f "$f" ] || continue
    jq -e --arg id "${f##*/}" 'any(.[]; .taskId == $id and .phase == "active")' "$WORK/plan.json" >/dev/null || rm -f -- "$f"
  done
fi
exit "$failed"
