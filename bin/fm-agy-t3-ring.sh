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
# Stop hook). Exit 3 hands back a held wake (THE HELD WAKE below): its text is
# on stdout, and the hook returns it as its own continue decision, so the wake
# is handled in the turn that is still open. Exit 0 means the turn may end: a
# waiter of this session is waiting, or the new one reported its first watcher
# status line, or it already delivered a wake, found nothing to supervise, or
# left a verified healthy watcher, all within FM_AGY_T3_RING_START_TIMEOUT
# seconds (default: the arm's own confirmation bound, the guard grace or at
# least 10 seconds, plus 30). Exit 1 means the ring does not apply or could not
# start, and the hook parks in place exactly as before. The ring applies only
# when the session runs in a T3 Code thread (T3CODE_THREAD_ID, plain id
# characters), the home holds a T3 credential (config/t3code-token), jq, node
# and perl are present, and this process's session holds the fleet lock
# (fm_session_lock_owned_by_self). A held wake is then handed back first;
# otherwise a failure that latched this lock holder to the blocking park (LATCH
# below) also means exit 1. A waiter that did not confirm in time is stopped
# before exit 1, so the blocking park never runs beside it.
#
# THE WAITER. A double fork with setsid starts it with every descriptor closed,
# so it shares no pipe, process group, or session with the agent or the hook.
# It owns the single-flight claim state/.agy-t3-ring.lock, takes the park baton
# state/.agy-park-owner that the blocking park also claims, and records itself
# in state/.agy-t3-ring.json:
#   {pid, identity, token, anchor, anchor_identity, thread, outcome, failures, at}
# where anchor is the lock holder the starting hook proved, token names the
# start that launched it, failures counts the failed tries to ring its wake,
# and outcome is arming, waiting, holding, delivered, handed-over,
# delivery-failed, failed, idle, healthy, or stood-down. Having no harness
# ancestry, it owns the cycle only while fm_session_lock_held_by still names
# that anchor, the baton is still its own, and no away-daemon record
# (state/.afk) exists; losing any of those stops it and its cycle silently,
# leaving any held wake for the next Stop hook. It runs bin/fm-watch-arm.sh, or
# on a home that runs the supervision host for agy the host's park bound to the
# same anchor (FM_SUPERVISION_HOST_LOCK_PID and
# FM_SUPERVISION_HOST_LOCK_IDENTITY), as its tracked child, polled every
# FM_AGY_PARK_POLL seconds (default 2), and judges each close as the blocking
# park does: an actionable close is held and delivered, a host that stood down
# ends the waiter, a host that died is retried, a non-actionable close beside a
# verified healthy watcher ends it, and a failed cycle is retried once. The
# waiter outlives the turns it spans, so a later Stop finds it waiting and
# returns at once; it exits once its wake is delivered or handed back, and the
# next Stop starts the next.
#
# THE HELD WAKE. An actionable close, or the failure notice below, is first
# written to state/.agy-t3-ring-wake, and the record reads holding. One of two
# owners then takes it, each by an atomic rename, so it is delivered once:
#   - a Stop hook that runs `start` hands it back (exit 3), so a wake that
#     closes while a turn is still open, such as one already pending at turn
#     end, carries on in that turn and is never rung into it;
#   - the waiter rings it, but only when T3 reads the thread with no turn
#     running (fm_backend_t3code_probe idle, ready, interrupted, or error), so
#     the message starts a fresh turn instead of being steered into one that
#     may be ending. While a turn runs (starting, running, or blocked on a
#     request) the waiter waits, uncounted, polling every FM_AGY_PARK_POLL
#     seconds, and that turn's own Stop hook takes the wake if it gets there
#     first.
# Ringing moves the file to state/.agy-t3-ring-wake.sending for the send, and
# back when the send does not land; a `start` that finds no live waiter takes
# either name, so a waiter that died mid-send strands nothing.
#
# DELIVERY. The wake becomes a record-backed watcher doorbell
# (bin/fm-operational-input.sh), sent by fm_backend_t3code_turn_start
# (bin/backends/t3code.sh) in T3's auto mode under one client request id, which
# is reused after a failed or unconfirmed send so a retry of a send that had
# landed is not doubled. A send lands only when T3 reports that it started or
# queued a fresh turn (the delivery its accepted record keeps). A message T3
# steered into a running turn may have reached the turn that is ending, so the
# wake is held again, the next try is a new message, and the steered turn's own
# Stop hook can take the wake meanwhile. A failed read of the thread, a send
# that did not land, and a steer each count as one failed try; the next try
# waits FM_AGY_T3_RING_SEND_BACKOFF seconds (default 5), doubling to at most
# 300, and the tenth failed try, about 20 minutes after the first, gives up.
# Giving up puts a "GAVE UP" notice in front of the held wake, records
# delivery-failed, and latches this lock holder to the blocking park. Nothing
# rings the thread after that, so the session stays unsupervised until the
# captain's next message; that turn's Stop hook hands back the notice and the
# wake before later turn ends park in place, and the wake also stays in the
# durable queue for the next drain or session start.
#
# LATCH. A give-up, a cycle that still failed after its retry, and a start that
# did not confirm all latch this lock holder to the blocking park through
# state/.agy-t3-ring-fallback (the holder's pid and identity). A cycle failure
# is also held and delivered as one failure notice; the next Stop then parks in
# place, where the bounded repair nag of bin/fm-turnend-guard.sh --agy applies.
# A new session, or removing the file, starts unlatched.
#
# UNPROVEN LIVE. tests/fm-agy-t3-ring.test.sh models T3's run states and its
# started and steered replies with a fake T3 server, not Antigravity's ACP
# prompt: that T3 reads the thread as running for as long as the Stop hook is
# open, and that a ring sent once the thread reads idle starts a turn
# Antigravity runs, need a live session (docs/verification/agy.md).
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
HELD="$STATE/.agy-t3-ring-wake"
BATON="$STATE/.agy-park-owner"
WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM_ATTEMPTS=2
SEND_ATTEMPTS=10
BACKOFF_CAP=300
# Seconds the first failed try waits before the next, doubling; a test seam.
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
FAILURES=0
HELD_TEXT=
WAKE_BODY=
DOORBELL=
REQUEST_ID=

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
  ANCHOR_IDENTITY=$(fm_session_pid_identity "$ANCHOR" 2>/dev/null) && [ -n "$ANCHOR_IDENTITY" ]
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

# Take the held wake into HELD_TEXT, from a waiter's held file, or from its
# in-flight send when no waiter is alive to finish it.
take_held() {
  local mine="$HELD.taken.$$"
  HELD_TEXT=
  if ! mv "$HELD" "$mine" 2>/dev/null; then
    ! fm_pid_alive "$(cat "$CLAIM/pid" 2>/dev/null || true)" \
      && mv "$HELD.sending" "$mine" 2>/dev/null || return 1
  fi
  HELD_TEXT=$(cat "$mine" 2>/dev/null || true)
  rm -f "$mine" 2>/dev/null
  [ -n "$HELD_TEXT" ]
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
  if ! take_held; then
    latched && return 1
  fi
  while :; do
    # A wake the waiter holds while this hook is open belongs to this turn.
    if [ -n "$HELD_TEXT" ] || take_held; then
      printf '%s\n' "$HELD_TEXT"
      return 3
    fi
    if read_live_waiter; then
      # Waiting for this session: it owns the cycle. Any other live waiter is
      # ours still arming or mid-send, one finishing a delivery, or another
      # session's that stands down at its next poll, so wait for it.
      if ours && [ "$W_OUTCOME" = waiting ]; then
        return 0
      fi
    elif [ "$launched" -eq 1 ]; then
      if read_record && [ "$W_TOKEN" = "$TOKEN" ]; then
        case "$W_OUTCOME" in
          delivered|idle|healthy) return 0 ;;
          stood-down|handed-over) return 1 ;;
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
      --arg outcome "$1" --argjson failures "$FAILURES" --argjson at "$(date +%s)" \
      '{pid:$pid,identity:$identity,token:$token,anchor:$anchor,anchor_identity:$anchor_identity,thread:$thread,outcome:$outcome,failures:$failures,at:$at}' \
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

# nap <seconds>: sleep in poll slices, standing down when the cycle is no longer
# ours and ending when a Stop hook took the held wake.
nap() {
  local left=$1 step
  while :; do
    still_ours || stand_down
    [ -e "$HELD" ] || { record handed-over; exit 0; }
    [ "$left" -gt 0 ] || return 0
    step=$POLL
    [ "$step" -le "$left" ] || step=$left
    sleep "$step"
    left=$((left - step))
  done
}

# One send of the claimed wake; 0 once T3 took it as a fresh turn.
send() {
  [ -n "$DOORBELL" ] || fm_operational_record_write "$STATE" watcher "$WAKE_BODY" DOORBELL || return 1
  [ -n "$REQUEST_ID" ] || REQUEST_ID=$(printf 'fm-agy-ring-%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}")
  FM_T3CODE_CLIENT_REQUEST_ID=$REQUEST_ID fm_backend_t3code_turn_start "$THREAD" "$DOORBELL" >/dev/null 2>&1 \
    || return 1
  [ "$(jq -r '.delivery // empty' "$STATE/t3code-sends/$REQUEST_ID.accepted" 2>/dev/null)" != steered ] \
    && return 0
  REQUEST_ID=
  return 1
}

# Ring the held wake into this thread as a fresh turn: 0 once it landed, 1 once
# the tries ran out. Exits when a Stop hook took the wake.
ring() {
  local delay=$SEND_BACKOFF
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source t3code >/dev/null 2>&1 || return 1
  unset FM_T3_FROM_THREAD FM_T3CODE_CLIENT_REQUEST_ID
  while :; do
    nap 0
    case "$(fm_backend_t3code_probe "$THREAD")" in
      starting|running|blocked)
        nap "$POLL"
        continue
        ;;
      idle|ready|interrupted|error)
        if ! mv "$HELD" "$HELD.sending" 2>/dev/null; then
          record handed-over
          exit 0
        fi
        if send; then
          rm -f "$HELD.sending" 2>/dev/null
          return 0
        fi
        mv -f "$HELD.sending" "$HELD" 2>/dev/null
        ;;
    esac
    FAILURES=$((FAILURES + 1))
    record holding
    [ "$FAILURES" -lt "$SEND_ATTEMPTS" ] || return 1
    nap "$delay"
    delay=$((delay * 2))
    [ "$delay" -le "$BACKOFF_CAP" ] || delay=$BACKOFF_CAP
  done
}

# deliver <body>: hold the wake, then ring it, or give up visibly.
deliver() {
  local tmp="$HELD.tmp.$$"
  WAKE_BODY=$1
  { printf '%s\n' "$WAKE_BODY" > "$tmp" && mv -f "$tmp" "$HELD"; } 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    record delivery-failed
    latch
    exit 1
  }
  record holding
  ring && return 0
  # Rewrite the held wake with the notice in front, unless a Stop hook took it.
  if mv "$HELD" "$HELD.sending" 2>/dev/null; then
    { printf '%s\n\n%s\n' "firstmate T3 ring GAVE UP - the detached Antigravity T3 waiter could not ring this thread after $FAILURES tries (T3 unreachable, its credential refused, or every try reaching a turn already running), so supervision went quiet and the wake below waited for this turn. This session's later turn ends park supervision inside the Stop hook; remove state/.agy-t3-ring-fallback once T3 takes messages again to return to the ring." \
      "$WAKE_BODY" > "$tmp" && mv -f "$tmp" "$HELD"; } 2>/dev/null \
      || { rm -f "$tmp" 2>/dev/null; mv -f "$HELD.sending" "$HELD" 2>/dev/null; }
    rm -f "$HELD.sending" 2>/dev/null
  elif [ ! -e "$HELD.sending" ]; then
    record handed-over
    exit 0
  fi
  record delivery-failed
  latch
  exit 1
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
  rm -f "$STATE"/.agy-t3-ring-output.* "$RECORD".tmp.* "$HELD".tmp.* 2>/dev/null
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
      deliver "firstmate watcher wake - one supervision event needs a handling turn now.
$wake

Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. Inside a T3 Code thread the Antigravity Stop hook never parks the turn: it leaves the next cycle to one detached waiter, which brought this wake. When the handling turn ends, the next cycle starts automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake."
      rm -f "$STATE/.turnend-blocks" 2>/dev/null || true
      record delivered
      exit 0
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
Run bin/fm-wake-drain.sh first and handle anything queued, then inspect the watcher startup path (state/.agy-t3-ring.json records the waiter). This session now parks supervision inside its Stop hook, so the thread shows the turn as running between turns; remove state/.agy-t3-ring-fallback once the cause is fixed to return to the ring."
  record failed
  exit 1
}

case "${1:-}" in
  start) cmd_start; exit $? ;;
  _run) shift; cmd_run "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
