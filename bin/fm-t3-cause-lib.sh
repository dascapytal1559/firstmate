#!/usr/bin/env bash
# fm-t3-cause-lib.sh - the T3 prompt that caused a Firstmate action.
#
# T3 Code's Usage counts a worker's tokens to the phone or computer prompt
# that started it by following causedBy: the prompt a launch or a message
# names as its cause (docs/t3code-backend.md "Work causes"). This library is
# the one place Firstmate decides that cause at its durable boundaries:
#   - bin/fm-spawn.sh records it in the task record (caused_by=) and sends it
#     on the worker's launch and its brief; a relaunch reuses the recorded one;
#   - bin/fm-send.sh records it in the steer's inbox record (caused-by=), and
#     every doorbell for that record carries it (bin/fm-task-inbox-lib.sh);
#   - bin/fm-inbox.sh note records the prompt that made an agent write a note
#     (caused-by=), so firstmate can name it when it acts on that note.
# A cause is the compact JSON {"threadId","runId"?,"messageId"} T3 takes.
# bin/backends/t3code.sh sends FM_T3CODE_CAUSED_BY as causedBy when it holds
# such JSON and never resolves one itself, so a re-ring or any other send
# outside these boundaries carries a cause only when its caller hands one in.
#
# FM_T3CODE_CAUSED_BY, read at each boundary:
#   unset or empty  the one prompt of the calling agent's current T3 turn
#                   (bin/fm-t3-mcp.mjs cause owns that rule, which answers
#                   nothing rather than guess), or nothing when this process
#                   runs in no T3 thread ($T3CODE_THREAD_ID unset), the home
#                   has no T3 credential, or T3 cannot be read;
#   off             no cause;
#   a cause JSON    that cause as given, for a turn that received several
#                   prompts or an action a recorded note caused; T3 checks
#                   the ids when the cause is sent.
# Anything else is refused (status 2) before the boundary acts.
# A cause that could not be established is left out silently, and the action
# goes ahead without one. Message text is never read.

_FM_T3_CAUSE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_t3_cause_resolve <token-file> -> the cause JSON on stdout, or nothing.
# Status 2 when FM_T3CODE_CAUSED_BY is malformed; 0 otherwise.
fm_t3_cause_resolve() {
  local token=$1 given=${FM_T3CODE_CAUSED_BY:-} out
  case "$given" in
    off) return 0 ;;
    '') ;;
    *)
      if ! out=$(node "$_FM_T3_CAUSE_LIB_DIR/fm-t3-mcp.mjs" cause-check --json "$given" 2>/dev/null); then
        echo "error: FM_T3CODE_CAUSED_BY must be off or a JSON object of exactly threadId, messageId, and optional runId (bin/fm-t3-cause-lib.sh)" >&2
        return 2
      fi
      _fm_t3_cause_field "$out"
      return 0
      ;;
  esac
  if [ -z "${T3CODE_THREAD_ID:-}" ] || [ ! -f "$token" ] || ! command -v node >/dev/null 2>&1; then
    return 0
  fi
  out=$(node "$_FM_T3_CAUSE_LIB_DIR/fm-t3-mcp.mjs" cause --thread "$T3CODE_THREAD_ID" --token-file "$token" 2>/dev/null) || return 0
  _fm_t3_cause_field "$out" || true
  return 0
}

# _fm_t3_cause_field <helper-json>: the causedBy JSON; status 1 without one.
_fm_t3_cause_field() {
  printf '%s' "$1" | node -e '
let d;
try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
if (!d || d.ok !== true || !d.causedBy) process.exit(1);
process.stdout.write(JSON.stringify(d.causedBy));
'
}
