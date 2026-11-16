#!/usr/bin/env bash
# fm-t3-usage-claim.sh - Firstmate's usage claims on T3 Code: tell T3's Usage
# page what caused work it cannot trace on its own, through the fork's
# t3_usage_claim (docs/t3code-backend.md "Usage claims" owns the operator
# contract; bin/fm-t3-mcp.mjs usage-claim owns the call).
#
# Every claim is best effort. A claim that cannot be made (no T3 credential,
# a T3 without t3_usage_claim, no T3 turn, no recorded cause) is skipped
# silently, and a call that fails is logged once, as one line in
# state/t3-usage-claims.log, and never retried by this run. Every verb exits
# 0 except invalid use (2), so no wake or turn ever waits on its accounting.
# Sessions T3 does not run - pipeline reviews, the supervision engine, a
# worker's own probes - are not claimed: they register themselves when they
# start (docs/t3code-backend.md "Usage claims").
#
# Usage:
#   fm-t3-usage-claim.sh turn (--device phone|computer | --task <id> | --caused-by <cause-json>)
#     Claim the calling agent's current T3 turn ($T3CODE_THREAD_ID): it
#     counts to that device, to <id>'s recorded cause, or to that cause.
#     For a turn the drain's claim does not describe, such as the turn that
#     files a voice journal (--device phone). It replaces any claim on that
#     turn, and a later drain in the same turn leaves it.
#   fm-t3-usage-claim.sh wake [--task <id> | --caused-by <cause-json> | --device phone|computer]...
#     The wake drain's claim on the current turn: the first candidate, in
#     order, that has a cause (a task's recorded cause, a cause given, or a
#     device given, such as the phone for a voice journal's note);
#     with no candidate caused, or none at all, the computer, because a wake
#     about no task is upkeep and a task launched with no recorded cause
#     (before T3 ran this home) has no device to trace. A turn this home
#     already claimed keeps its first claim.
#     Then, detached, each of the thread's recent finished turns this home
#     never claimed is claimed computer: a turn a notification started that
#     no drain described, such as a background command finishing. T3 counts
#     a claimed turn only when its own prompt does not trace, so claiming a
#     prompted turn changes nothing.
#
# Records, both trimmed as they grow:
#   state/.t3-usage-claimed-runs  "<thread> TAB <run>" of every turn this home
#                                 claimed, so a drain keeps a turn's first
#                                 claim and the sweep skips it;
#   state/t3-usage-claims.log     one line per failed call.
# A task's cause is bin/fm-t3-cause-lib.sh's fm_t3_cause_of_task.
# FM_T3_USAGE_CLAIM_TIMEOUT (seconds, default 20) bounds each T3 call.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TOKEN="${FM_T3CODE_TOKEN_FILE:-$CONFIG/t3code-token}"
HELPER="$SCRIPT_DIR/fm-t3-mcp.mjs"
CLAIMED="$STATE/.t3-usage-claimed-runs"
LOG="$STATE/t3-usage-claims.log"
TIMEOUT=${FM_T3_USAGE_CLAIM_TIMEOUT:-20}
case "$TIMEOUT" in ''|0*|*[!0-9]*) TIMEOUT=20 ;; esac
TAB=$(printf '\t')
export FM_HOME

# shellcheck source=bin/fm-t3-cause-lib.sh
. "$SCRIPT_DIR/fm-t3-cause-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# keep_tail <file> <max-lines>: trim <file> to its newest half once it grows
# past <max-lines>.
keep_tail() {
  local file=$1 max=$2 lines tmp
  [ -f "$file" ] || return 0
  lines=$(awk 'END { print NR }' "$file" 2>/dev/null) || return 0
  [ "${lines:-0}" -gt "$max" ] || return 0
  tmp="$file.$$"
  if tail -n "$((max / 2))" "$file" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

log_failure() {  # <what> <helper-output>
  local message
  # shellcheck disable=SC2016 # A literal Node program; ${...} is JavaScript.
  message=$(printf '%s' "$2" | node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(0); }
if (d && d.error) process.stdout.write(`${d.error.code}: ${d.error.message}`);' 2>/dev/null)
  [ -n "$message" ] || message="no answer from bin/fm-t3-mcp.mjs"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(printf '%s' "$message" | tr '\t\n' '  ')" >> "$LOG" 2>/dev/null || true
  keep_tail "$LOG" 400
}

# t3_ready: this home can call T3 at all.
t3_ready() {
  [ -f "$TOKEN" ] && command -v node >/dev/null 2>&1 && [ -d "$STATE" ]
}

# claim <what> <usage-claim args...>: one bounded call. Prints its JSON on
# success; logs once and returns 1 on failure. A T3 without usage claims is
# not a failure (returns 3), only the absence of the feature.
claim() {
  local what=$1 out rc=0
  shift
  out=$(fm_exec_timed "$TIMEOUT" 2 node "$HELPER" usage-claim "$@" --token-file "$TOKEN" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out"
    return 0
  fi
  case "$out" in *'"usage_claim_unsupported"'*) return 3 ;; esac
  log_failure "$what" "$out"
  return 1
}

json_field() {  # <json> <key>
  printf '%s' "$1" | node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(0); }
const v = d == null ? null : d[process.argv[1]];
if (v !== null && v !== undefined) process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));' "$2" 2>/dev/null
}

remember_run() {  # <thread> <run>
  [ -n "$1" ] && [ -n "$2" ] || return 0
  printf '%s\t%s\n' "$1" "$2" >> "$CLAIMED" 2>/dev/null || true
  keep_tail "$CLAIMED" 1000
}

run_claimed() {  # <thread> <run>
  [ -f "$CLAIMED" ] && grep -Fxq -- "$1$TAB$2" "$CLAIMED" 2>/dev/null
}

# value_args <cause-json|device>: the usage-claim value flags.
value_args() {
  case "$1" in
    phone|computer) printf '%s\n' --device "$1" ;;
    *) printf '%s\n' --caused-by "$1" ;;
  esac
}

# first_cause <candidate...>: each candidate is task:<id>, cause:<json>, or
# device:<device>. Prints the first cause or device found; status 1 when none
# was named at all, 2 when some were named but none had a cause.
first_cause() {
  local c cause
  [ "$#" -gt 0 ] || return 1
  for c in "$@"; do
    case "$c" in
      task:*) cause=$(fm_t3_cause_of_task "$STATE" "${c#task:}") ;;
      cause:*) cause=${c#cause:} ;;
      device:*) cause=${c#device:} ;;
      *) cause= ;;
    esac
    if [ -n "$cause" ]; then
      printf '%s' "$cause"
      return 0
    fi
  done
  return 2
}

# sweep <thread>: claim computer on each recent finished turn of <thread> this
# home never claimed (the header's wake rule).
sweep() {
  local thread=$1 runs run rc
  runs=$(fm_exec_timed "$TIMEOUT" 2 node "$HELPER" recent-runs --thread "$thread" --limit 10 --token-file "$TOKEN" 2>/dev/null) || {
    log_failure "sweep $thread" "$runs"
    return 0
  }
  runs=$(printf '%s' "$runs" | node -e '
let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(0); }
const done = new Set(["completed", "failed", "cancelled", "interrupted", "rolled_back"]);
for (const r of d.runs ?? []) if (r.runId && done.has(r.status)) console.log(r.runId);' 2>/dev/null)
  for run in $runs; do
    run_claimed "$thread" "$run" && continue
    rc=0
    claim "sweep $thread $run" --thread "$thread" --run "$run" --device computer >/dev/null || rc=$?
    case "$rc" in
      0) remember_run "$thread" "$run" ;;
      *) return 0 ;;
    esac
  done
}

# claim_turn <first-wins 0|1> <value>: claim the calling agent's turn. With
# first-wins, a turn this home already claimed keeps that claim.
claim_turn() {
  local first=$1 value=$2 out line thread=${T3CODE_THREAD_ID:-}
  local -a args=(--turn "$thread")
  [ -n "$thread" ] && t3_ready || return 0
  [ "$first" -eq 0 ] || args+=(--unless-listed "$CLAIMED")
  while IFS= read -r line; do args+=("$line"); done < <(value_args "$value")
  out=$(claim "turn $thread" "${args[@]}") || return 1
  [ "$(json_field "$out" claimed)" = true ] || return 0
  remember_run "$thread" "$(json_field "$out" runId)"
}

verb_turn() {
  local value='' n=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --device) [ "$#" -ge 2 ] || usage; case "$2" in phone|computer) ;; *) usage ;; esac; value=$2; n=$((n + 1)); shift 2 ;;
      --task) [ "$#" -ge 2 ] || usage; value=task:$2; n=$((n + 1)); shift 2 ;;
      --caused-by) [ "$#" -ge 2 ] || usage; value=cause:$2; n=$((n + 1)); shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$n" -eq 1 ] || usage
  case "$value" in
    task:*|cause:*)
      value=$(first_cause "$value") || { echo "fm-t3-usage-claim: no cause recorded for ${value#task:}; nothing claimed" >&2; return 0; }
      ;;
  esac
  claim_turn 0 "$value" || true
}

verb_wake() {
  local -a candidates=()
  local value
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage; candidates+=("task:$2"); shift 2 ;;
      --caused-by) [ "$#" -ge 2 ] || usage; candidates+=("cause:$2"); shift 2 ;;
      --device) [ "$#" -ge 2 ] || usage; case "$2" in phone|computer) ;; *) usage ;; esac; candidates+=("device:$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "${T3CODE_THREAD_ID:-}" ] && t3_ready || return 0
  value=$(first_cause "${candidates[@]+"${candidates[@]}"}") || value=computer
  claim_turn 1 "$value" || return 0
  # The sweep names its runs, so it needs no tie to this turn: detached, it
  # never holds up the drain. A failed turn claim above skips it, so an
  # unreachable T3 costs one log line. It runs as its own process, because
  # each bounded call stops when the process that made it is gone.
  ( exec "$SCRIPT_DIR/fm-t3-usage-claim.sh" _sweep "$T3CODE_THREAD_ID" </dev/null >/dev/null 2>&1 & )
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in
  turn) verb_turn "$@" ;;
  wake) verb_wake "$@" ;;
  # wake's detached sweep (header); not a public verb.
  _sweep) [ "$#" -eq 1 ] || usage; t3_ready && sweep "$1" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
exit 0
