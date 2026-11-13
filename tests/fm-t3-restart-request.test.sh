#!/usr/bin/env bash
# tests/fm-t3-restart-request.test.sh - bin/fm-t3-restart-request.sh, the
# clean T3 restart: request it through the T3 Code fork's restart registry,
# wait until T3 reports drained, and cancel the request on a timeout, a stop,
# or a lost T3, driven through its CLI against tests/t3-fake-server.mjs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-restart-request-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
REQ="$ROOT/bin/fm-t3-restart-request.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

req() {  # <args...> -> stdout in OUT, exit in RC
  OUT=$(FM_HOME="$HOME_DIR" "$REQ" "$@" 2>"$TMP_ROOT/stderr")
  RC=$?
}

# world_get <js-expression over w>
world_get() {
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = eval(process.argv[2]); process.stdout.write(v == null ? "" : String(v))' "$T3_FAKE_WORLD" "$1"
}

IDLE_WORLD='{"restartRegistry":true,"activeTurns":0}'

fresh_case() {  # <name> [world-json]
  t3_fake_case "$TMP_ROOT/cases/$1" "${2:-$IDLE_WORLD}"
  t3_fake_credential "$HOME_DIR/config/t3code-token"
}

# wait_for <js-condition over w> <seconds>: poll the fake's world.
wait_for() {
  local i=0 limit=$(($2 * 10))
  while [ "$i" -lt "$limit" ]; do
    [ "$(world_get "($1) ? 1 : 0")" = 1 ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_drains_at_once_and_leaves_the_request_pending() {
  fresh_case drained
  req drain --reason "  install build a  " --interval 1
  expect_code 0 "$RC" "an idle T3 drains at once: $OUT $(cat "$TMP_ROOT/stderr")"
  assert_contains "$OUT" "requested the restart" "the request is reported"
  assert_contains "$OUT" "drained" "the drain is reported"
  assert_equals '{"reason":"install build a"}' "$(t3_fake_calls t3_restart_request)" "one trimmed request"
  assert_equals "install build a" "$(world_get 'w.restartRequest && w.restartRequest.reason')" \
    "the request stays pending, holding messages, until the restart"
  assert_equals "" "$(t3_fake_calls t3_restart_cancel)" "a drained run cancels nothing"
  pass "fm-t3-restart-request drain: an idle T3 drains at once and the request stays pending for the restart"
}

test_waits_for_running_turns() {
  local pid
  fresh_case waits '{"restartRegistry":true,"activeTurns":2}'
  ( req drain --reason "install build b" --interval 1; printf '%s\n%s\n' "$RC" "$OUT" > "$TMP_ROOT/waits.out" ) &
  pid=$!
  wait_for 'w.restartRequest' 10 || fail "the request should land while turns run"
  sleep 2
  [ ! -s "$TMP_ROOT/waits.out" ] || fail "drain must not return while turns run: $(cat "$TMP_ROOT/waits.out")"
  t3_fake_set 'w.activeTurns = 0'
  wait "$pid"
  assert_equals 0 "$(sed -n 1p "$TMP_ROOT/waits.out")" "drain returns 0 once the last turn ends: $(cat "$TMP_ROOT/waits.out")"
  assert_equals "install build b" "$(world_get 'w.restartRequest && w.restartRequest.reason')" "the request stays pending"
  pass "fm-t3-restart-request drain: waits while any turn runs, FirstMate's own included, and returns once T3 drains"
}

test_timeout_cancels_and_releases() {
  fresh_case timeout '{"restartRegistry":true,"activeTurns":1}'
  req drain --reason "install build c" --within 2 --interval 1
  expect_code 1 "$RC" "a T3 that never drains times out: $OUT"
  assert_contains "$OUT" "did not drain within 2s" "the timeout is reported"
  assert_contains "$OUT" "1 turn(s) still running" "the report names what kept it busy"
  assert_equals "" "$(world_get 'w.restartRequest')" "the timed-out request is cancelled, releasing held messages"
  pass "fm-t3-restart-request drain: a request that never drains is cancelled and reported, never left holding messages"
}

test_cancelled_in_t3_means_no_restart() {
  local pid
  fresh_case cancelled '{"restartRegistry":true,"activeTurns":1}'
  ( req drain --reason "install build d" --interval 1; printf '%s\n%s\n' "$RC" "$OUT" > "$TMP_ROOT/cancelled.out" ) &
  pid=$!
  wait_for 'w.restartRequest' 10 || fail "the request should land"
  t3_fake_set 'w.restartRequest = null; w.activeTurns = 0'
  wait "$pid"
  assert_equals 3 "$(sed -n 1p "$TMP_ROOT/cancelled.out")" "the captain's Cancel restart ends the wait with no restart"
  assert_contains "$(cat "$TMP_ROOT/cancelled.out")" "cancelled in T3" "the cancel is reported"

  fresh_case replaced '{"restartRegistry":true,"activeTurns":1}'
  ( req drain --reason "install build d" --interval 1; printf '%s\n%s\n' "$RC" "$OUT" > "$TMP_ROOT/replaced.out" ) &
  pid=$!
  wait_for 'w.restartRequest' 10 || fail "the request should land"
  t3_fake_set 'w.restartRequest.reason = "someone else"; w.activeTurns = 0'
  wait "$pid"
  assert_equals 3 "$(sed -n 1p "$TMP_ROOT/replaced.out")" "a replaced request is no longer this run's to restart on"
  assert_equals "someone else" "$(world_get 'w.restartRequest.reason')" "the replacement is left alone"

  fresh_case restarted '{"restartRegistry":true,"activeTurns":1}'
  ( req drain --reason "install build d" --interval 1; printf '%s\n%s\n' "$RC" "$OUT" > "$TMP_ROOT/restarted.out" ) &
  pid=$!
  wait_for 'w.restartRequest' 10 || fail "the request should land"
  t3_fake_set 'w.serverStartedAt = "2099-01-01T00:00:00.000Z"'
  wait "$pid"
  assert_equals 3 "$(sed -n 1p "$TMP_ROOT/restarted.out")" "a T3 that restarted on its own is not restarted again"
  assert_contains "$(cat "$TMP_ROOT/restarted.out")" "restarted on its own" "the restart is reported"
  pass "fm-t3-restart-request drain: a request cancelled or replaced in T3, or ended by a restart, never leads to a restart"
}

test_foreign_request_is_left_alone_and_own_is_adopted() {
  fresh_case foreign '{"restartRegistry":true,"activeTurns":0,"restartRequest":{"reason":"other work","requestedAt":"2026-11-13T00:00:00.000Z"}}'
  req drain --reason "install build e" --interval 1
  expect_code 4 "$RC" "another pending restart is refused: $OUT"
  assert_contains "$OUT" '"other work"' "the refusal names the other reason"
  assert_equals "" "$(t3_fake_calls t3_restart_request)$(t3_fake_calls t3_restart_cancel)" "nothing is requested or cancelled"

  fresh_case adopt '{"restartRegistry":true,"activeTurns":0,"restartRequest":{"reason":"install build e","requestedAt":"2026-11-13T00:00:00.000Z"}}'
  req drain --reason "install build e" --interval 1
  expect_code 0 "$RC" "a rerun adopts its own pending request: $OUT"
  assert_contains "$OUT" "adopted" "the adoption is reported"
  assert_equals "" "$(t3_fake_calls t3_restart_request)" "an adopted request is not sent again"
  pass "fm-t3-restart-request drain: another reason's restart is left alone; its own pending request is adopted"
}

test_stop_cancels_even_when_the_group_is_killed() {
  local pid i=0
  fresh_case stopped '{"restartRegistry":true,"activeTurns":1}'
  # Its own process group, stopped the way a retired watch is: TERM to the
  # group, then KILL to the group, with little grace in between.
  FM_HOME="$HOME_DIR" perl -e 'setpgrp(0, 0); exec @ARGV' "$REQ" drain --reason "install build f" --interval 1 \
    > "$TMP_ROOT/stopped.out" 2>&1 &
  pid=$!
  wait_for 'w.restartRequest' 10 || fail "the request should land"
  kill -TERM -"$pid" 2>/dev/null
  sleep 0.2
  kill -KILL -"$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  wait_for '!w.restartRequest' 15 || fail "a stopped drain must cancel its request even after its group is killed: $(cat "$TMP_ROOT/stopped.out")"
  assert_contains "$(cat "$TMP_ROOT/stopped.out")" "stopped before T3 drained" "the stop is reported"
  while [ "$i" -lt 50 ] && pgrep -f "fm-t3-restart-request.sh cancel --reason install build f" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
  pass "fm-t3-restart-request drain: a retired or timed-out drain cancels its request from outside its process group"
}

test_cancel_only_its_own_reason() {
  fresh_case cancel '{"restartRegistry":true,"activeTurns":0,"restartRequest":{"reason":"install build new","requestedAt":"2026-11-13T00:00:00.000Z"}}'
  req cancel --reason "install build old"
  expect_code 0 "$RC" "an older build's cleanup succeeds: $OUT"
  assert_equals "install build new" "$(world_get 'w.restartRequest.reason')" "a newer request survives an older one's cleanup"
  req cancel --reason "install build new"
  expect_code 0 "$RC" "its own cancel succeeds: $OUT"
  assert_equals "" "$(world_get 'w.restartRequest')" "its own request is cancelled"
  pass "fm-t3-restart-request cancel: cancels only a request with exactly its reason"
}

test_unreadable_t3_and_usage() {
  fresh_case unreadable '{"restartRegistry":true,"activeTurns":0}'
  t3_fake_set 'w.failTools = { t3_restart_status: { code: "unavailable", message: "down" } }'
  req drain --reason "install build g" --interval 1
  expect_code 2 "$RC" "an unreadable registry is an error: $OUT"
  assert_equals "" "$(t3_fake_calls t3_restart_request)" "nothing is requested when the registry cannot be read"
  fresh_case old-t3 '{"restartStatus":true}'
  req drain --reason "install build g" --interval 1
  expect_code 2 "$RC" "a T3 without the registry is an error: $OUT"
  req drain --interval 1
  expect_code 2 "$RC" "a drain without a reason is invalid use"
  req drain --reason "x" --within 0
  expect_code 2 "$RC" "a zero bound is invalid use"
  pass "fm-t3-restart-request: an unreadable or missing registry and invalid use exit 2 with nothing requested"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_drains_at_once_and_leaves_the_request_pending \
  test_waits_for_running_turns \
  test_timeout_cancels_and_releases \
  test_cancelled_in_t3_means_no_restart \
  test_foreign_request_is_left_alone_and_own_is_adopted \
  test_stop_cancels_even_when_the_group_is_killed \
  test_cancel_only_its_own_reason \
  test_unreadable_t3_and_usage
