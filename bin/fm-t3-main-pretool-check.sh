#!/usr/bin/env bash
# PreToolUse guard for a Firstmate main in a home signed in to T3 Code
# (docs/t3code-backend.md "Server restart" and "Sign-in").
#
# Two checks, both inert outside such a home:
#
# 1. Restart reminder. A T3 server restart ends the main's session with every
#    other T3 session, and a later send reopens it in a new process. Claude's
#    SessionStart hook does not reliably fire on that reopen, so the reopened
#    main can carry on without session start, trusting workers that are no
#    longer running. When state/.lock names a pid that is no longer running
#    (fm_session_lock_inspect reads it stale), the first tool call is denied
#    once per such pid with an instruction to run bin/fm-session-start.sh,
#    which retakes the lock and runs bin/fm-t3-restart.sh recover. A call that
#    itself runs bin/fm-session-start.sh is allowed. The once-per-pid record is
#    state/.t3-restart-nudged.
# 2. Credential seatbelt. config/t3code-token is a full-access T3 credential
#    that a T3 thread's transcript would keep. A Read or Grep naming that
#    file, a Grep over the config directory, and a Bash command that names
#    the file (except a lone ls, stat, test, chmod, rm, or file), or that hands
#    a glob over config/ to a command that prints file contents (cat, head,
#    tail, grep, and the like), is denied with the reason. This is a guard
#    against an agent's mistake, not a security boundary: anything the main
#    can run can still read the file.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-t3-main-pretool-check.sh [--claude]
#
# Scope: the real primary checkout (git-dir equals git-common-dir, as for
# bin/fm-cd-pretool-check.sh) of a home whose config holds t3code-token.
# Exit/output contract (the shape of bin/fm-cd-pretool-check.sh):
#   ALLOW or INERT - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   FAIL OPEN - malformed or empty stdin, or missing jq.
# Only Claude registers this hook (.claude/settings.json).
set -u

CLAUDE_MODE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
TOKEN="$CONFIG/t3code-token"

PAYLOAD=$(cat 2>/dev/null || true)
[ -e "$TOKEN" ] || [ -L "$TOKEN" ] || exit 0
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] && [ -d "$FM_ROOT/bin" ] || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=
TARGET=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty)' 2>/dev/null) || TARGET=
GLOB=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.glob // empty' 2>/dev/null) || GLOB=

deny() {  # <code> <reason>
  local detail escaped
  detail="[$1] $2"
  escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

# --- 1. restart reminder -----------------------------------------------------
if [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ]; then
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_inspect "$STATE"
  if [ "$FM_LOCK_INSPECT_STATE" = stale ] && [ -n "$FM_LOCK_INSPECT_PID" ] \
    && [ "$(head -n 1 "$STATE/.t3-restart-nudged" 2>/dev/null)" != "$FM_LOCK_INSPECT_PID" ]; then
    printf '%s\n' "$FM_LOCK_INSPECT_PID" > "$STATE/.t3-restart-nudged" 2>/dev/null || true
    case "$CMD" in
      *fm-session-start.sh*) ;;
      *)
        deny t3-restart "This home's session lock names pid $FM_LOCK_INSPECT_PID, which is no longer running: this session was reopened after its previous process ended, most likely because the T3 server restarted and took every T3 session with it. Run bin/fm-session-start.sh now, exactly once, before anything else: it retakes the lock and wakes the T3 workers the restart ended. This reminder appears once."
        ;;
    esac
  fi
fi

# --- 2. credential seatbelt ---------------------------------------------------
TOKEN_REASON="config/t3code-token is the T3 credential; printing it would keep a full-access credential in this thread's transcript. Read the config files you need by their own names, and check the credential with bin/fm-t3-mcp.mjs status, which never prints it."
is_config_dir() {  # <path>
  case "${1%/}" in
    config|./config|"$CONFIG"|"$FM_HOME/config"|*/config) return 0 ;;
  esac
  return 1
}

case "$TOOL" in
  Bash) ;;
  Grep)
    case "$TARGET$GLOB" in *t3code-token*) deny t3-token "$TOKEN_REASON" ;; esac
    if [ -n "$TARGET" ] && is_config_dir "$TARGET"; then
      deny t3-token "$TOKEN_REASON"
    fi
    exit 0
    ;;
  *)
    case "$TARGET" in *t3code-token) deny t3-token "$TOKEN_REASON" ;; esac
    exit 0
    ;;
esac

[ -n "$CMD" ] || exit 0
# Quote and escape bytes removed so a quoted path still reads as one word.
PLAIN=$CMD
PLAIN=${PLAIN//\\/}
PLAIN=${PLAIN//\"/}
PLAIN=${PLAIN//\'/}
case "$PLAIN" in
  *t3code-token*)
    case "$PLAIN" in
      *[\;\|\&\`\<\>]*|*\$\(*) deny t3-token "$TOKEN_REASON" ;;
    esac
    case "$PLAIN" in
      ls\ *|stat\ *|test\ *|'[ '*|chmod\ *|rm\ *|file\ *) exit 0 ;;
    esac
    deny t3-token "$TOKEN_REASON"
    ;;
esac
READER_RE='(^|[[:space:];|&(`])(cat|head|tail|less|more|bat|tac|nl|strings|xxd|od|hexdump|base64|grep|egrep|fgrep|rg|ag|sed|awk|gawk|jq|cut|paste|column|diff|cmp|python3?|node|perl|ruby|tee)([[:space:]]|$)'
if printf '%s' "$PLAIN" | grep -Eq "$READER_RE"; then
  if printf '%s' "$PLAIN" | grep -Eq '(^|[[:space:]=])([^[:space:]]*/)?config/[^[:space:]]*[]*?[]'; then
    deny t3-token "$TOKEN_REASON"
  fi
  if printf '%s' "$PLAIN" | grep -Eq '(^|[[:space:]])(grep|egrep|fgrep)[[:space:]].*-[[:alnum:]]*[rR]' \
    && printf '%s' "$PLAIN" | grep -Eq '(^|[[:space:]])([^[:space:]]*/)?config/?([[:space:]]|$)'; then
    deny t3-token "$TOKEN_REASON"
  fi
fi
exit 0
