#!/usr/bin/env bash
# fm-t3-needs-me.sh - keep the decisions on the captain's T3 Bridge tab in
# line with his open captain calls (docs/t3code-backend.md "Bridge decisions").
#
# Each open captain call is one decision on the Bridge, carrying the call's
# question, options, its project (the task's repo), when it started waiting
# (the hold's start), and the words Firstmate raised and updated it with. The
# wanted state comes from structured records only: the backlog's captain holds
# and their hold_bucket (bin/fm-fleet-snapshot.sh), the call's context record
# (data/needs-me/<task-id>.json, written only by bin/fm-captain-hold.sh
# context). No prose is read.
#
# Usage:
#   fm-t3-needs-me.sh sync
#     bin/fm-captain-hold.sh runs this after every hold, answer, reconcile, and
#     context, before it returns, and bin/fm-watch.sh about once a minute as
#     the backstop. One pass, one T3 session, and one more each when the
#     objectives, the routing table or the rules changed.
#   fm-t3-needs-me.sh reply-task [<message-file>]
#     Prints the task id a captain reply from the Bridge names on its
#     `needs-me-task: <task-id>` line (stdin without a file). Exit 1 when the
#     message names none, 2 when it names more than one or a malformed id.
#
# Wanted state, per task: a live or aged hold is listed until it is answered
# or closed, however long it waits; a dated hold (--until) is listed with
# wakeAt 00:00 UTC on that date, so it waits under Scheduled until then; a
# blocked, answered, released, or closed call is left out. The payload is the
# context record from this hold (same hold-set stamp) or, without one, the
# hold reason as the question and the only entry. Its revision is the
# record's plus one (1 with no record), always positive as T3 requires, so
# every raise and update reaches T3 as a new revision.
#
# A pass sends the whole list in one t3_decisions_set call (bin/fm-t3-mcp.mjs
# decisions owns the call and its proof), so the Bridge changes in the same
# step as Firstmate's records. Only a list that is empty and was empty on the
# last accepted pass makes no call.
#
# A pass T3 does not take is reported on stdout and sent again on the next
# pass. The third such pass in a row also leaves its exact error, as a
# one-line wake reason, in state/t3-needs-me/.alert, which bin/fm-watch.sh
# turns into a `check: t3-decisions` wake for firstmate. It is written once
# per run of failures, which state/t3-needs-me/.decisions counts, and the
# next accepted pass deletes it.
#
# Each sync pass also pushes the captain's high level objectives, as
# bin/fm-objectives.sh reads them, to the top of T3's Bridge tab
# (docs/t3code-backend.md "Objectives"), only when the payload bin/fm-t3-mcp.mjs
# objectives-payload builds from them differs from the last proven push,
# whose hash state/t3-needs-me/.objectives keeps; an absent file, or one with
# no bullets, clears them once. A failed push is reported and retried three
# times in a row, then every 15 minutes, and never holds the decisions back;
# a T3 without objectives is retried the same way, quietly.
#
# The model routing table follows the same way (docs/t3code-backend.md "Model
# routing"): the table bin/fm-t3-mcp.mjs routing-payload builds from
# config/crew-dispatch.json is pushed with t3_routing_set when it differs from
# the last proven push, whose hash state/t3-needs-me/.routing keeps, with the
# same retries and back-off. An absent or unreadable file clears the table
# once, and only if one was sent; a malformed one is reported every pass and
# leaves the Bridge's table as it was.
#
# The captain's rules follow the same way (docs/t3code-backend.md "Rules"):
# the list bin/fm-t3-mcp.mjs rules-payload validates from
# data/rules/inventory.json is pushed with t3_rules_set when it differs from
# the last proven push, whose hash state/t3-needs-me/.rules keeps. An absent
# or unreadable file clears the list once, and only if one was sent; a
# malformed one is reported every pass and leaves the Bridge's rules as they
# were.
#
# Only a main home with config/t3code-token takes part: a secondmate's calls
# reach the captain through its parent. With no FirstMate thread in T3 (none
# pinned as coordinator and none live), a pass changes no decision, since a
# reply would have nowhere to go, and a T3 without t3_decisions_set is not
# supported, so its pass leaves the decisions alone and reports nothing, as an
# unsupported objectives, routing or rules push does; those pushes still run
# in both cases.
#
# Exit: 0, or 1 when the records could not be read, a decision could not be
# brought in line, or the objectives, routing table or rules could not be pushed (a
# line on stdout says which; the next pass retries); usage errors exit 2.
# Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONTEXTS="$DATA/needs-me"
SYNCS="$STATE/t3-needs-me"
OBJECTIVES_SYNC="$SYNCS/.objectives"
ROUTING_SYNC="$SYNCS/.routing"
RULES_SYNC="$SYNCS/.rules"
RULES_INVENTORY="$DATA/rules/inventory.json"
DECISIONS_SYNC="$SYNCS/.decisions"
ALERT="$SYNCS/.alert"
NOW=${FM_NEEDS_ME_NOW:-$(date +%s)}
BACKOFF_FAILURES=3
BACKOFF_SECONDS=900
ALERT_AFTER=3

usage() {
  sed -n '13,22p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB:$#" in
  sync:0|reply-task:0|reply-task:1) ;;
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

# The wanted list, one decision per open captain call the captain can answer,
# into $WORK/list.json.
plan() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$WORK/snapshot.json" 2>"$WORK/snapshot.err" \
    || { echo "t3-needs-me: the backlog could not be read: $(head -n 1 "$WORK/snapshot.err")"; return 1; }
  slurp_dir "$CONTEXTS" > "$WORK/contexts.json" || return 1
  jq -n --slurpfile snap "$WORK/snapshot.json" --slurpfile ctx "$WORK/contexts.json" --arg home "$FM_HOME" '
    def iso: if . == null then null elif test("T") then . else . + "T00:00:00Z" end;
    def abs: if .kind == "link" or (.path | startswith("/")) then . else .path = ($home + "/" + .path) end;
    def entry: {at, kind} + (if .changed then {changed} else {} end) + {text}
      + {attachments: [(.attachments // [])[] | abs | {kind, path} + (if .label then {label} else {} end)]};
    ($ctx[0] | map({key: .taskId, value: .}) | from_entries) as $ctxs
    | [ $snap[0].backlog.records[]?
        | select(.structured and .hold_kind == "captain" and .state != "done")
        | select(.hold_bucket == "live" or .hold_bucket == "aged" or .hold_bucket == "dated")
        | . as $r
        | ($ctxs[$r.id] | if . != null and .holdSet == ($r.hold_set // "") then . else null end) as $c
        | (if $c != null and ($c.entries | length) > 0 then $c.entries else
             [{at: ($r.hold_set // $r.since | iso), kind: "raised", text: ($r.hold_reason[:8192]), attachments: []}] end) as $entries
        | {id: $r.id, title: ($r.title[:200])}
          + (if ($r.repo // "" | gsub("^\\s+|\\s+$"; "")) as $repo | $repo != "" and $repo != "-" then {projectName: ($r.repo[:200])} else {} end)
          + (if ($r.hold_set // "") != "" then {since: ($r.hold_set | iso)} else {} end)
          + {question: ((($c.question // null) // $r.hold_reason)[:4000]),
             options: [($c.options // [])[] | {label}],
             entries: [$entries[] | entry],
             revision: (($c.revision // 0) + 1)}
          + (if $r.hold_bucket == "dated" and $r.hold_until != null then {wakeAt: ($r.hold_until | iso)} else {} end)
      ]
  ' > "$WORK/list.json" || { echo "t3-needs-me: the wanted state could not be built"; return 1; }
}

# --- sync ------------------------------------------------------------------

taking_part || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$SYNCS" || { echo "t3-needs-me: could not create $SYNCS"; exit 1; }
fm_lock_acquire_wait_max "$SYNCS/.lock" 30 || { echo "t3-needs-me: another pass holds the lock; the next pass catches up"; exit 0; }
LOCK_HELD=1

# The record of the last decisions passes, {empty, failures, failedAt,
# error}: empty says the last accepted pass had nothing to show, and failures
# counts the passes T3 has not taken since. {} when absent or unreadable.
decisions_record() {
  local rec=''
  [ ! -f "$DECISIONS_SYNC" ] || rec=$(jq -c 'select(type == "object")' "$DECISIONS_SYNC" 2>/dev/null) || rec=''
  [ -n "$rec" ] || rec='{}'
  printf '%s\n' "$rec"
}

write_decisions_record() {  # <json>
  printf '%s\n' "$1" > "$DECISIONS_SYNC.tmp" && mv -f "$DECISIONS_SYNC.tmp" "$DECISIONS_SYNC"
}

# T3 took the pass: the run of failures ends and any unread alert goes with it.
pass_taken() {  # <empty: true|false>
  write_decisions_record "$(jq -cn --argjson empty "$1" \
    '{empty: $empty, failures: 0, failedAt: null, error: null}')" \
    || echo "t3-needs-me: could not record the pass"
  rm -f -- "$ALERT"
}

# T3 did not take the pass: reported, counted, and on the third in a row left
# for the watcher to wake firstmate with.
pass_refused() {  # <error>
  local error=$1 failures reason
  failures=$(( $(decisions_record | jq -r '.failures // 0') + 1 ))
  write_decisions_record "$(decisions_record | jq -c --argjson failures "$failures" --argjson now "$NOW" --arg error "$error" \
    '. + {failures: $failures, failedAt: $now, error: $error}')" \
    || echo "t3-needs-me: could not record the failed pass"
  echo "t3-needs-me: T3 could not take the decisions: $error; the next pass retries"
  [ "$failures" = "$ALERT_AFTER" ] || return 0
  reason="check: t3-decisions: T3 did not take the captain's decisions $failures passes in a row: $error"
  { printf '%s' "$reason" | fm_wake_clean_field && printf '\n'; } > "$ALERT.tmp" && mv -f "$ALERT.tmp" "$ALERT" \
    || echo "t3-needs-me: could not leave the alert for firstmate"
}

# One pass over the decisions; 0, or 1 when one was not brought in line.
sync_decisions() {
  local parent out_parent failed=0 id message rc=0
  plan || return 1

  parent=''
  [ ! -f "$SYNCS/.parent" ] || parent=$(cat "$SYNCS/.parent")
  jq -n --slurpfile list "$WORK/list.json" --arg root "$(cd "$FM_HOME" && pwd -P)" --arg parent "$parent" \
    '{root: $root, parent: (if $parent == "" then null else $parent end), list: $list[0]}' > "$WORK/input.json" \
    || { echo "t3-needs-me: the pass could not be staged"; return 1; }

  # Nothing to show, and nothing shown since the last accepted pass: no T3
  # call at all.
  if decisions_record | jq -e --slurpfile list "$WORK/list.json" \
    '.empty == true and (.failures // 0) == 0 and $list[0] == []' >/dev/null; then
    return 0
  fi

  fm_backend_t3code_mcp decisions --file "$WORK/input.json" > "$WORK/out.json" 2>"$WORK/out.err" || rc=$?
  case "$rc" in
    0) ;;
    4) return 0 ;;
    *) pass_refused "$(head -n 1 "$WORK/out.err" | grep . || echo "exit $rc")"; return 1 ;;
  esac
  out_parent=$(jq -r '.parent // ""' "$WORK/out.json")
  if [ -z "$out_parent" ]; then
    # No FirstMate thread: T3 took the pass, and nothing changed.
    pass_taken "$(decisions_record | jq '.empty == true')"
    return 0
  fi
  printf '%s\n' "$out_parent" > "$SYNCS/.parent.tmp" && mv -f "$SYNCS/.parent.tmp" "$SYNCS/.parent"
  pass_taken "$(jq 'length == 0' "$WORK/list.json")"

  while IFS=$'\t' read -r id message; do
    [ -n "$id$message" ] || continue
    echo "t3-needs-me: decision $id was left off the Bridge: $message"
    failed=1
  done <<< "$(jq -r '.rejected[]? | [(.id // "?"), .problem] | @tsv' "$WORK/out.json")"
  return "$failed"
}

# bridge_record <sync-file>: the last proven push's record of one Bridge feed
# ({hash, failures, failedAt, unsupported}), {} when there is none.
bridge_record() {
  local rec='{}'
  [ ! -f "$1" ] || rec=$(jq -c 'select(type == "object")' "$1" 2>/dev/null) || rec='{}'
  [ -n "$rec" ] || rec='{}'
  printf '%s\n' "$rec"
}

# push_bridge_feed <name> <verb> <sync-file> <payload-file> [<note>]: one
# Bridge feed (the objectives, the model routing table, the rules) follows its
# source: <payload-file> is hashed and sent with bin/fm-t3-mcp.mjs <verb>
# only when that hash differs from the last proven push in <sync-file>. A
# failed push keeps the old hash, so the next pass retries, three times in a
# row and then every BACKOFF_SECONDS, like a decision; a T3 without the feed's
# tool is retried the same way, quietly. <note>, when given, is printed after
# a proven push.
push_bridge_feed() {
  local name=$1 verb=$2 sync=$3 payload=$4 note=${5:-} rec hash rc=0
  hash=$(sha < "$payload")
  rec=$(bridge_record "$sync")
  [ "$(printf '%s' "$rec" | jq -r '.hash // ""')" != "$hash" ] || return 0
  if ! printf '%s' "$rec" | jq -e --argjson now "$NOW" --argjson failures "$BACKOFF_FAILURES" --argjson backoff "$BACKOFF_SECONDS" \
    '(.failures // 0) < $failures or ($now - (.failedAt // 0)) >= $backoff' >/dev/null; then
    # Held back: not proven this pass, which is no failure on a T3 without it.
    printf '%s' "$rec" | jq -e '.unsupported == true' >/dev/null
    return
  fi
  fm_backend_t3code_mcp "$verb" --file "$payload" > "$WORK/$name-out.json" 2>"$WORK/$name-out.err" || rc=$?
  if [ "$rc" = 0 ]; then
    if ! { jq -n --arg hash "$hash" '{hash: $hash, failures: 0, failedAt: null, unsupported: false}' > "$sync.tmp" \
      && mv -f "$sync.tmp" "$sync"; }; then
      echo "t3-needs-me: $name: could not record the push"
      return 1
    fi
    [ -z "$note" ] || echo "t3-needs-me: $name: $note"
    return 0
  fi
  printf '%s' "$rec" | jq --argjson now "$NOW" --argjson unsupported "$([ "$rc" = 4 ] && echo true || echo false)" \
    '. + {failures: ((.failures // 0) + 1), failedAt: $now, unsupported: $unsupported}' > "$sync.tmp" \
    && mv -f "$sync.tmp" "$sync"
  [ "$rc" != 4 ] || return 0
  echo "t3-needs-me: $name: the push failed: $(head -n 1 "$WORK/$name-out.err"); the next pass retries"
  return 1
}

# The Bridge's objectives follow the home's objectives file.
sync_objectives() {
  local helper=$SCRIPT_DIR/fm-t3-mcp.mjs shortened note=
  command -v node >/dev/null 2>&1 || { echo "t3-needs-me: objectives: node is required"; return 1; }
  FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-objectives.sh" > "$WORK/objectives-source.json" 2>"$WORK/objectives.err" \
    || { echo "t3-needs-me: objectives: the objectives file could not be read: $(head -n 1 "$WORK/objectives.err"); the next pass retries"; return 1; }
  node "$helper" objectives-payload --file "$WORK/objectives-source.json" > "$WORK/objectives.json" 2>"$WORK/objectives.err" \
    || { echo "t3-needs-me: objectives: the payload could not be built: $(head -n 1 "$WORK/objectives.err")"; return 1; }
  jq -c '{markdown}' "$WORK/objectives.json" > "$WORK/objectives-payload.json" \
    || { echo "t3-needs-me: objectives: the payload could not be built"; return 1; }
  shortened=$(jq -r '.shortened' "$WORK/objectives.json")
  [ "$shortened" = 0 ] || note="$shortened of $(jq -r '.objectives' "$WORK/objectives.json") objectives were shortened to fit T3's 8192 characters"
  push_bridge_feed objectives objectives "$OBJECTIVES_SYNC" "$WORK/objectives-payload.json" "$note"
}

# The Bridge's model routing table follows config/crew-dispatch.json. A file
# that is absent or unreadable clears the table, but only once one was sent;
# a malformed one is reported every pass and changes nothing on the Bridge.
sync_routing() {
  local helper=$SCRIPT_DIR/fm-t3-mcp.mjs file=$CONFIG/crew-dispatch.json shortened note=
  command -v node >/dev/null 2>&1 || { echo "t3-needs-me: routing: node is required"; return 1; }
  if [ -f "$file" ] && [ -r "$file" ]; then
    node "$helper" routing-payload --file "$file" > "$WORK/routing.json" 2>"$WORK/routing.err" \
      || { echo "t3-needs-me: routing: the table could not be built: $(head -n 1 "$WORK/routing.err" | sed 's/^fm-t3-mcp: //'); the next pass retries"; return 1; }
  else
    printf '{"markdown":null,"rows":0,"shortened":0}\n' > "$WORK/routing.json"
  fi
  jq -c '{markdown}' "$WORK/routing.json" > "$WORK/routing-payload.json" \
    || { echo "t3-needs-me: routing: the table could not be built"; return 1; }
  # Nothing to clear when no table was ever sent.
  if jq -e '.markdown == null' "$WORK/routing.json" >/dev/null \
    && ! bridge_record "$ROUTING_SYNC" | jq -e 'has("hash")' >/dev/null; then
    return 0
  fi
  shortened=$(jq -r '.shortened' "$WORK/routing.json")
  [ "$shortened" = 0 ] || note="$shortened cells of the $(jq -r '.rows' "$WORK/routing.json")-row table were shortened to fit T3's 8192 characters"
  push_bridge_feed routing routing "$ROUTING_SYNC" "$WORK/routing-payload.json" "$note"
}

# The Bridge's rules section follows data/rules/inventory.json, the same way
# as the routing table: absent or unreadable clears it once one was sent, and
# malformed is reported every pass and changes nothing on the Bridge.
sync_rules() {
  local helper=$SCRIPT_DIR/fm-t3-mcp.mjs file=$RULES_INVENTORY
  command -v node >/dev/null 2>&1 || { echo "t3-needs-me: rules: node is required"; return 1; }
  if [ -f "$file" ] && [ -r "$file" ]; then
    node "$helper" rules-payload --file "$file" > "$WORK/rules.json" 2>"$WORK/rules.err" \
      || { echo "t3-needs-me: rules: the list could not be built: $(head -n 1 "$WORK/rules.err" | sed 's/^fm-t3-mcp: //'); the next pass retries"; return 1; }
  else
    printf '{"rules":[]}\n' > "$WORK/rules.json"
  fi
  jq -c '{rules}' "$WORK/rules.json" > "$WORK/rules-payload.json" \
    || { echo "t3-needs-me: rules: the list could not be built"; return 1; }
  # Nothing to clear when no list was ever sent.
  if jq -e '.rules == []' "$WORK/rules-payload.json" >/dev/null \
    && ! bridge_record "$RULES_SYNC" | jq -e 'has("hash")' >/dev/null; then
    return 0
  fi
  push_bridge_feed rules rules "$RULES_SYNC" "$WORK/rules-payload.json"
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source t3code >/dev/null 2>&1 || { echo "t3-needs-me: the T3 adapter could not load"; exit 1; }
decisions_rc=0
sync_decisions || decisions_rc=$?
objectives_rc=0
sync_objectives || objectives_rc=$?
routing_rc=0
sync_routing || routing_rc=$?
rules_rc=0
sync_rules || rules_rc=$?
[ "$decisions_rc" = 0 ] && [ "$objectives_rc" = 0 ] && [ "$routing_rc" = 0 ] && [ "$rules_rc" = 0 ] || exit 1
exit 0
