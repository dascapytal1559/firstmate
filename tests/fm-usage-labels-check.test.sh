#!/usr/bin/env bash
# tests/fm-usage-labels-check.test.sh - bin/fm-usage-labels-check.sh, the
# nightly check that every T3 Code token of a day is labelled, and
# bin/fm-t3-mcp.mjs usage-reasons beneath it, driven through their CLIs
# against tests/t3-fake-server.mjs and a scratch home's backlog; plus
# bin/fm-nightly-checks.sh running it after the clear check. No live T3
# server is ever called.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-usage-labels-check-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
CHECK="$ROOT/bin/fm-usage-labels-check.sh"
HELPER="$ROOT/bin/fm-t3-mcp.mjs"
HOME_DIR="$TMP_ROOT/home"
BACKLOG="$HOME_DIR/data/backlog.md"
DAY=2026-11-15
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_T3CODE_TOKEN_FILE
export FM_HOME="$HOME_DIR"

# A row of the fork's UsageOriginReasonUsage.
row() {  # <reason> <provider> <tokens> <byDefault>
  printf '{"origin":"%s","reason":"%s","provider":"%s","tokens":%s,"byDefault":%s,"costUsd":0,"records":1}' \
    "$([ "$4" = true ] && echo computer || echo phone)" "$1" "$2" "$3" "$4"
}

# fresh_case <name> <world-json>: a fresh fake world, a credential for it, and
# an empty backlog.
fresh_case() {
  t3_fake_case "$TMP_ROOT/cases/$1" "$2"
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$BACKLOG"
  t3_fake_credential "$HOME_DIR/config/t3code-token"
}

gap_world() {
  printf '{"usageReasons":{"rows":[%s,%s,%s,%s,%s,%s]}}' \
    "$(row typed claude 1000 false)" "$(row unregisteredSession claude 300 true)" "$(row unregisteredSession claude 200 true)" \
    "$(row unnamedTurn codex 50 true)" "$(row noCause claude 0 true)" "$(row terminal claude 70 false)"
}

item_count() {
  grep -c -- '- \[.\] usage-labels-gap ' "$BACKLOG"
}

test_helper_reads_the_figure_and_refuses_what_is_not_one() {
  fresh_case helper "$(gap_world)"
  local out
  out=$(node "$HELPER" usage-reasons --days 1 --until-day "$DAY")
  expect_code 0 "$?" "a T3 with the watchdog answers"
  assert_equals "$DAY $DAY 1620 550 6" "$(printf '%s' "$out" | jq -r '"\(.sinceDay) \(.untilDay) \(.tokens) \(.byDefaultTokens) \(.rows | length)"')" "the figure comes back whole"
  assert_contains "$(cat "$T3_FAKE_LOG")" '"days":1,"untilDay":"2026-11-15"' "the window is sent as asked"
  node "$HELPER" usage-reasons --until-day 15-11-2026 >/dev/null 2>&1
  expect_code 2 "$?" "a malformed day is invalid use"
  t3_fake_set 'w.usageReasonsAnswer = { sinceDay: "2026-11-15", untilDay: "2026-11-15", timeZone: "UTC", tokens: 5, byDefaultTokens: 0, rows: [{ reason: "typed" }] }'
  out=$(node "$HELPER" usage-reasons --days 1 --until-day "$DAY" 2>/dev/null)
  expect_code 1 "$?" "a figure whose rows do not read is refused"
  assert_equals usage_reasons_malformed "$(printf '%s' "$out" | jq -r .error.code)" "and typed so"
  t3_fake_set 'w.usageReasonsAnswer = { sinceDay: "2026-11-14", untilDay: "2026-11-14", timeZone: "UTC", tokens: 0, byDefaultTokens: 0, rows: [] }'
  node "$HELPER" usage-reasons --days 1 --until-day "$DAY" >/dev/null 2>&1
  expect_code 1 "$?" "a figure for another day is refused, never read as an empty one"
  t3_fake_set 'delete w.usageReasons; delete w.usageReasonsAnswer'
  out=$(node "$HELPER" usage-reasons --days 1 2>/dev/null)
  expect_code 4 "$?" "a T3 without the watchdog is refused"
  assert_equals usage_reasons_unsupported "$(printf '%s' "$out" | jq -r .error.code)" "and typed so"
  pass "fm-t3-mcp usage-reasons: reads one day's figure and refuses anything that is not one"
}

test_everything_labelled_stays_silent() {
  fresh_case labelled "{\"usageReasons\":{\"rows\":[$(row typed claude 900 false),$(row upkeep codex 100 false),$(row noCause claude 0 true)]}}"
  local before out
  before=$(cat "$BACKLOG")
  out=$("$CHECK" --day "$DAY")
  expect_code 0 "$?" "a labelled day passes"
  assert_contains "$out" "$DAY (Australia/Melbourne): all 1000 tokens labelled" "the summary names the day"
  assert_equals "$before" "$(cat "$BACKLOG")" "nothing is raised"
  pass "fm-usage-labels-check: a fully labelled day raises nothing"
}

test_unlabelled_tokens_raise_one_item() {
  fresh_case gaps "$(gap_world)"
  "$CHECK" --day "$DAY" >/dev/null
  expect_code 0 "$?" "the check raises the item"
  local text
  text=$(cat "$BACKLOG")
  assert_equals 1 "$(item_count)" "one item"
  assert_contains "$text" "usage-labels-gap - Usage labels: 550 tokens unlabelled on $DAY" "the title totals the gap"
  assert_contains "$text" "550 of 1620 tokens on $DAY (Australia/Melbourne)" "the body names the day and the share"
  assert_contains "$text" "- unregisteredSession, claude: 500 tokens" "rows of one reason and provider are summed"
  assert_contains "$text" "- unnamedTurn, codex: 50 tokens" "each reason and provider is named"
  assert_not_contains "$text" "noCause" "a reason with no tokens is left out"
  assert_not_contains "$text" "typed, claude" "labelled usage is left out"
  assert_contains "$text" "(kind: scout)" "it is queued as a scout"
  pass "fm-usage-labels-check: unlabelled tokens raise one item naming reasons, providers and tokens"
}

test_later_nights_update_the_open_item() {
  fresh_case nights "$(gap_world)"
  "$CHECK" --day "$DAY" >/dev/null
  t3_fake_set 'w.usageReasons.rows = [{ origin: "computer", reason: "lateRecord", provider: "claude", tokens: 42, byDefault: true, costUsd: 0, records: 1 }]'
  "$CHECK" --day 2026-11-16 >/dev/null
  expect_code 0 "$?" "the second night updates"
  local text
  text=$(cat "$BACKLOG")
  assert_equals 1 "$(item_count)" "still one item"
  assert_contains "$text" "Usage labels: 42 tokens unlabelled on 2026-11-16" "retitled for the new night"
  assert_contains "$text" "- lateRecord, claude: 42 tokens" "the body is the new night's"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" hold usage-labels-gap --reason "later" >/dev/null
  "$CHECK" --day 2026-11-17 >/dev/null
  assert_equals 1 "$(item_count)" "a held item is updated too"
  assert_contains "$(cat "$BACKLOG")" "unlabelled on 2026-11-17" "and retitled"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" "done" usage-labels-gap >/dev/null
  "$CHECK" --day 2026-11-18 >/dev/null
  expect_code 0 "$?" "a done item is reopened"
  assert_equals 1 "$(item_count)" "not added a second time"
  assert_contains "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" show usage-labels-gap)" "state: queued" "it is queued again"
  pass "fm-usage-labels-check: later nights update the one item, reopening it when done"
}

test_an_unreadable_figure_is_raised_never_zero() {
  fresh_case nowatchdog '{}'
  "$CHECK" --day "$DAY" >/dev/null
  expect_code 0 "$?" "a T3 without the watchdog raises the item"
  assert_contains "$(cat "$BACKLOG")" "usage-labels-gap - Usage labels unreadable for $DAY" "titled unreadable"
  assert_contains "$(cat "$BACKLOG")" "unknown, not zero: this T3 cannot report usage reasons" "naming why"
  fresh_case failing "$(gap_world)"
  t3_fake_set 'w.failTools = { t3_usage_reasons: { code: "orchestration_error", message: "origins unreadable" } }'
  "$CHECK" --day "$DAY" >/dev/null
  assert_contains "$(cat "$BACKLOG")" "origins unreadable" "T3's own failure is named"
  fresh_case nocred "$(gap_world)"
  rm -f "$HOME_DIR/config/t3code-token"
  "$CHECK" --day "$DAY" >/dev/null
  assert_contains "$(cat "$BACKLOG")" "Usage labels unreadable for $DAY" "no credential is unreadable too"
  assert_equals 1 "$(item_count)" "one item"
  pass "fm-usage-labels-check: a figure that cannot be read raises the item instead of passing as zero"
}

test_no_write_and_usage() {
  fresh_case nowrite "$(gap_world)"
  local before out
  before=$(cat "$BACKLOG")
  out=$("$CHECK" --day "$DAY" --no-write)
  expect_code 0 "$?" "--no-write runs"
  assert_contains "$out" "Usage labels: 550 tokens unlabelled on $DAY" "it prints the item"
  assert_equals "$before" "$(cat "$BACKLOG")" "and writes nothing"
  "$CHECK" --day 2026-11 >/dev/null 2>&1
  expect_code 2 "$?" "a malformed day is invalid use"
  "$CHECK" --bogus >/dev/null 2>&1
  expect_code 2 "$?" "an unknown flag is invalid use"
  pass "fm-usage-labels-check: --no-write changes nothing, and invalid use exits 2"
}

test_nightly_checks_run_every_step() {
  fresh_case nightly "$(gap_world)"
  local out
  # No transcripts anywhere: the clear check fails, and the label check still runs.
  out=$(HOME="$TMP_ROOT/nohome" CLAUDE_CONFIG_DIR="$TMP_ROOT/nohome/.claude" "$ROOT/bin/fm-nightly-checks.sh" 2>&1)
  expect_code 1 "$?" "a failed step fails the run"
  assert_contains "$out" "fm-clear-watch.sh failed" "the failed step is named"
  assert_equals 1 "$(item_count)" "the label check ran after it"
  "$ROOT/bin/fm-nightly-checks.sh" extra >/dev/null 2>&1
  expect_code 2 "$?" "it takes no arguments"
  pass "fm-nightly-checks: every step runs even when an earlier one fails"
}

t3_fake_start "$TMP_ROOT/server"
fm_test_run \
  test_helper_reads_the_figure_and_refuses_what_is_not_one \
  test_everything_labelled_stays_silent \
  test_unlabelled_tokens_raise_one_item \
  test_later_nights_update_the_open_item \
  test_an_unreadable_figure_is_raised_never_zero \
  test_no_write_and_usage \
  test_nightly_checks_run_every_step
