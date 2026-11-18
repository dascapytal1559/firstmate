#!/usr/bin/env bash
# Claude Stop hook wrapper (fork): a notification never reloads a cold session.
#
# Registered in tracked .claude/settings.json as the Stop hook in place of
# bin/fm-claude-stop-autoarm.sh, with the same asyncRewake and timeout. It runs
# that upstream hook unchanged, on the same payload, and looks only at its
# result. The StopFailure registration still runs the upstream hook directly.
#
# Every outcome passes through byte for byte - the upstream hook's exit status
# and its stderr - except one: the upstream hook is about to wake this session
# for a supervision event, and waking it would re-send a context whose prompt
# cache has expired. Then this wrapper sends one message to FirstMate's own T3
# Code thread instead and exits 0, so the session is not woken in place. The
# T3 Code fork starts that message's turn in a fresh session when the thread is
# cold (FORK.md "A notification never reloads a cold session").
#
# The message is Firstmate operational input of the watcher kind, carried as
# the record-backed doorbell of bin/fm-operational-input.sh (Claude strips the
# typed envelope's invisible marker): the record in this home's
# state/operational-inbox holds the envelope, and T3 Code delivers only the
# doorbell naming it. So everything that tells the captain's words from fleet
# machinery reads it as machinery: the away-mode return rule
# (.agents/skills/afk/SKILL.md), the dialog mirror's writer
# (bin/fm-host-mirror.sh), and the nightly clear check (bin/fm-clear-watch.py).
#
# The reroute happens only when all of these hold:
#   - the upstream hook exited 2, and its own ledger entry
#     (state/.claude-autoarm-epoch) records outcome=rewake under the upstream
#     hook's own pid - an actionable wake, never a failure notice, an alarm, or
#     an interruption, all of which pass through;
#   - this wrapper was not itself signalled while it waited;
#   - the session runs in a T3 Code thread (T3CODE_THREAD_ID) and holds the
#     session lock (bin/fm-session-lock-lib.sh fm_session_lock_owned_by_self);
#   - the newest request in the session's transcript (the payload's
#     transcript_path; the timestamp of its last assistant entry with usage) is
#     older than the prompt-cache lifetime, FM_COLD_REROUTE_CACHE_SECONDS
#     (default 3600, one hour);
#   - the context is over 100,000 tokens, as bin/fm-warm-compact-lib.sh
#     fm_warm_compact_context_tokens reads it from the same transcript.
#
# The message carries no notification and asks for no fresh context: the
# notification stays in the durable wake queue, which a fresh session's start
# digest presents, and the T3 Code fork alone decides whether the turn starts
# fresh. If his message and this one race, the first starts the fresh session
# and the second continues it.
#
# Any failure of the send - no credential, a record that cannot be written, T3
# unreachable, a refused or expired credential, an unconfirmed delivery - falls
# back to the upstream
# outcome: its stderr and exit 2, exactly as without this wrapper. A doubled
# delivery after an unconfirmed send is harmless, because handling a wake is
# repeatable.
#
# Signals: Claude ends a hook by signalling its whole process tree
# (docs/verification/runtime-backends.md "Fresh session swap on real Claude"),
# so the upstream hook receives HUP, TERM, or INT itself and runs its own
# interruption handling. This wrapper only keeps waiting for that outcome and
# passes it through; forwarding the signal would deliver it twice, and the
# upstream handler resets its traps on the first.
#
# Any argument means a manual run: -h or --help prints this wrapper's usage,
# and anything else is handed to the upstream hook unchanged.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-cold-reroute.sh

Claude Stop hook registered in .claude/settings.json; not for manual use.
It runs bin/fm-claude-stop-autoarm.sh on the same payload and passes its
outcome through, except that a wake of a T3 Code session idle past its
prompt-cache lifetime is sent as one operational-input doorbell to
FirstMate's own T3 Code thread instead (exit 0). Any failure of that send
falls back to the wake.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="$SCRIPT_DIR/fm-claude-stop-autoarm.sh"

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) exec "$UPSTREAM" "$@" ;;
  esac
fi

# Without scratch files nothing can be judged, so be the upstream hook itself.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-cold-reroute.XXXXXX" 2>/dev/null) || exec "$UPSTREAM"
trap 'rm -rf "$SCRATCH"' EXIT
cat > "$SCRATCH/payload" 2>/dev/null || true

# The upstream hook runs in the foreground, never as a background job: a
# non-interactive shell starts a background job with SIGINT ignored, which the
# job could not undo, while a trapped signal that reaches this shell during a
# foreground command runs its trap only after the command ends. The pid is
# recorded by exec, so the hook keeps the pid it writes into its ledger.
SIGNALLED=0
trap 'SIGNALLED=1' HUP TERM INT
bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' fm-cold-reroute "$SCRATCH/pid" "$UPSTREAM" \
  < "$SCRATCH/payload" 2> "$SCRATCH/err"
RC=$?
CHILD=$(cat "$SCRATCH/pid" 2>/dev/null || true)

pass_through() {
  cat "$SCRATCH/err" >&2 2>/dev/null
  exit "$RC"
}

[ "$RC" -eq 2 ] || pass_through
[ "$SIGNALLED" -eq 0 ] || pass_through

# --- is this a wake of a cold, large T3 Code session? ------------------------
THREAD=${T3CODE_THREAD_ID:-}
case "$THREAD" in ''|*[!A-Za-z0-9._-]*) pass_through ;; esac
command -v jq >/dev/null 2>&1 || pass_through

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -s "$CONFIG/t3code-token" ] || pass_through

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_autoarm_ledger_read "$STATE" || pass_through
[ "$FM_AUTOARM_OUTCOME" = rewake ] && [ "$FM_AUTOARM_OWNER" = "$CHILD" ] || pass_through
fm_session_lock_owned_by_self "$STATE" || pass_through

TRANSCRIPT=$(jq -r '.transcript_path // empty | strings' "$SCRATCH/payload" 2>/dev/null || true)
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || pass_through

CACHE_SECONDS=${FM_COLD_REROUTE_CACHE_SECONDS:-3600}
case "$CACHE_SECONDS" in ''|0*|*[!0-9]*) CACHE_SECONDS=3600 ;; esac
LAST_REQUEST=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | jq -R -r '
    fromjson? | select(.type == "assistant" and (.message.usage | type) == "object")
    | .timestamp | strings | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty
  ' 2>/dev/null | tail -n 1)
case "$LAST_REQUEST" in ''|*[!0-9]*) pass_through ;; esac
[ $(( $(date +%s) - LAST_REQUEST )) -gt "$CACHE_SECONDS" ] || pass_through

TOKENS=$(fm_warm_compact_context_tokens "$TRANSCRIPT")
case "$TOKENS" in ''|*[!0-9]*) pass_through ;; esac
[ "$TOKENS" -gt 100000 ] || pass_through

# --- ring it through T3 Code instead -----------------------------------------
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source t3code >/dev/null 2>&1 || pass_through
unset FM_T3_FROM_THREAD FM_T3CODE_CLIENT_REQUEST_ID
BODY='A firstmate supervision wake is waiting in the durable wake queue. It was rung through T3 Code instead of waking the session in place, because the session sat idle past its prompt-cache lifetime.
In a session that has just started, the session-start digest already presents the queue. Otherwise run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command.
The Stop hook owns watcher continuity: the next turn end arms supervision, so do NOT run bin/fm-watch-arm.sh.'
DOORBELL=
fm_operational_record_write "$STATE" watcher "$BODY" DOORBELL || pass_through
fm_backend_t3code_turn_start "$THREAD" "$DOORBELL" >/dev/null 2>&1 || pass_through
exit 0
