#!/usr/bin/env bash
# Behavior tests for opt-in worker sizing: bin/fm-size.sh's pick, queue,
# finish, due, report and refit, and bin/fm-spawn.sh starting on the picked
# account or deferring a start no account has room for.
#
# A fake quota-axi answers with a quota-axi --json snapshot fixture from
# <login-folder>/quota.json and logs every read; FM_SIZE_NOW pins the clock.
# No test reads a real account.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-size)
TOOL="$ROOT/bin/fm-size.sh"
NOW=1794800000
unset QUOTA_AXI_SNAPSHOT QUOTA_AXI_CLAUDE_PROFILES T3CODE_HOME ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN FM_T3CODE_SPAWN_INSTANCE

# make_fakes <fakebin> <case-dir>: quota-axi from fixtures, and a claude whose
# sign-in check passes for a root holding .credentials.json.
make_fakes() {
  cat > "$1/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" >> '$2/reads'
dir=\${CLAUDE_CONFIG_DIR:-'$2/ordinary'}
[ -f "\$dir/quota.json" ] || exit 1
cat "\$dir/quota.json"
SH
  cat > "$1/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" > '$2/claude-worker'
SH
  chmod +x "$1/quota-axi" "$1/claude"
}

# new_case <name> -> sets CASE HOME_DIR FAKEBIN USER_HOME
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  USER_HOME="$CASE/user-home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN" "$USER_HOME"
  make_fakes "$FAKEBIN" "$CASE"
}

# sizing_config [accounts-json]: a small cost table. Plan small has a 5-hour
# window and a Fable rate; plan big has weekly rates only.
sizing_config() {
  local accounts=${1:-"[{\"id\":\"$CASE/a1\",\"plan\":\"small\"},{\"id\":\"$CASE/a2\",\"plan\":\"big\"}]"}
  jq -n --argjson accounts "$accounts" '{
    accounts: $accounts,
    reserve: {five_hour: 10, weekly: 2},
    queue_notice_minutes: 60,
    plans: {
      small: {five_hour: {fable: 2, other: 1}, weekly: {fable: 0.25, other: 0.1}, fable_weekly: {fable: 0.5}},
      big: {weekly: {fable: 0.13, other: 0.07}}
    },
    classes: [
      {kind: "ship", model: "opus", effort: "high", p75: 5, p90: 8, busy_p90: 90},
      {kind: "ship", model: "fable", effort: "xhigh", p75: 30, p90: 40, busy_p90: 250},
      {kind: "pipeline", model: "opus", effort: "high", p75: 12, p90: 22, busy_p90: 90}
    ]
  }' > "$HOME_DIR/config/worker-sizing.json"
}

# account <dir> <five|-> <five-reset-min> <week> <week-reset-hours> [fable|-]
account() {
  local dir=$1 five=$2 five_min=$3 week=$4 week_h=$5 fable=${6:--}
  mkdir -p "$dir"
  jq -n --arg five "$five" --argjson five_at "$((NOW + five_min * 60))" --arg week "$week" \
    --argjson week_at "$((NOW + week_h * 3600))" --arg fable "$fable" '
    def win($id; $pct; $at): if $pct == "-" then [] else [{id: $id, percentRemaining: ($pct | tonumber), resetsAt: ($at | todate | sub("Z$"; ".123456+00:00"))}] end;
    {schemaVersion: 5, providers: [{provider: "claude", state: {status: "fresh"},
      windows: (win("five_hour"; $five; $five_at) + win("seven_day"; $week; $week_at) + win("model:fable"; $fable; $week_at)),
      quotaSemantics: {status: "known", effectiveAvailability: [{scope: "all_models", status: "known",
        effectivePercentRemaining: ($week | tonumber), runway: {status: "through_reset"}, selection: {spendPriority: 1}}]}}]}' > "$dir/quota.json"
}

run_tool() {
  env -i HOME="$USER_HOME" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_SIZE_NOW="${SIZE_NOW:-$NOW}" "$TOOL" "$@"
}
pick() {  # <task> [args...]: stdout and stderr together
  local task=$1
  shift
  run_tool pick --task "$task" --kind ship --model claude-opus-5-5 --effort high --backend tmux "$@" 2>&1
}
records() { cat "$HOME_DIR/data/worker-sizing/records.jsonl"; }
last_record() { tail -1 "$HOME_DIR/data/worker-sizing/records.jsonl"; }

test_absent_config_reads_nothing() {
  local out rc
  new_case off
  account "$CASE/a1" 50 300 50 48
  out=$(pick off-1); rc=$?
  expect_code 0 "$rc" "no config means no sizing"
  assert_equals "" "$out" "no config prints nothing"
  assert_absent "$CASE/reads" "no config reads no quota"
  assert_absent "$HOME_DIR/data/worker-sizing" "no config writes no record"
  pass "without config/worker-sizing.json nothing is read, printed, or recorded"
}

test_fit_picks_the_soonest_weekly_reset() {
  local out rc
  new_case fit
  sizing_config
  account "$CASE/a1" 50 300 50 48
  account "$CASE/a2" - 0 50 24
  out=$(run_tool pick --task fit-1 --kind ship --model claude-opus-5-5 --effort high --backend tmux 2>"$CASE/err"); rc=$?
  expect_code 0 "$rc" "a job that fits starts: $(cat "$CASE/err")"
  assert_equals "$CASE/a2" "$out" "stdout is the account that fits with the soonest weekly reset"
  assert_contains "$(cat "$CASE/err")" "sizing: $CASE/a1 (small) | 5h 50-0 held-10 reserve, needs 8: ok | week 50-0 held-2 reserve, needs 0.8: ok | 0 running" "one line per account"
  assert_contains "$(cat "$CASE/err")" "sizing: start $CASE/a2 - fits; soonest weekly reset" "the decision line names the pick"
  [ "$(wc -l < "$CASE/err" | tr -d ' ')" = 3 ] || fail "two accounts print three lines: $(cat "$CASE/err")"
  [ "$(last_record | jq -r '[.event, .decision, .account, .class.match, .lines] | join(" ")')" = "start start $CASE/a2 exact 3" ] ||
    fail "the start record names the decision, the account and the class: $(last_record)"
  [ "$(last_record | jq '.accounts | length')" = 2 ] || fail "the record keeps every account's reading"
  assert_grep "$CASE/a1|--provider claude --json --no-credential-refresh --max-age 120s" "$CASE/reads" "each account is read once, read-only, through quota-axi's cache"
  pass "a job that fits starts on the fitting account with the soonest weekly reset, and the pick is recorded"
}

# watcher_runs_retry_check: run the retry check through the watcher's own trust
# gate for custom state checks, failing as the watcher would reject it.
watcher_runs_retry_check() {
  (
    . "$ROOT/bin/fm-pr-lib.sh"
    . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_snapshot_prepare "$HOME_DIR/state" worker-sizing-retry || { echo "rejected"; exit 1; }
    FM_SIZE_NOW="${SIZE_NOW:-$NOW}" bash "$FM_CUSTOM_CHECK_SNAPSHOT"
    rc=$?
    fm_custom_check_snapshot_cleanup
    exit "$rc"
  )
}

test_no_fit_queues_until_the_soonest_reset() {
  local out rc
  new_case queue
  sizing_config
  account "$CASE/a1" 15 90 50 48
  account "$CASE/a2" - 0 2 30
  out=$(pick queue-1); rc=$?
  expect_code 76 "$rc" "no room means the start is queued: $out"
  assert_contains "$out" "5h 15-0 held-10 reserve, needs 8: short" "the short limit is named"
  assert_contains "$out" "sizing: queued - no account fits now; soonest fit after a reset; $CASE/a1 at $(jq -nr "$((NOW + 5400)) | todate | sub(\":[0-9]{2}Z$\"; \"Z\")") (in 90 min)" "the soonest fit is named"
  assert_contains "$out" "the wait passes 60 minutes - tell the captain" "a wait over an hour says to tell the captain"
  assert_grep "at=$((NOW + 5400))" "$HOME_DIR/state/worker-sizing/queue/queue-1" "the retry time is queued"
  [ "$(last_record | jq -r '.event')" = queue ] || fail "the queue decision is recorded"
  out=$(watcher_runs_retry_check) || fail "the watcher accepts the retry check it is handed: $out"
  assert_equals "" "$out" "nothing is due before the reset"
  out=$(SIZE_NOW=$((NOW + 5400)) run_tool due)
  assert_contains "$out" "check: worker sizing: queued start of queue-1 is due (expected to fit on $CASE/a1) after 90 min; dispatch it again" "the due start wakes firstmate"
  assert_absent "$HOME_DIR/state/worker-sizing/queue/queue-1" "a due entry is retired"
  assert_absent "$HOME_DIR/state/worker-sizing-retry.check.sh" "with nothing queued the retry check is retired"
  assert_absent "$HOME_DIR/state/worker-sizing-retry.check-trust" "and so is its trust binding"
  pass "a job no account has room for is queued until the soonest reset where it fits, and the retry wakes firstmate"
}

# running_ship <id> <account-root> <model> <spent-output-tokens> [status]
running_ship() {
  local id=$1 root=$2 model=$3 tokens=$4 status=${5:-working} wt dir
  wt="$CASE/wt-$id"
  mkdir -p "$wt"
  printf 'kind=ship\nharness=claude\nmodel=%s\neffort=xhigh\nworktree=%s\naccount=%s\nspawn_gen=s%s.1.1\nmode=local-only\n' \
    "$model" "$wt" "$root" "$((NOW - 600))" > "$HOME_DIR/state/$id.meta"
  printf '%s [at=1]: going\n' "$status" > "$HOME_DIR/state/$id.status"
  dir="$root/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir/sess/subagents"
  jq -nc --arg m "$model" --argjson o "$tokens" --arg ts "$(jq -nr "$((NOW - 300)) | todate")" \
    '{type: "assistant", requestId: "r1", timestamp: $ts, message: {model: $m, usage: {input_tokens: 0, output_tokens: $o}}}' > "$dir/sess.jsonl"
  # A duplicate of the same request in a subagent file counts once.
  cp "$dir/sess.jsonl" "$dir/sess/subagents/agent.jsonl"
}

test_running_work_is_counted() {
  local out rc
  new_case running
  sizing_config "[{\"id\":\"$CASE/a1\",\"plan\":\"small\"},{\"id\":\"$CASE/a2\",\"plan\":\"big\"}]"
  account "$CASE/a1" 50 300 90 24
  account "$CASE/a2" - 0 90 48
  # A Fable ship on a1 that has spent $10 still holds 30 - 10 = 20 at 2 per unit.
  running_ship big-fable "$CASE/a1" claude-fable-5-2 250000
  out=$(pick run-1 2>&1); rc=$?
  expect_code 0 "$rc" "a second account has room: $out"
  assert_contains "$out" "5h 50-40 held-10 reserve, needs 8: short | week 90-5 held-2 reserve, needs 0.8: ok | 1 running" "the running ship's remainder is held"
  assert_contains "$out" "sizing: start $CASE/a2" "the start moves to the account with room"
  [ "$(last_record | jq -c '.running[0] | [.task, .spent, .source]')" = '["big-fable",10,"worker"]' ] ||
    fail "the record names the running work and what it spent: $(last_record | jq -c .running)"
  # A record from before any account was recorded is placed by its transcripts.
  grep -v '^account=' "$HOME_DIR/state/big-fable.meta" > "$CASE/m" && mv "$CASE/m" "$HOME_DIR/state/big-fable.meta"
  pick run-legacy >/dev/null 2>&1
  [ "$(last_record | jq -c '.running[] | select(.task == "big-fable") | [.account, .assumed]')" = "[\"$CASE/a1\",false]" ] ||
    fail "a task with no recorded account is placed where its transcripts are: $(last_record | jq -c .running)"
  printf 'done [at=2]: ready\n' >> "$HOME_DIR/state/big-fable.status"
  out=$(pick run-2 2>&1)
  assert_contains "$out" "| 0 running" "a finished worker holds nothing"
  assert_contains "$out" "sizing: start $CASE/a1" "with the worker done the sooner account fits again"
  # The start just picked holds its place until its task record exists.
  out=$(pick run-3 2>&1)
  assert_contains "$out" "$CASE/a1 (small) | 5h 50-5 held" "a start picked moments ago is counted"
  pass "running workers and moments-old starts are held at their remainder, so a job moves to an account with room"
}

test_fable_allowance_is_checked() {
  local out rc
  new_case fable
  sizing_config
  account "$CASE/a1" 100 300 90 24 10
  account "$CASE/a2" - 0 90 48 60
  out=$(run_tool pick --task fable-1 --kind ship --model claude-fable-5-2 --effort xhigh --backend tmux 2>&1); rc=$?
  expect_code 0 "$rc" "a Fable job starts where its allowance has room: $out"
  assert_contains "$out" "5h 100-0 held-10 reserve, needs 80: ok | week 90-0 held-2 reserve, needs 10: ok | fable 10-0 held-2 reserve, needs 20: short" "the Fable allowance is sized at the plan's Fable rate"
  assert_contains "$out" "fable 60-0 held-2 reserve, needs 5.2 (weekly rate): ok" "a plan without a Fable rate sizes it at its weekly rate"
  assert_contains "$out" "sizing: start $CASE/a2" "the Fable job moves off the account whose allowance is short"
  pass "a Fable job is sized against the Fable allowance as well as the 5-hour window and the week"
}

test_unmeasured_account_proceeds_with_a_warning() {
  local out rc
  new_case unmeasured
  sizing_config
  account "$CASE/a1" 12 90 50 48
  mkdir -p "$CASE/a2"
  out=$(pick um-1); rc=$?
  expect_code 0 "$rc" "an unmeasured account does not block: $out"
  assert_contains "$out" "sizing: $CASE/a2 (big) | not measured: quota-axi could not measure it" "the unmeasured account is named"
  assert_contains "$out" "could not be measured, starting there with a warning" "the decision says why"
  [ "$(last_record | jq -r '.warning')" = true ] || fail "the warning is recorded"
  pass "when no measured account fits, an account that could not be measured is used with a warning"
}

test_explicit_account_wins_and_is_recorded() {
  local out rc
  new_case explicit
  sizing_config
  account "$CASE/a1" 12 90 50 48
  account "$CASE/a2" - 0 50 24
  out=$(run_tool pick --task ex-1 --kind ship --model claude-opus-5-5 --effort high --backend tmux --account "$CASE/a1" 2>"$CASE/err"); rc=$?
  expect_code 0 "$rc" "an explicit account starts even when it does not fit"
  assert_equals "$CASE/a1" "$out" "the explicit account is the pick"
  assert_contains "$(cat "$CASE/err")" "sizing: explicit $CASE/a1 - chosen by firstmate; does not fit, starting anyway as chosen" "the line says it does not fit"
  [ "$(last_record | jq -r '.decision')" = explicit ] || fail "the explicit choice is recorded"
  pass "firstmate's explicit account wins, and the record keeps whether it fit"
}

test_a_malformed_config_is_an_error() {
  local out rc
  new_case malformed
  printf '{"accounts":[{"id":"x","plan":"nope"}],"plans":{},"classes":[]}\n' > "$HOME_DIR/config/worker-sizing.json"
  out=$(pick bad-1); rc=$?
  expect_code 2 "$rc" "a malformed table is an error"
  assert_contains "$out" "names an undefined plan" "the problem is named"
  printf 'not json\n' > "$HOME_DIR/config/worker-sizing.json"
  out=$(pick bad-2); rc=$?
  expect_code 2 "$rc" "invalid JSON is an error"
  assert_absent "$CASE/reads" "a malformed table reads no quota"
  pass "a malformed sizing file is reported, never sized around"
}

test_t3_accounts_are_instances_with_their_own_login_folders() {
  local out rc
  new_case t3
  sizing_config '[{"id":"claudeAgent","plan":"big"},{"id":"claudeThird","plan":"small"}]'
  jq --arg t3 "$CASE/t3" '. + {t3_home: $t3}' "$HOME_DIR/config/worker-sizing.json" > "$CASE/c" && mv "$CASE/c" "$HOME_DIR/config/worker-sizing.json"
  mkdir -p "$CASE/t3/userdata"
  jq -n '{providerInstances: {claudeAgent: {driver: "claudeAgent", config: {}}, claudeThird: {driver: "claudeAgent", config: {homePath: "~/third"}}}}' \
    > "$CASE/t3/userdata/settings.json"
  account "$CASE/ordinary" - 0 50 48
  account "$USER_HOME/third" 50 300 50 24
  out=$(run_tool pick --task t3-1 --kind scout --model default --effort default --backend t3code 2>"$CASE/err"); rc=$?
  expect_code 0 "$rc" "a T3 start is sized: $(cat "$CASE/err")"
  assert_equals claudeThird "$out" "the pick is a T3 instance id"
  assert_grep "unset|--provider" "$CASE/reads" "an instance with no homePath is read as the ordinary login"
  assert_grep "$USER_HOME/third|--provider" "$CASE/reads" "an instance is read under its own login folder"
  assert_contains "$(cat "$CASE/err")" "(scout opus high sized as ship opus high, same model and effort)" "a default model and effort use the table's defaults"
  pass "on T3 Code each account is a provider instance read under its own login folder"
}

test_t3_data_folder_is_the_signed_in_servers() {
  local out rc
  new_case t3-discover
  sizing_config '[{"id":"claudeThird","plan":"small"}]'
  printf '{"environment_id":"env-fork"}\n' > "$HOME_DIR/config/t3code-token"
  # ~/.t3 belongs to another T3 install; the fork keeps its own folder.
  mkdir -p "$USER_HOME/.t3/userdata" "$USER_HOME/.t3-fork/userdata"
  printf 'env-other\n' > "$USER_HOME/.t3/userdata/environment-id"
  printf 'env-fork\n' > "$USER_HOME/.t3-fork/userdata/environment-id"
  jq -n '{providerInstances: {claudeThird: {driver: "claudeAgent", config: {homePath: "~/wrong"}}}}' > "$USER_HOME/.t3/userdata/settings.json"
  jq -n '{providerInstances: {claudeThird: {driver: "claudeAgent", config: {homePath: "~/third"}}}}' > "$USER_HOME/.t3-fork/userdata/settings.json"
  account "$USER_HOME/third" 50 300 50 24
  out=$(run_tool pick --task disc-1 --kind ship --model claude-opus-5-5 --effort high --backend t3code 2>&1); rc=$?
  expect_code 0 "$rc" "the signed-in server's settings are found without t3_home: $out"
  assert_contains "$out" "sizing: start claudeThird" "the instance is measured"
  assert_grep "$USER_HOME/third|" "$CASE/reads" "the login folder comes from the folder whose environment id matches the credential"
  pass "without t3_home, T3's data folder is the one whose environment id matches the signed-in server"
}

test_finish_report_and_refit() {
  local out wt dir
  new_case finish
  sizing_config
  account "$CASE/a1" 50 300 50 48
  account "$CASE/a2" - 0 50 72
  pick fin-1 >/dev/null
  wt="$CASE/wt-fin-1"
  mkdir -p "$wt"
  printf 'kind=ship\nworktree=%s\n' "$wt" > "$HOME_DIR/state/fin-1.meta"
  printf 'window=five_hour\nmoved_to=%s\n' "$CASE/a2" > "$HOME_DIR/state/fin-1.usage-limit"
  dir="$CASE/a1/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  {
    jq -nc --arg ts "$(jq -nr "$((NOW + 60)) | todate")" '{type: "assistant", requestId: "a", timestamp: $ts,
      message: {model: "claude-opus-5-5", usage: {input_tokens: 1000000, output_tokens: 100000, cache_creation_input_tokens: 500000,
        cache_creation: {ephemeral_1h_input_tokens: 500000, ephemeral_5m_input_tokens: 0}, cache_read_input_tokens: 9000000}}}'
    jq -nc --arg ts "$(jq -nr "$((NOW + 1260)) | todate")" '{type: "assistant", requestId: "b", timestamp: $ts,
      message: {model: "claude-opus-5-5", usage: {input_tokens: 0, output_tokens: 50000}}}'
    printf 'not json\n'
    jq -nc --arg ts "$(jq -nr "$((NOW - 9999)) | todate")" '{type: "assistant", requestId: "old", timestamp: $ts,
      message: {model: "claude-opus-5-5", usage: {output_tokens: 9999999}}}'
  } > "$dir/s.jsonl"
  SIZE_NOW=$((NOW + 1800)) run_tool finish --task fin-1 || fail "finish exits 0"
  # 1M input * 4 + 0.5M 1-hour writes * 2 * 4 + 0.15M output * 20 = 4 + 4 + 3.
  [ "$(last_record | jq -c '[.event, .usage.weight, .usage.calls, .usage.busy_minutes, .cut_off, .cut_off_window, .duration_minutes, .moved_to]')" = "[\"finish\",11,2,10,true,\"five_hour\",30,\"$CASE/a2\"]" ] ||
    fail "finish records the actual weight, busy minutes, cut-off, move and duration: $(last_record)"
  [ "$(last_record | jq -r '.reading.measured')" = true ] || fail "finish keeps the account's reading"
  run_tool finish --task never-sized || fail "finish of a task never sized is a quiet no-op"
  [ "$(records | jq -r 'select(.task == "never-sized")' | wc -l | tr -d ' ')" = 0 ] || fail "a task never sized gets no record"
  out=$(run_tool report)
  assert_contains "$out" "starts 1 (0 explicit, 0 on an unmeasured account), queued 0, finished 1" "the report counts starts and finishes"
  assert_contains "$out" "cut off by a usage limit: 1 of 1 finished (ship opus high)" "the report counts cut-offs"
  assert_contains "$out" "ship opus high: 1, 8 / 5, 11 / 11, 1 above" "the report sets the estimate against the actual"
  assert_contains "$out" "sizing step: median" "the report shows the sizing step's own cost"
  out=$(run_tool refit)
  assert_contains "$out" "no class has enough finished records yet" "refit needs enough records"
  out=$(run_tool refit --min 1 --write)
  assert_contains "$out" "ship opus high: n 1, p75 11, p90 11, busy_p90 10" "refit names the new figures"
  [ "$(jq -c '.classes[] | select(.kind == "ship" and .model == "opus") | [.p75, .p90, .busy_p90]' "$HOME_DIR/config/worker-sizing.json")" = '[11,11,10]' ] ||
    fail "refit --write updates the table"
  ls "$HOME_DIR/config/worker-sizing.json.bak-"* >/dev/null 2>&1 || fail "refit --write keeps a backup"
  pass "cleanup records the actual, and report and refit read the records"
}

# --- through fm-spawn ---------------------------------------------------------

new_spawn_case() {
  new_case "$1"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$CASE/a1" "$CASE/a2"
  printf '{}\n' > "$CASE/a1/.credentials.json"
  printf '{}\n' > "$CASE/a2/.credentials.json"
  printf '%s\n' "$CASE/a1" "$CASE/a2" > "$HOME_DIR/config/claude-accounts"
}

spawn_ship() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_SIZE_NOW=$NOW \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode local-only --yolo off "$@"
}

test_spawn_starts_on_the_pick_or_defers() {
  local out rc
  new_spawn_case spawn
  sizing_config
  account "$CASE/a1" 50 300 50 48
  account "$CASE/a2" - 0 50 24
  out=$(spawn_ship sz-pick --model claude-opus-5-5 --effort high); rc=$?
  expect_code 0 "$rc" "a sized start launches: $out"
  assert_contains "$out" "sizing: start $CASE/a2" "the sizing lines reach the caller"
  assert_grep "account=$CASE/a2" "$HOME_DIR/state/sz-pick.meta" "the worker starts on the picked account"
  account "$CASE/a1" 12 90 50 48
  account "$CASE/a2" - 0 2 24
  out=$(spawn_ship sz-queue --model claude-opus-5-5 --effort high); rc=$?
  expect_code 76 "$rc" "no room defers the start: $out"
  assert_contains "$out" "deferred: task sz-queue was not launched and its backlog item stays queued" "the deferral is named"
  assert_absent "$HOME_DIR/state/sz-queue.meta" "a deferred start publishes no task record"
  [ ! -s "$CASE/launch.log" ] || fail "a deferred start launches nothing: $(cat "$CASE/launch.log")"
  out=$(spawn_ship sz-explicit --model claude-opus-5-5 --effort high --account "$CASE/a1"); rc=$?
  expect_code 0 "$rc" "an explicit account starts anyway: $out"
  assert_grep "account=$CASE/a1" "$HOME_DIR/state/sz-explicit.meta" "the explicit account is used"
  out=$(spawn_ship sz-t3flag --model claude-opus-5-5 --t3-instance claudeThird); rc=$?
  expect_code 1 "$rc" "--t3-instance refuses on a pane backend"
  assert_contains "$out" "--t3-instance applies only to backend=t3code" "the refusal names the backend"
  rm -f "$HOME_DIR/config/worker-sizing.json"
  out=$(spawn_ship sz-off --model claude-opus-5-5 --account "$CASE/a1"); rc=$?
  expect_code 0 "$rc" "without the file the spawn is unchanged: $out"
  assert_not_contains "$out" "sizing:" "without the file nothing is sized"
  pass "fm-spawn starts on the picked account, defers a start with no room, and keeps an explicit choice"
}

test_t3_spawn_instance_rides_the_backend_lookup() {
  local out
  new_case t3-lookup
  printf 'claude=claudeAgent\n' > "$HOME_DIR/config/t3code-instances"
  out=$(FM_BACKEND_CONFIG_DIR="$HOME_DIR/config" bash -c '. "$1"; fm_backend_t3code_instance_id claude' _ "$ROOT/bin/backends/t3code.sh")
  assert_equals claudeAgent "$out" "the standing mapping answers without a per-start instance"
  out=$(FM_T3CODE_SPAWN_INSTANCE=claude=claudeThird FM_BACKEND_CONFIG_DIR="$HOME_DIR/config" \
    bash -c '. "$1"; fm_backend_t3code_instance_id claude; echo /; fm_backend_t3code_instance_id codex; echo /' _ "$ROOT/bin/backends/t3code.sh")
  assert_equals $'claudeThird/\n/' "$out" "a per-start instance answers for its own harness only"
  assert_grep "claude=claudeAgent" "$HOME_DIR/config/t3code-instances" "the standing mapping is never rewritten"
  pass "a per-start T3 instance overrides the standing mapping for that harness without rewriting it"
}

test_absent_config_reads_nothing
test_fit_picks_the_soonest_weekly_reset
test_no_fit_queues_until_the_soonest_reset
test_running_work_is_counted
test_fable_allowance_is_checked
test_unmeasured_account_proceeds_with_a_warning
test_explicit_account_wins_and_is_recorded
test_a_malformed_config_is_an_error
test_t3_accounts_are_instances_with_their_own_login_folders
test_t3_data_folder_is_the_signed_in_servers
test_finish_report_and_refit
test_spawn_starts_on_the_pick_or_defers
test_t3_spawn_instance_rides_the_backend_lookup

echo "# all fm-size tests passed"
