#!/usr/bin/env bash
# fm-t3-bridge.sh - keep T3's Bridge tab in line with its two sources: the
# captain's high level objectives and the model routing table
# (docs/t3code-backend.md "Objectives" and "Model routing").
#
# Usage:
#   fm-t3-bridge.sh sync
#     bin/fm-watch.sh runs this about once a minute, so a changed source
#     reaches the Bridge within that minute. One pass, and one T3 session for
#     each feed that changed.
#
# Each feed is pushed only when its payload differs from the last push T3
# proved, whose hash state/t3-bridge/.<feed> keeps:
#   objectives  the rows bin/fm-objectives.sh reads, built by bin/fm-t3-mcp.mjs
#               objectives-payload and sent with t3_objectives_set. An absent
#               file, or one with no bullets, clears them once.
#   routing     config/crew-dispatch.json, built by bin/fm-t3-mcp.mjs
#               routing-payload and sent with t3_routing_set. An absent or
#               unreadable file clears the table once, and only if one was
#               sent; a malformed one is reported every pass and leaves the
#               Bridge's table as it was.
# A failed push keeps the old hash, so the next pass retries, three times in a
# row and then every 15 minutes; a T3 without the feed's tool is retried the
# same way, quietly.
#
# Only a main home with config/t3code-token takes part.
#
# Exit: 0, or 1 when a feed could not be pushed (a line on stdout says which;
# the next pass retries); usage errors exit 2. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SYNCS="$STATE/t3-bridge"
HELPER="$SCRIPT_DIR/fm-t3-mcp.mjs"
NOW=${FM_T3_BRIDGE_NOW:-$(date +%s)}
BACKOFF_FAILURES=3
BACKOFF_SECONDS=900

if [ "$#" != 1 ] || [ "$1" != sync ]; then
  sed -n '/^# Usage:/,/^#     each feed that changed./p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

[ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || exit 0
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
! fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1 || exit 0

for tool in jq node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "t3-bridge: $tool is required"; exit 1; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-bridge.XXXXXX") || { echo "t3-bridge: no temporary directory"; exit 1; }
LOCK_HELD=0
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$SYNCS/.lock" || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$SYNCS" || { echo "t3-bridge: could not create $SYNCS"; exit 1; }
fm_lock_acquire_wait_max "$SYNCS/.lock" 30 || { echo "t3-bridge: another pass holds the lock; the next pass catches up"; exit 0; }
LOCK_HELD=1
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source t3code >/dev/null 2>&1 || { echo "t3-bridge: the T3 adapter could not load"; exit 1; }

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

# feed_record <feed>: the last proven push's record ({hash, failures,
# failedAt, unsupported}), {} when there is none.
feed_record() {
  local rec='{}'
  [ ! -f "$SYNCS/.$1" ] || rec=$(jq -c 'select(type == "object")' "$SYNCS/.$1" 2>/dev/null) || rec='{}'
  [ -n "$rec" ] || rec='{}'
  printf '%s\n' "$rec"
}

# push_feed <feed> <payload-file> [<note>]: send <payload-file> with
# bin/fm-t3-mcp.mjs <feed> when its hash differs from the last proven push.
# <note>, when given, is printed after a proven push.
push_feed() {
  local feed=$1 payload=$2 note=${3:-} sync="$SYNCS/.$1" rec hash rc=0
  hash=$(sha < "$payload")
  rec=$(feed_record "$feed")
  [ "$(printf '%s' "$rec" | jq -r '.hash // ""')" != "$hash" ] || return 0
  if ! printf '%s' "$rec" | jq -e --argjson now "$NOW" --argjson failures "$BACKOFF_FAILURES" --argjson backoff "$BACKOFF_SECONDS" \
    '(.failures // 0) < $failures or ($now - (.failedAt // 0)) >= $backoff' >/dev/null; then
    # Held back: not proven this pass, which is no failure on a T3 without it.
    printf '%s' "$rec" | jq -e '.unsupported == true' >/dev/null
    return
  fi
  fm_backend_t3code_mcp "$feed" --file "$payload" > "$WORK/$feed-out.json" 2>"$WORK/$feed-out.err" || rc=$?
  if [ "$rc" = 0 ]; then
    if ! { jq -n --arg hash "$hash" '{hash: $hash, failures: 0, failedAt: null, unsupported: false}' > "$sync.tmp" \
      && mv -f "$sync.tmp" "$sync"; }; then
      echo "t3-bridge: $feed: could not record the push"
      return 1
    fi
    [ -z "$note" ] || echo "t3-bridge: $feed: $note"
    return 0
  fi
  printf '%s' "$rec" | jq --argjson now "$NOW" --argjson unsupported "$([ "$rc" = 4 ] && echo true || echo false)" \
    '. + {failures: ((.failures // 0) + 1), failedAt: $now, unsupported: $unsupported}' > "$sync.tmp" \
    && mv -f "$sync.tmp" "$sync"
  [ "$rc" != 4 ] || return 0
  echo "t3-bridge: $feed: the push failed: $(head -n 1 "$WORK/$feed-out.err"); the next pass retries"
  return 1
}

sync_objectives() {
  local shortened note=
  FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-objectives.sh" > "$WORK/objectives-source.json" 2>"$WORK/objectives.err" \
    || { echo "t3-bridge: objectives: the objectives file could not be read: $(head -n 1 "$WORK/objectives.err"); the next pass retries"; return 1; }
  node "$HELPER" objectives-payload --file "$WORK/objectives-source.json" > "$WORK/objectives.json" 2>"$WORK/objectives.err" \
    || { echo "t3-bridge: objectives: the payload could not be built: $(head -n 1 "$WORK/objectives.err")"; return 1; }
  jq -c '{markdown}' "$WORK/objectives.json" > "$WORK/objectives-payload.json" \
    || { echo "t3-bridge: objectives: the payload could not be built"; return 1; }
  shortened=$(jq -r '.shortened' "$WORK/objectives.json")
  [ "$shortened" = 0 ] || note="$shortened of $(jq -r '.objectives' "$WORK/objectives.json") objectives were shortened to fit T3's 8192 characters"
  push_feed objectives "$WORK/objectives-payload.json" "$note"
}

sync_routing() {
  local file=$CONFIG/crew-dispatch.json shortened note=
  if [ -f "$file" ] && [ -r "$file" ]; then
    node "$HELPER" routing-payload --file "$file" > "$WORK/routing.json" 2>"$WORK/routing.err" \
      || { echo "t3-bridge: routing: the table could not be built: $(head -n 1 "$WORK/routing.err" | sed 's/^fm-t3-mcp: //'); the next pass retries"; return 1; }
  else
    printf '{"markdown":null,"rows":0,"shortened":0}\n' > "$WORK/routing.json"
  fi
  jq -c '{markdown}' "$WORK/routing.json" > "$WORK/routing-payload.json" \
    || { echo "t3-bridge: routing: the table could not be built"; return 1; }
  # Nothing to clear when no table was ever sent.
  if jq -e '.markdown == null' "$WORK/routing.json" >/dev/null \
    && ! feed_record routing | jq -e 'has("hash")' >/dev/null; then
    return 0
  fi
  shortened=$(jq -r '.shortened' "$WORK/routing.json")
  [ "$shortened" = 0 ] || note="$shortened of the $(jq -r '.rows' "$WORK/routing.json") routes had their description shortened to fit T3's 8192 characters"
  push_feed routing "$WORK/routing-payload.json" "$note"
}

rc=0
sync_objectives || rc=1
sync_routing || rc=1
exit "$rc"
