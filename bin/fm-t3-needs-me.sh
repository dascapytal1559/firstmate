#!/usr/bin/env bash
# fm-t3-needs-me.sh - keep T3's Bridge feeds in line with their sources, and
# read which task a captain reply names.
#
# Usage:
#   fm-t3-needs-me.sh sync
#     bin/fm-watch.sh runs this about once a minute. One pass, and one T3
#     session for each feed that changed.
#   fm-t3-needs-me.sh reply-task [<message-file>]
#     Prints the task id a captain reply names (stdin without a file): a reply
#     to an item names it on its `needs-me-task: <task-id>` line, and one
#     typed on a worker's thread names that thread on its
#     `kept-thread: <thread-id>` line, whose task is the one record in
#     state/*.meta with that t3_thread_id. Exit 1 when the message names
#     none, or a thread no task records; 2 when it names more than one, a
#     malformed id, or a thread more than one task records.
#
# Each sync pass pushes the captain's high level objectives, as
# bin/fm-objectives.sh reads them, to the top of T3's Bridge tab
# (docs/t3code-backend.md "Objectives"), only when the payload bin/fm-t3-mcp.mjs
# objectives-payload builds from them differs from the last proven push,
# whose hash state/t3-needs-me/.objectives keeps; an absent file, or one with
# no bullets, clears them once. A failed push is reported and retried three
# times in a row, then every 15 minutes; a T3 without objectives is retried
# the same way, quietly.
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
# Only a main home with config/t3code-token takes part.
#
# Exit: 0, or 1 when the objectives, routing table or rules could not be
# pushed (a line on stdout says which; the next pass retries); usage errors
# exit 2. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SYNCS="$STATE/t3-needs-me"
OBJECTIVES_SYNC="$SYNCS/.objectives"
ROUTING_SYNC="$SYNCS/.routing"
RULES_SYNC="$SYNCS/.rules"
RULES_INVENTORY="$DATA/rules/inventory.json"
NOW=${FM_NEEDS_ME_NOW:-$(date +%s)}
BACKOFF_FAILURES=3
BACKOFF_SECONDS=900

usage() {
  sed -n '/^# Usage:/,/^#     malformed id, or a thread more than one task records./p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# kept_thread_task <thread-id>: the task ids whose record names that thread,
# one per line.
kept_thread_task() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    slug_ok "$id" || continue
    [ "$(sed -n 's/^t3_thread_id=//p' "$meta" | tail -n 1)" = "$1" ] && printf '%s\n' "$id"
  done
  return 0
}

if [ "$VERB" = reply-task ]; then
  message=$(cat ${1:+"$1"}) || exit 1
  ids=$(printf '%s\n' "$message" | sed -n 's/^[[:space:]>]*needs-me-task:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' | sort -u)
  threads=$(printf '%s\n' "$message" | sed -n 's/^[[:space:]>]*kept-thread:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' | sort -u)
  if [ -n "$threads" ]; then
    [ -z "$ids" ] || { echo "reply names both a task and a kept thread" >&2; exit 2; }
    [ "$(printf '%s\n' "$threads" | wc -l | tr -d ' ')" = 1 ] || { echo "reply names more than one kept thread: $(printf '%s' "$threads" | tr '\n' ' ')" >&2; exit 2; }
    case "$threads" in *[!A-Za-z0-9:._-]*) echo "reply names a malformed thread id: $threads" >&2; exit 2 ;; esac
    ids=$(kept_thread_task "$threads")
    [ -n "$ids" ] || { echo "no task records kept thread $threads" >&2; exit 1; }
    [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] || { echo "kept thread $threads is recorded by more than one task: $(printf '%s' "$ids" | tr '\n' ' ')" >&2; exit 2; }
  fi
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

# --- sync ------------------------------------------------------------------

taking_part || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$SYNCS" || { echo "t3-needs-me: could not create $SYNCS"; exit 1; }
fm_lock_acquire_wait_max "$SYNCS/.lock" 30 || { echo "t3-needs-me: another pass holds the lock; the next pass catches up"; exit 0; }
LOCK_HELD=1

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
# row and then every BACKOFF_SECONDS; a T3 without the feed's tool is retried
# the same way, quietly. <note>, when given, is printed after a proven push.
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
  [ "$shortened" = 0 ] || note="$shortened of the $(jq -r '.rows' "$WORK/routing.json") routes had their description shortened to fit T3's 8192 characters"
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
objectives_rc=0
sync_objectives || objectives_rc=$?
routing_rc=0
sync_routing || routing_rc=$?
rules_rc=0
sync_rules || rules_rc=$?
[ "$objectives_rc" = 0 ] && [ "$routing_rc" = 0 ] && [ "$rules_rc" = 0 ] || exit 1
exit 0
