#!/usr/bin/env bash
# fm-agy-t3-ring.sh - Antigravity (agy) primary supervision inside a T3 Code
# thread (fork): the turn ends at once, and one detached waiter rings the
# thread when a real wake arrives.
#
# Usage: fm-agy-t3-ring.sh start
#        fm-agy-t3-ring.sh -h|--help
# The waiter's own entry, `_run`, is started only by `start`.
#
# WHY. Antigravity runs every hook synchronously (its embedded hook reference:
# "Hooks run synchronously and block the agent loop (no async execution)"), so
# bin/fm-turnend-guard-agy.sh parks supervision inside the Stop hook. T3 Code
# serves the thread through `antigravity acp`, where that park keeps the ACP
# prompt open: the thread shows the turn as still thinking for as long as the
# park lasts, a wake arrives inside that same prompt, and T3's prompt
# inactivity bound for Antigravity (15 minutes) fails the prompt and replaces
# the agent. This file gives that hook the shape of
# upstream's asynchronous Codex park (bin/fm-codex-stop-park.sh): the hook
# returns at once, one waiter outside the agent's process tree owns the cycle,
# and only a real wake starts a turn, sent through T3 into FirstMate's own
# thread.
#
# START (bin/fm-turnend-guard-agy.sh runs it after its own guards, inside the
# Stop hook). Exit 0 means the turn may end: a waiter of this session is
# waiting, or the new one reported its first watcher status line, or it already
# delivered a wake, found nothing to supervise, or left a verified healthy
# watcher, all within FM_AGY_T3_RING_START_TIMEOUT seconds (default: the arm's
# own confirmation bound, the guard grace or at least 10 seconds, plus 30).
# Exit 1 means the ring does not apply or could not start, and the hook parks in
# place exactly as before. The ring applies only when the session runs in a T3
# Code thread (T3CODE_THREAD_ID, plain id characters), the home holds a T3
# credential (config/t3code-token), jq, node and perl are present, this
# process's session holds the fleet lock (fm_session_lock_owned_by_self), and no
# failure has latched this lock holder to the blocking park. A waiter that did
# not confirm in time is stopped before exit 1, so the blocking park never runs
# beside it.
#
# THE WAITER. A double fork with setsid starts it with every descriptor closed,
# so it shares no pipe, process group, or session with the agent or the hook.
# It owns the single-flight claim state/.agy-t3-ring.lock, takes the park baton
# state/.agy-park-owner that the blocking park also claims, and records itself
# in state/.agy-t3-ring.json:
#   {pid, identity, token, anchor, anchor_identity, thread, outcome, at}
# where anchor is the lock holder the starting hook proved, token names the
# start that launched it, and outcome is arming, waiting, delivering, delivered,
# delivery-failed, failed, idle, healthy, or stood-down. Having no harness
# ancestry, it owns the cycle only while fm_session_lock_held_by still names
# that anchor, the baton is still its own, and no away-daemon record
# (state/.afk) exists; losing any of those stops it and its cycle silently. It
# runs bin/fm-watch-arm.sh, or on a home that runs the supervision host for agy
# the host's park bound to the same anchor (FM_SUPERVISION_HOST_LOCK_PID and
# FM_SUPERVISION_HOST_LOCK_IDENTITY), as its tracked child, polled every
# FM_AGY_PARK_POLL seconds (default 2), and judges each close as the blocking
# park does: an actionable close is delivered, a host that stood down ends the
# waiter, a host that died is retried, a non-actionable close beside a verified
# healthy watcher ends it, and a failed cycle is retried once. The waiter
# outlives the turns it spans, so a later Stop finds it waiting and returns at
# once; it exits after delivering, and the woken turn's Stop starts the next.
#
# DELIVERY. The wake becomes a record-backed watcher doorbell
# (bin/fm-operational-input.sh), sent to the thread by
# fm_backend_t3code_turn_start (bin/backends/t3code.sh) in T3's auto mode,
# which starts a turn on an idle thread and otherwise reaches the turn already
# running. A send is tried three times, the n-th retry
# after n times FM_AGY_T3_RING_SEND_BACKOFF seconds (default 5); that function
# reuses the client request id after an unconfirmed delivery, so a retry of a
# send that had landed is not doubled. A send that
# still fails leaves the wake in the durable queue. A failed send, a cycle that
# still failed after its retry, and a start that did not confirm all latch this
# lock holder to the blocking park through state/.agy-t3-ring-fallback (the
# holder's pid and identity), and a cycle failure is also rung as one failure
# notice; the next Stop then parks in place, where the bounded repair nag of
# bin/fm-turnend-guard.sh --agy applies. A new session, or removing the file,
# starts unlatched.
#
# GAP. Nothing re-rings a failed delivery. Once all three sends of a wake fail,
# or the cycle-failure notice cannot be sent, the waiter has exited and no
# watcher cycle, waiter, or turn remains: the Antigravity main session is
# unsupervised, and the wake waits in the durable queue, until the captain's
# next message starts a turn whose Stop hook reads the latch and parks in place.
#
# WINDOW. A wake can be rung while the Stop hook is still open: the cycle closes
# at once on a wake already pending at turn end, so the waiter delivers before
# `start` returns, or a wake closes just after the `waiting` return, before the
# ACP prompt has actually ended. That send reaches the ending turn, and relies
# on T3 or Antigravity turning it into a fresh turn. If either drops it, the
# waiter has already exited as delivered: the main session is unsupervised until
# the captain's next message, and nothing records it. Unproven live.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

CLAIM="$STATE/.agy-t3-ring.lock"
RECORD="$STATE/.agy-t3-ring.json"
FALLBACK="$STATE/.agy-t3-ring-fallback"
BATON="$STATE/.agy-park-owner"
WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM_ATTEMPTS=2
SEND_ATTEMPTS=3
# Seconds the n-th failed send waits before the next, times n; a test seam.
SEND_BACKOFF=${FM_AGY_T3_RING_SEND_BACKOFF:-5}
case "$SEND_BACKOFF" in ''|*[!0-9]*) SEND_BACKOFF=5 ;; esac

GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*) GRACE=300 ;; esac
POLL=${FM_AGY_PARK_POLL:-2}
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
START_TIMEOUT=${FM_AGY_T3_RING_START_TIMEOUT:-}
case "$START_TIMEOUT" in
  ''|*[!0-9]*|0)
    START_TIMEOUT=$GRACE
    [ "$START_TIMEOUT" -ge 10 ] || START_TIMEOUT=10
    START_TIMEOUT=$((START_TIMEOUT + 30))
    ;;
esac

ANCHOR=
ANCHOR_IDENTITY=
THREAD=
TOKEN=
IDENTITY=
BATON_TOKEN=
CHILD=
OUT=
OWNED=0

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

latched() {
  [ -f "$FALLBACK" ] || return 1
  [ "$(sed -n '1p' "$FALLBACK" 2>/dev/null)" = "$ANCHOR" ] \
    && [ "$(sed -n '2p' "$FALLBACK" 2>/dev/null)" = "$ANCHOR_IDENTITY" ]
}

latch() {
  local tmp="$FALLBACK.tmp.$$"
  { printf '%s\n%s\n' "$ANCHOR" "$ANCHOR_IDENTITY" > "$tmp" && mv -f "$tmp" "$FALLBACK"; } 2>/dev/null \
    || rm -f "$tmp" 2>/dev/null
  return 0
}

# Does the ring apply to this hook's session? Sets ANCHOR and ANCHOR_IDENTITY.
capable() {
  case "${T3CODE_THREAD_ID:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -s "$CONFIG/t3code-token" ] || return 1
  command -v jq >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
    && command -v perl >/dev/null 2>&1 || return 1
  [ -f "$SCRIPT_DIR/backends/t3code.sh" ] && [ -f "$SCRIPT_DIR/fm-backend.sh" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  ANCHOR=$(cat "$STATE/.lock" 2>/dev/null || true)
  ANCHOR_IDENTITY=$(fm_session_pid_identity "$ANCHOR" 2>/dev/null) && [ -n "$ANCHOR_IDENTITY" ] || return 1
  ! latched
}

# --- start ---------------------------------------------------------------------

# Read the live claim holder whose record is its own into W_* and succeed, or
# fail when no waiter is alive.
read_live_waiter() {
  local pid identity
  W_OUTCOME='' W_ANCHOR='' W_ANCHOR_IDENTITY='' W_THREAD='' W_TOKEN=''
  pid=$(cat "$CLAIM/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  read_record "$pid" "$identity"
}

# read_record [<pid> <identity>]: load the record into W_*, requiring that
# writer when one is named.
read_record() {
  local fields
  [ -f "$RECORD" ] || return 1
  fields=$(jq -r --arg pid "${1:-}" --arg identity "${2:-}" '
    select(($pid == "" or (.pid | tostring) == $pid) and ($identity == "" or .identity == $identity))
    | [.outcome, .anchor, .anchor_identity, .thread, .token, (.pid | tostring)] | map(tostring) | join("\u001f")
  ' "$RECORD" 2>/dev/null) || return 1
  [ -n "$fields" ] || return 1
  IFS=$'\037' read -r W_OUTCOME W_ANCHOR W_ANCHOR_IDENTITY W_THREAD W_TOKEN W_PID <<EOF
$fields
EOF
}

ours() {
  [ "$W_ANCHOR" = "$ANCHOR" ] && [ "$W_ANCHOR_IDENTITY" = "$ANCHOR_IDENTITY" ] && [ "$W_THREAD" = "$THREAD" ]
}

launch() {
  # Double fork with setsid, as bin/fm-job.sh starts its runner: the waiter is
  # reparented to init with no controlling terminal and no tie to the agent's
  # process tree, group, or session, and every descriptor above stderr is
  # closed so the hook's own pipes see EOF when the hook exits.
  # shellcheck disable=SC2016 # Perl code, not shell.
  perl -MPOSIX -e '
    defined(my $p = fork) or die "fork: $!\n";
    if ($p) { waitpid($p, 0); exit($? >> 8); }
    POSIX::setsid() or POSIX::_exit(1);
    defined(my $q = fork) or POSIX::_exit(1);
    POSIX::_exit(0) if $q;
    open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">&", \*STDOUT);
    POSIX::close($_) for 3 .. 255;
    exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
  ' "${BASH:-bash}" "$SELF" _run "$TOKEN" "$THREAD" "$ANCHOR" "$ANCHOR_IDENTITY"
}

# Stop the waiter this start launched, when it is still running.
stop_launched() {
  local i
  read_live_waiter || return 0
  [ "$W_TOKEN" = "$TOKEN" ] || return 0
  kill -TERM "$W_PID" 2>/dev/null || return 0
  i=0
  while [ "$i" -lt 50 ] && fm_pid_alive "$W_PID"; do
    sleep 0.1
    i=$((i + 1))
  done
}

cmd_start() {
  local deadline launched=0 now
  capable || return 1
  THREAD=$T3CODE_THREAD_ID
  TOKEN=$(printf 'start-%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}")
  deadline=$(( $(date +%s) + START_TIMEOUT ))
  while :; do
    if read_live_waiter; then
      # Waiting for this session: it owns the cycle. Any other live waiter is
      # ours still arming, one finishing a delivery, or another session's that
      # stands down at its next poll, so wait for it.
      if ours && [ "$W_OUTCOME" = waiting ]; then
        return 0
      fi
    elif [ "$launched" -eq 1 ]; then
      if read_record && [ "$W_TOKEN" = "$TOKEN" ]; then
        case "$W_OUTCOME" in
          delivered|idle|healthy) return 0 ;;
          stood-down) return 1 ;;
          arming|waiting|delivering) ;;
          *) latch; return 1 ;;
        esac
      fi
    else
      launch || { latch; return 1; }
      launched=1
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || break
    sleep 0.2
  done
  stop_launched
  latch
  return 1
}

# --- the waiter -----------------------------------------------------------------

record() {  # <outcome>
  local tmp="$RECORD.tmp.$$"
  [ "$OWNED" -eq 1 ] || return 1
  if jq -n --argjson pid "$$" --arg identity "$IDENTITY" --arg token "$TOKEN" \
      --arg anchor "$ANCHOR" --arg anchor_identity "$ANCHOR_IDENTITY" --arg thread "$THREAD" \
      --arg outcome "$1" --argjson at "$(date +%s)" \
      '{pid:$pid,identity:$identity,token:$token,anchor:$anchor,anchor_identity:$anchor_identity,thread:$thread,outcome:$outcome,at:$at}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$RECORD" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

still_ours() {
  [ "$(cat "$BATON" 2>/dev/null || true)" = "$BATON_TOKEN" ] || return 1
  fm_session_lock_held_by "$STATE" "$ANCHOR" "$ANCHOR_IDENTITY" || return 1
  [ ! -e "$STATE/.afk" ]
}

stand_down() {
  record stood-down
  exit 0
}

# shellcheck disable=SC2329 # EXIT trap owns cleanup.
cleanup() {
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null
  [ "$OWNED" -eq 0 ] || fm_lock_release "$CLAIM"
}

# Ring the thread with one watcher doorbell, retrying the send.
deliver() {  # <body>
  local doorbell='' i=0
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source t3code >/dev/null 2>&1 || return 1
  fm_operational_record_write "$STATE" watcher "$1" doorbell || return 1
  unset FM_T3_FROM_THREAD FM_T3CODE_CLIENT_REQUEST_ID
  while [ "$i" -lt "$SEND_ATTEMPTS" ]; do
    fm_backend_t3code_turn_start "$THREAD" "$doorbell" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    [ "$i" -ge "$SEND_ATTEMPTS" ] || sleep $((i * SEND_BACKOFF))
  done
  return 1
}

cmd_run() {
  local attempt=0 confirmed=0 ever_confirmed=0 rc host_mode=0 actionable_re wake
  TOKEN=${1:-} THREAD=${2:-} ANCHOR=${3:-} ANCHOR_IDENTITY=${4:-}
  [ -n "$TOKEN" ] && [ -n "$THREAD" ] && [ -n "$ANCHOR" ] && [ -n "$ANCHOR_IDENTITY" ] || exit 2
  IDENTITY=$(fm_pid_identity "$$") || exit 1
  fm_lock_try_acquire "$CLAIM" || exit 0
  OWNED=1
  trap cleanup EXIT
  trap 'stand_down' HUP INT TERM
  # The claim proves no other waiter still uses these captures.
  rm -f "$STATE"/.agy-t3-ring-output.* "$RECORD".tmp.* 2>/dev/null
  BATON_TOKEN="ring:$$:$TOKEN"
  printf '%s\n' "$BATON_TOKEN" > "$BATON" || exit 1
  record arming || exit 1
  fm_session_lock_held_by "$STATE" "$ANCHOR" "$ANCHOR_IDENTITY" || stand_down

  actionable_re='^(signal:|stale:|check:|heartbeat($|:))'
  if fm_supervision_host_enabled "$CONFIG" agy; then
    host_mode=1
    actionable_re='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
  fi

  while [ "$attempt" -lt "$ARM_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    still_ours || stand_down
    if ! fm_supervision_needed "$STATE" "$GRACE"; then
      record idle
      exit 0
    fi
    OUT=$(mktemp "$STATE/.agy-t3-ring-output.XXXXXX") || { OUT=; break; }
    if [ "$host_mode" -eq 1 ]; then
      FM_SUPERVISION_HOST_PRIMARY=agy FM_SUPERVISION_HOST_LOCK_PID="$ANCHOR" \
        FM_SUPERVISION_HOST_LOCK_IDENTITY="$ANCHOR_IDENTITY" \
        "$SCRIPT_DIR/fm-supervision-host.sh" park > "$OUT" 2>&1 < /dev/null &
    else
      "$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 < /dev/null &
    fi
    CHILD=$!
    confirmed=0
    while kill -0 "$CHILD" 2>/dev/null; do
      if [ "$confirmed" -eq 0 ] && grep -Eq '^watcher: (started|attached)' "$OUT" 2>/dev/null; then
        confirmed=1
        ever_confirmed=1
        record waiting
      fi
      still_ours || stand_down
      sleep "$POLL"
    done
    rc=0
    wait "$CHILD" 2>/dev/null || rc=$?
    CHILD=
    still_ours || stand_down

    if grep -Eq "$actionable_re" "$OUT" 2>/dev/null; then
      if [ "$host_mode" -eq 1 ]; then
        wake=$(awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null)
      else
        wake=$(grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8)
      fi
      record delivering
      if deliver "firstmate watcher wake - one supervision event needs a handling turn now.
$wake

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. Inside a T3 Code thread the Antigravity Stop hook never parks the turn: it leaves the next cycle to one detached waiter, which rang this thread. When the handling turn ends, the next cycle starts automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."; then
        rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
        record delivered
        exit 0
      fi
      record delivery-failed
      latch
      exit 1
    fi

    if [ "$host_mode" -eq 1 ]; then
      grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null && stand_down
      if [ "$rc" -gt 128 ] || [ ! -s "$OUT" ]; then
        rm -f "$OUT" 2>/dev/null
        OUT=
        continue
      fi
    fi
    # A non-actionable close is benign beside a verified healthy watcher.
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      record healthy
      exit 0
    fi
    rm -f "$OUT" 2>/dev/null
    OUT=
  done

  if ! fm_supervision_needed "$STATE" "$GRACE"; then
    record idle
    exit 0
  fi
  record failed
  latch
  # The starting hook has already returned unless the cycle never confirmed, in
  # which case it parks in place and owns the repair itself.
  [ "$ever_confirmed" -eq 1 ] || exit 1
  deliver "firstmate watcher auto-arm FAILED - the detached Antigravity T3 waiter could not keep a live watcher cycle after a retry.
Run bin/fm-wake-drain.sh first and handle anything queued, then inspect the watcher startup path (state/.agy-t3-ring.json records the waiter). This session now parks supervision inside its Stop hook, so the thread shows the turn as running between turns; remove state/.agy-t3-ring-fallback once the cause is fixed to return to the ring." || true
  exit 1
}

case "${1:-}" in
  start) cmd_start; exit $? ;;
  _run) shift; cmd_run "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
