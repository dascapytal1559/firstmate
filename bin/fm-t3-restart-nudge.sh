#!/usr/bin/env bash
# fm-t3-restart-nudge.sh - the outside nudge that tells a Firstmate main
# running as a T3 Code thread that the T3 server restarted
# (docs/t3code-backend.md "Server restart").
#
# A T3 server restart ends the main's session, and nothing inside the dead
# session can wake it again: until someone sends the main a message, it does
# not reopen, so the T3 workers the restart ended stay down. This job runs
# outside T3 (launchd, every --interval seconds) and sends the main exactly one
# message per restart once the server is back up. That message reopens the
# main, and its session start then runs bin/fm-t3-restart.sh recover.
#
# Usage:
#   fm-t3-restart-nudge.sh run --thread <main-thread-id>
#     One pass. Reads the verified server's process identity
#     (bin/fm-t3-mcp.mjs status serverStart) through this home's credential;
#     an unreadable server is a silent exit 0, retried on the next pass. The
#     first identity seen is recorded and nothing is sent. A changed identity
#     sends the main one Firstmate operational input of kind session-start
#     (record-backed, bin/fm-operational-input.sh) under a client request id
#     derived from that identity, and records the identity once T3 accepted
#     it. An unconfirmed or failed send keeps the same text and id pending in
#     state/.t3-restart-nudge-pending, so a retry is the same delivery rather
#     than a second message. Records: state/.t3-restart-nudge (last nudged
#     identity), independent of bin/fm-t3-restart.sh's own record.
#   fm-t3-restart-nudge.sh install --thread <main-thread-id> [--interval <seconds>]
#       [--launch-agents-dir <dir>] [--log <file>] [--no-load]
#     macOS only. Renders docs/examples/t3code-restart-nudge.plist into
#     <dir>/<label>.plist (default ~/Library/LaunchAgents) and loads it with
#     launchctl bootstrap gui/<uid>, unless --no-load. The label is
#     dev.firstmate.t3-restart-nudge.<first 12 hex of sha256(FM_HOME)>, so
#     each home has its own job. The job runs with this home's FM_HOME and a
#     PATH that holds the node, lsof, and ps this install found. Interval
#     defaults to 30 seconds. Prints the plist path.
#   fm-t3-restart-nudge.sh uninstall [--launch-agents-dir <dir>] [--no-load]
#     Unloads the job (launchctl bootout, unless --no-load) and removes its
#     plist; nothing installed is a success.
#
# The main thread id is the T3 thread whose workspace is this home (its id
# shows in T3 Code, or in bin/fm-t3-mcp.mjs thread-for-root while it runs).
# Exit: 0 success or nothing to do; 1 failure (printed); 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TEMPLATE="$FM_ROOT/docs/examples/t3code-restart-nudge.plist"
RECORD="$STATE/.t3-restart-nudge"
PENDING="$STATE/.t3-restart-nudge-pending"

usage() {
  sed -n '13,40p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
THREAD=
INTERVAL=30
AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG=
LOAD=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --thread) [ "$#" -ge 2 ] || usage; THREAD=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || usage; INTERVAL=$2; shift 2 ;;
    --launch-agents-dir) [ "$#" -ge 2 ] || usage; AGENTS_DIR=$2; shift 2 ;;
    --log) [ "$#" -ge 2 ] || usage; LOG=$2; shift 2 ;;
    --no-load) LOAD=0; shift ;;
    *) usage ;;
  esac
done

sha256() {  # stdin -> hex
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

LABEL="dev.firstmate.t3-restart-nudge.$(printf '%s' "$FM_HOME" | sha256 | cut -c1-12)"
PLIST="$AGENTS_DIR/$LABEL.plist"

write_file() {  # <path> <content>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

nudge_run() {
  local current recorded pending_id='' pending_text='' id text rc=0
  case "$THREAD" in ''|*[[:space:]]*) echo "error: run needs --thread <main-thread-id>" >&2; exit 2 ;; esac
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source t3code >/dev/null 2>&1 || { echo "error: the t3code adapter did not load" >&2; exit 1; }
  current=$(fm_backend_t3code_server_start 2>/dev/null) || exit 0
  [ -n "$current" ] || exit 0
  mkdir -p "$STATE" || exit 1
  recorded=$(head -n 1 "$RECORD" 2>/dev/null) || recorded=
  if [ -z "$recorded" ]; then
    write_file "$RECORD" "$current" || { echo "error: cannot record the T3 server identity in $RECORD" >&2; exit 1; }
    exit 0
  fi
  [ "$recorded" != "$current" ] || exit 0
  if [ -f "$PENDING" ] && [ "$(sed -n '1p' "$PENDING")" = "$current" ]; then
    pending_id=$(sed -n '2p' "$PENDING")
    pending_text=$(sed -n '3,$p' "$PENDING")
  fi
  if [ -n "$pending_id" ] && [ -n "$pending_text" ]; then
    id=$pending_id
    text=$pending_text
  else
    id="fm-t3-restart-$(printf '%s' "$current" | sha256 | cut -c1-24)"
    text=$(printf '%s' "The T3 server restarted (new server process $current, seen at $(date -u +%Y-%m-%dT%H:%MZ)), which ended this session and every T3 worker's. Run \`bin/fm-session-start.sh\` now, exactly once, before anything else: it retakes the session lock and wakes the T3 workers the restart ended." \
      | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-operational-input.sh" record session-start) \
      || { echo "error: cannot write the operational input record under $STATE/operational-inbox" >&2; exit 1; }
    write_file "$PENDING" "$current
$id
$text" || { echo "error: cannot record the pending nudge in $PENDING" >&2; exit 1; }
  fi
  FM_T3CODE_CLIENT_REQUEST_ID=$id fm_backend_t3code_turn_start "$THREAD" "$text" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "t3-restart-nudge: the send to $THREAD did not confirm (exit $rc); the next pass retries it under request id $id" >&2
    exit 1
  fi
  write_file "$RECORD" "$current" || { echo "error: sent, but cannot record the T3 server identity in $RECORD" >&2; exit 1; }
  rm -f "$PENDING"
  echo "t3-restart-nudge: told $THREAD that the T3 server restarted ($current)"
}

plist_safe() {
  case "$1" in *'&'*|*'<'*|*'>'*|*'"'*|*"'"*|*'|'*) return 1 ;; esac
}

nudge_install() {
  local node_dir path rendered value
  case "$THREAD" in ''|*[[:space:]]*) echo "error: install needs --thread <main-thread-id>" >&2; exit 2 ;; esac
  case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: --interval must be a positive number of seconds" >&2; exit 2 ;; esac
  [ "$(uname -s)" = Darwin ] || { echo "error: install renders a launchd job, which needs macOS" >&2; exit 1; }
  [ -f "$TEMPLATE" ] || { echo "error: the launchd template $TEMPLATE is missing" >&2; exit 1; }
  node_dir=$(dirname "$(command -v node)" 2>/dev/null) || node_dir=
  [ -n "$node_dir" ] && [ -x "$node_dir/node" ] || { echo "error: node is not on PATH; the job needs it" >&2; exit 1; }
  path="$node_dir:/usr/bin:/bin:/usr/sbin:/sbin"
  [ -n "$LOG" ] || LOG="$STATE/t3-restart-nudge.log"
  for value in "$SCRIPT_DIR/fm-t3-restart-nudge.sh" "$FM_HOME" "$THREAD" "$path" "$LOG"; do
    plist_safe "$value" || { echo "error: '$value' cannot be embedded safely in a property list" >&2; exit 1; }
  done
  rendered=$(sed -e "s|@LABEL@|$LABEL|g" -e "s|@SCRIPT@|$SCRIPT_DIR/fm-t3-restart-nudge.sh|g" \
    -e "s|@FM_HOME@|$FM_HOME|g" -e "s|@THREAD@|$THREAD|g" -e "s|@INTERVAL@|$INTERVAL|g" \
    -e "s|@PATH@|$path|g" -e "s|@LOG@|$LOG|g" "$TEMPLATE") || exit 1
  mkdir -p "$AGENTS_DIR" || { echo "error: cannot create $AGENTS_DIR" >&2; exit 1; }
  write_file "$PLIST" "$rendered" || { echo "error: cannot write $PLIST" >&2; exit 1; }
  chmod 0644 "$PLIST" 2>/dev/null || true
  if [ "$LOAD" -eq 1 ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || { echo "error: launchctl bootstrap refused $PLIST" >&2; exit 1; }
  fi
  printf '%s\n' "$PLIST"
}

nudge_uninstall() {
  if [ "$LOAD" -eq 1 ] && command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  fi
  rm -f "$PLIST" || { echo "error: cannot remove $PLIST" >&2; exit 1; }
}

case "$VERB" in
  run) nudge_run ;;
  install) nudge_install ;;
  uninstall) nudge_uninstall ;;
  *) usage ;;
esac
