#!/usr/bin/env bash
# fm-t3-usage-claim.sh - Firstmate's usage claims on T3 Code: tell T3's Usage
# page where work it cannot trace on its own comes from, through the fork's
# t3_usage_claim (docs/t3code-backend.md "Usage claims" owns the operator
# contract; bin/fm-t3-mcp.mjs usage-claim owns the call).
#
# Every claim is best effort. A claim that cannot be made (no T3 credential,
# a T3 without t3_usage_claim, no T3 turn, nothing to name) is skipped
# silently, and a claim that fails is logged once, as one line in
# state/t3-usage-claims.log, and never retried by this run; the nightly
# bin/fm-usage-labels-check.sh raises its item for any such line. Every verb
# exits 0 except invalid use (2), so no wake or turn ever waits on its
# accounting. Sessions T3 does not run - pipeline reviews, the supervision
# engine, a worker's own probes - are not claimed: they register themselves
# when they start (docs/t3code-backend.md "Usage claims").
#
# Usage:
#   fm-t3-usage-claim.sh turn (--device phone|computer | --process incident | --task <id> | --from-thread <reference>)
#     Claim the calling agent's T3 turn running now ($T3CODE_THREAD_ID): it
#     counts to that device, as incident response (to the computer, as
#     incident work), with task <id>'s work, or with that origin reference's
#     work. For a turn the drain's claim does not describe, such as the turn
#     that files a voice journal (--device phone) or one that handles a
#     production alert no drain in it presented (--process incident). It
#     replaces any claim on that turn, and a later drain in the same turn
#     leaves it.
#   fm-t3-usage-claim.sh wake [--task <id> | --from-thread <reference> | --caused-by <cause-json> | --device phone|computer | --process incident]...
#     The wake drain's claim on the current turn. It tries the candidates
#     that name something, in order and each distinct value once, until T3
#     binds one: a task's own thread
#     (where that task counts now; for an item queued as upkeep with no
#     thread yet, the computer, as journal, the phone, and as incident,
#     incident work), a reference given, a cause given (one a note or
#     follow-up recorded before references existed, passed on unchanged), a
#     device given, such as the phone for a voice journal's note, or a
#     process given, incident for a production alert's note. T3 refuses a reference or cause it cannot bind, such as a task
#     whose work counts to no device, and the next candidate gets its turn;
#     a T3 that cannot take a process skips that candidate the same way; a
#     wake none of whose candidates binds is logged as failing to name its
#     turn. A turn that already has a claim keeps it (T3's ifUnclaimed).
#     With no candidate at all, nothing is claimed: T3 files a coordinator
#     turn that no claim names and no person typed as upkeep by itself, so
#     upkeep needs no claim.
#
# state/t3-usage-claims.log holds one tab-separated line per failed claim
# (UTC time, what was claimed, the error), trimmed as it grows.
# A task's reference is bin/fm-t3-origin-lib.sh's fm_t3_origin_of_task.
# FM_T3_USAGE_CLAIM_TIMEOUT (seconds, default 20) bounds each T3 call.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TOKEN="${FM_T3CODE_TOKEN_FILE:-$CONFIG/t3code-token}"
HELPER="$SCRIPT_DIR/fm-t3-mcp.mjs"
LOG="$STATE/t3-usage-claims.log"
TIMEOUT=${FM_T3_USAGE_CLAIM_TIMEOUT:-20}
case "$TIMEOUT" in ''|0*|*[!0-9]*) TIMEOUT=20 ;; esac
export FM_HOME

# shellcheck source=bin/fm-t3-origin-lib.sh
. "$SCRIPT_DIR/fm-t3-origin-lib.sh"
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

# CLAIM_OUT holds the helper's answer to the last claim.
CLAIM_OUT=

# claim <usage-claim args...>: one bounded call on the calling agent's turn.
# 0 claimed (or kept); 3 this T3 cannot take the claim, the absence of a
# feature rather than a failure; 4 T3 refused the value, which another value
# may not be; 1 any other failure. Logs nothing: the caller does.
claim() {
  local rc=0
  CLAIM_OUT=$(fm_exec_timed "$TIMEOUT" 2 node "$HELPER" usage-claim --turn "$T3CODE_THREAD_ID" "$@" --token-file "$TOKEN" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$CLAIM_OUT" in
    *'"usage_claim_unsupported"'*) return 3 ;;
    *'"origin_refused"'*|*'"cause_refused"'*) return 4 ;;
  esac
  return 1
}

# value_args <value>: the usage-claim value flags for a device, upkeep (the
# computer), journal (the phone, which T3 files as journal), incident (the
# process T3 files as incident work), a reference, or a cause.
value_args() {
  case "$1" in
    phone|computer) printf '%s\n' --device "$1" ;;
    upkeep) printf '%s\n' --device computer ;;
    journal) printf '%s\n' --device phone ;;
    incident) printf '%s\n' --process incident ;;
    *) printf '%s\n%s\n' "$(fm_t3_origin_flag "$1")" "$1" ;;
  esac
}

# candidate_value <candidate>: what task:<id>, from:<reference>,
# cause:<json>, device:<device>, or process:<process> names, or nothing.
candidate_value() {
  case "$1" in
    task:*) fm_t3_origin_of_task "$STATE" "${1#task:}" ;;
    from:*|cause:*|device:*|process:*) printf '%s' "${1#*:}" ;;
  esac
}

# claim_value <value> [--if-unclaimed]: claim the calling agent's turn with
# <value>; the claim's status as claim returns it.
claim_value() {
  local value=$1 line
  local -a args=()
  shift
  while IFS= read -r line; do args+=("$line"); done < <(value_args "$value")
  claim "${args[@]}" "$@"
}

verb_turn() {
  local candidate='' n=0 value rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --device) [ "$#" -ge 2 ] || usage; case "$2" in phone|computer) ;; *) usage ;; esac; candidate=device:$2; n=$((n + 1)); shift 2 ;;
      --process) [ "$#" -ge 2 ] || usage; [ "$2" = incident ] || usage; candidate=process:$2; n=$((n + 1)); shift 2 ;;
      --task) [ "$#" -ge 2 ] || usage; candidate=task:$2; n=$((n + 1)); shift 2 ;;
      --from-thread) [ "$#" -ge 2 ] || usage; candidate=from:$2; n=$((n + 1)); shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$n" -eq 1 ] || usage
  value=$(candidate_value "$candidate")
  if [ -z "$value" ]; then
    echo "fm-t3-usage-claim: ${candidate%%:*} ${candidate#*:} names no T3 thread; nothing claimed" >&2
    return 0
  fi
  [ -n "${T3CODE_THREAD_ID:-}" ] && t3_ready || return 0
  claim_value "$value" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || log_failure "turn $T3CODE_THREAD_ID" "$CLAIM_OUT"
}

verb_wake() {
  local -a candidates=() tried=()
  local c t value rc refused=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || usage; candidates+=("task:$2"); shift 2 ;;
      --from-thread) [ "$#" -ge 2 ] || usage; candidates+=("from:$2"); shift 2 ;;
      --caused-by) [ "$#" -ge 2 ] || usage; candidates+=("cause:$2"); shift 2 ;;
      --device) [ "$#" -ge 2 ] || usage; case "$2" in phone|computer) ;; *) usage ;; esac; candidates+=("device:$2"); shift 2 ;;
      --process) [ "$#" -ge 2 ] || usage; [ "$2" = incident ] || usage; candidates+=("process:$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  [ "${#candidates[@]}" -gt 0 ] && [ -n "${T3CODE_THREAD_ID:-}" ] && t3_ready || return 0
  for c in "${candidates[@]}"; do
    value=$(candidate_value "$c")
    [ -n "$value" ] || continue
    for t in ${tried[@]+"${tried[@]}"}; do
      [ "$t" != "$value" ] || continue 2
    done
    tried+=("$value")
    rc=0
    claim_value "$value" --if-unclaimed || rc=$?
    case "$rc" in
      0) return 0 ;;
      # This candidate cannot be bound or this T3 cannot take it; the next
      # one may be.
      3) ;;
      4) refused=$CLAIM_OUT ;;
      *) log_failure "wake turn $T3CODE_THREAD_ID ($c)" "$CLAIM_OUT"; return 0 ;;
    esac
  done
  [ -z "$refused" ] || log_failure "wake turn $T3CODE_THREAD_ID: no candidate bound" "$refused"
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in
  turn) verb_turn "$@" ;;
  wake) verb_wake "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
exit 0
