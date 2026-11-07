#!/usr/bin/env bash
# tests/fm-watch-worker-event.test.sh - bin/fm-watch.sh rings the worker-event
# doorbell for every worker-signal batch, including the routine turn-ends it
# absorbs, so a `when` watch armed with --on-worker-event re-checks at that
# moment instead of waiting out its interval, and its outcome reaches firstmate
# as an ordinary process-event wake.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-worker-event-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

COND="$TMP_ROOT/cond.sh"
cat > "$COND" <<'SH'
#!/usr/bin/env bash
echo x >> "$2"
[ -e "$1" ]
SH
ACT="$TMP_ROOT/act.sh"
cat > "$ACT" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$1"
SH
chmod +x "$COND" "$ACT"

lines() { [ -e "$1" ] && grep -c . "$1" || echo 0; }

# The process-event runner finds the `when` adapter under its code root, so it
# and the watcher (whose per-cycle reconcile can relaunch it) run with the real
# root rather than the inert one wake-helpers.sh exports for the tangle guard.
real_root() { FM_ROOT_OVERRIDE="$ROOT" "$@"; }

test_absorbed_turn_end_fires_the_watch_promptly() {
  local dir state fakebin out pid trig count log result i f n
  dir=$(make_case absorbed); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  fm_test_track_procevent_home "$dir"
  trig="$dir/trigger"; count="$dir/count"; log="$dir/act.log"
  FM_HOME="$dir" real_root "$ROOT/bin/fm-procevent-when.sh" arm idle --on-worker-event \
    --interval 600 --stable 1 --condition "$COND" "$trig" "$count" \
    --action "$ACT" "$log" >/dev/null || fail "cannot arm the watch"
  FM_HOME="$dir" real_root "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
  for i in $(seq 1 100); do [ "$(lines "$count")" -ge 1 ] && break; sleep 0.1; done
  [ "$(lines "$count")" -eq 1 ] || fail "the watch never ran its first poll"
  # The condition is now true, but nothing re-polls it before its interval.
  : > "$trig"
  sleep 2
  [ ! -e "$log" ] || fail "the watch fired before any worker event"

  # A routine turn-end whose crew is still working: the watcher absorbs it,
  # after lingering its signal grace. The ring comes before that linger, so the
  # watch fires well inside a 10 s grace.
  : > "$state/task.turn-ended"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_SIGNAL_GRACE=10
  pid=$!
  for i in $(seq 1 60); do [ -e "$log" ] && break; sleep 0.1; done
  [ -e "$log" ] || { reap "$pid"; fail "the absorbed turn-end did not trigger the watch within 6 s: $(cat "$out")"; }
  wait_for_exit "$pid" 300 || { reap "$pid"; fail "the watcher never delivered the watch outcome"; }
  grep -F "check: process-event result captured" "$out" >/dev/null \
    || fail "the outcome did not reach firstmate as a process-event wake: $(cat "$out")"
  if awk -F '\t' '$3 == "signal"' "$state/.wake-queue" | grep . >/dev/null; then
    fail "the routine turn-end must stay absorbed, not queued as a signal"
  fi
  result=; n=0
  for f in "$state/procevent-inbox"/when-idle.*.result; do [ -e "$f" ] && { result=$f; n=$((n + 1)); }; done
  [ "$n" -eq 1 ] || fail "expected exactly one watch outcome, found $n"
  grep -F 'status: fired' "$result" >/dev/null || fail "the captured outcome is not a fire: $(cat "$result")"
  [ "$(lines "$log")" -eq 1 ] || fail "the action ran more than once"
  pass "an absorbed turn-end re-checks an --on-worker-event watch at once and its outcome wakes firstmate"
}

test_absorbed_turn_end_fires_the_watch_promptly
