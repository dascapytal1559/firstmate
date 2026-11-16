#!/usr/bin/env bash
# Behavior tests for the opt-in Fable quota floor: bin/fm-fable-floor.sh's
# verdicts, and bin/fm-spawn.sh refusing, proceeding, and recording the
# override before anything is launched.
#
# A fake quota-axi answers with a quota-axi --json snapshot fixture from
# <login-folder>/quota.json (the ordinary login, CLAUDE_CONFIG_DIR unset,
# answers from <case>/ordinary), and logs the login folder and arguments of
# every read. No test reads a real account.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-fable-floor)
TOOL="$ROOT/bin/fm-fable-floor.sh"
FABLE=claude-fable-5-2
unset QUOTA_AXI_SNAPSHOT QUOTA_AXI_CLAUDE_PROFILES T3CODE_HOME ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

# make_fake_quota <fakebin> <case-dir>
make_fake_quota() {
  cat > "$1/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_SNAPSHOT-unset}" "\${QUOTA_AXI_CLAUDE_PROFILES-unset}" "\$*" >> '$2/reads'
dir=\${CLAUDE_CONFIG_DIR:-'$2/ordinary'}
[ -f "\$dir/quota.json" ] || exit 1
cat "\$dir/quota.json"
[ ! -f "\$dir/exit-1" ] || exit 1
SH
  chmod +x "$1/quota-axi"
}

# new_tool_case <name> -> sets CASE HOME_DIR FAKEBIN USER_HOME
new_tool_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/fakebin"
  USER_HOME="$CASE/user-home"
  mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$USER_HOME"
  make_fake_quota "$FAKEBIN" "$CASE"
}

# floors [lines...]: write config/fable-quota-floor (this home's values by default).
floors() {
  if [ "$#" -eq 0 ]; then set -- 'fable_weekly=2' 'weekly=2' 'five_hour=50'; fi
  printf '%s\n' "$@" > "$HOME_DIR/config/fable-quota-floor"
}

# account <dir> <five_hour|-> <seven_day|-> <fable|-> [fable-runway]
# A login folder whose read reports those percentages left; - omits the window.
account() {
  local dir=$1 five=$2 week=$3 fable=$4 fable_runway=${5:-through_reset}
  mkdir -p "$dir"
  jq -n --arg five "$five" --arg week "$week" --arg fable "$fable" --arg fable_runway "$fable_runway" '
    def win($id; $pct): if $pct == "-" then [] else [{id: $id, percentRemaining: ($pct | tonumber)}] end;
    def avail($scope; $pct; $runway):
      if $pct == "-" then [] else [{scope: $scope, status: "known", effectivePercentRemaining: ($pct | tonumber),
        runway: {status: $runway}, selection: {spendPriority: 1}}] end;
    {
      schemaVersion: 5,
      providers: [{
        provider: "claude",
        state: {status: "fresh", stale: false},
        windows: (win("five_hour"; $five) + win("seven_day"; $week) + win("model:fable"; $fable)),
        quotaSemantics: {
          status: "known",
          effectiveAvailability: (avail("all_models"; $week; "through_reset") + avail("model:fable"; $fable; $fable_runway))
        }
      }]
    }' > "$dir/quota.json"
}

# rate_limited <dir>: a read the vendor rate-limits; quota-axi exits 1 and
# prints a snapshot naming that state.
rate_limited() {
  mkdir -p "$1"
  jq -n '{schemaVersion: 5, providers: [{provider: "claude",
    state: {status: "rate_limited", error: "Claude quota endpoint rate limited"},
    quotaSemantics: {status: "unknown", effectiveAvailability: []}}]}' > "$1/quota.json"
  : > "$1/exit-1"
}

run_tool() {
  env -i HOME="$USER_HOME" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    QUOTA_AXI_SNAPSHOT="$CASE/shared-fixture.json" QUOTA_AXI_CLAUDE_PROFILES="$CASE/x:$CASE/y" \
    ${T3CODE_HOME_TEST:+T3CODE_HOME="$T3CODE_HOME_TEST"} \
    "$TOOL" check "$@" 2>&1
}

test_absent_file_and_other_models_read_nothing() {
  local out rc
  new_tool_case absent
  account "$CASE/acct" 80 1 1
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/acct"); rc=$?
  expect_code 0 "$rc" "no floor file means no check"
  assert_equals "" "$out" "no floor file prints nothing"
  floors
  out=$(run_tool --model claude-opus-5-5 --backend tmux --root "$CASE/acct"); rc=$?
  expect_code 0 "$rc" "a non-Fable model is not checked"
  assert_equals "" "$out" "a non-Fable model prints nothing"
  assert_absent "$CASE/reads" "neither case may read any quota"
  pass "an absent floor file and a non-Fable model read nothing and pass"
}

test_measured_values_at_or_below_a_floor_refuse() {
  local out rc
  new_tool_case refuse
  floors
  account "$CASE/fable-low" 80 40 2
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/fable-low" --account work); rc=$?
  expect_code 3 "$rc" "Fable weekly at its floor must refuse: $out"
  assert_contains "$out" "on Claude account work ($CASE/fable-low)" "the refusal names the account"
  assert_contains "$out" "Fable weekly 2% left (floor 2%)" "the refusal names the figure and floor"
  assert_contains "$out" "--account <entry>" "the refusal names pointing at another account"
  assert_contains "$out" "--fable-floor-override <reason>" "the refusal names the override"
  account "$CASE/week-low" 80 1 40
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/week-low"); rc=$?
  expect_code 3 "$rc" "the all-models weekly floor must refuse"
  assert_contains "$out" "weekly 1% left (floor 2%)" "the weekly figure is named"
  account "$CASE/five-low" 50 40 40
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/five-low"); rc=$?
  expect_code 3 "$rc" "a 5-hour window at its floor must refuse"
  assert_contains "$out" "5-hour window 50% left (floor 50%)" "the 5-hour figure is named"
  account "$CASE/dry" 80 40 30 exhausted_now
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/dry"); rc=$?
  expect_code 3 "$rc" "an exhausted_now Fable runway must refuse above the floor"
  assert_contains "$out" "Fable allowance exhausted now" "the exhausted runway is named"
  assert_grep "$CASE/fable-low|unset|unset|--provider claude --json --no-credential-refresh --max-age 60s" "$CASE/reads" \
    "the read runs under the account's own folder, read-only, with no fixture or profile list leaking in"
  pass "a measured window at or below its floor, or an exhausted runway, refuses"
}

test_values_above_every_floor_pass() {
  local out rc
  new_tool_case pass
  floors
  account "$CASE/fresh" 51 3 3
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/fresh"); rc=$?
  expect_code 0 "$rc" "an account above every floor passes: $out"
  assert_equals "" "$out" "a pass prints nothing"
  account "$CASE/no-five" - 30 30
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/no-five"); rc=$?
  expect_code 0 "$rc" "an account with no 5-hour window passes: $out"
  assert_equals "" "$out" "an account without a 5-hour window is not uncertain"
  pass "an account above every floor passes silently"
}

test_an_unmeasured_account_proceeds_with_its_reason() {
  local out rc
  new_tool_case unmeasured
  floors
  mkdir -p "$CASE/unread"
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/unread"); rc=$?
  expect_code 0 "$rc" "an unreadable account must not block"
  assert_contains "$out" "uncertain: quota-axi could not measure $CASE/unread" "the uncertainty is named"
  rate_limited "$CASE/limited"
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/limited"); rc=$?
  expect_code 0 "$rc" "a rate-limited read must not block"
  assert_contains "$out" "rate_limited: Claude quota endpoint rate limited" "the vendor's own reason is named"
  account "$CASE/no-fable" 80 40 -
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/no-fable"); rc=$?
  expect_code 0 "$rc" "a missing Fable window must not block"
  assert_contains "$out" "uncertain: " "a missing Fable window is uncertainty"
  assert_contains "$out" "no Fable weekly window reported" "the missing window is named"
  pass "an account quota-axi cannot measure proceeds with a one-line reason"
}

test_the_ordinary_login_is_read_with_the_root_unset() {
  local out rc
  new_tool_case ordinary
  floors
  account "$CASE/ordinary" 80 40 1
  out=$(run_tool --model "$FABLE" --backend tmux --root ""); rc=$?
  expect_code 3 "$rc" "the ordinary login is measured too"
  assert_contains "$out" "/.claude, the ordinary login)" "the ordinary login is named"
  out=$(run_tool --model "$FABLE" --backend tmux --root "$USER_HOME/.claude/"); rc=$?
  expect_code 3 "$rc" "the default folder by name is the ordinary login"
  [ "$(cut -d'|' -f1 "$CASE/reads" | sort -u)" = unset ] ||
    fail "the ordinary login must be read with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/reads")"
  pass "the ordinary login, empty or named, is read with CLAUDE_CONFIG_DIR unset"
}

# t3_settings <t3-home> <env-id>: T3 provider settings with three Claude instances.
t3_settings() {
  mkdir -p "$1/userdata"
  printf '%s\n' "$2" > "$1/userdata/environment-id"
  # claudeThird's homePath is " ~/third ", a tilde path with padding to trim.
  jq -n --arg second "$CASE/second" '{providerInstances: {
    claudeAgent: {driver: "claudeAgent", config: {customModels: []}},
    claudeSecond: {driver: "claudeAgent", config: {homePath: $second}},
    claudeThird: {driver: "claudeAgent", config: {homePath: " ~/third "}},
    codex: {driver: "codex", config: {}}
  }}' > "$1/userdata/settings.json"
}

test_t3_reads_the_mapped_instance_login_folder() {
  local out rc
  new_tool_case t3
  floors 'fable_weekly=2' "t3_home=$CASE/t3"
  t3_settings "$CASE/t3" env-1
  printf '{"environment_id":"env-1","access_token":"x"}\n' > "$HOME_DIR/config/t3code-token"
  account "$CASE/ordinary" 80 40 1
  account "$CASE/second" 80 40 30
  account "$USER_HOME/third" 80 40 2
  out=$(run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 3 "$rc" "with no mapping the HARNESSES default instance is checked: $out"
  assert_contains "$out" "T3 instance claudeAgent (~/.claude, the ordinary login)" "an empty homePath is the ordinary login"
  assert_contains "$out" "config/t3code-instances" "the T3 remedy names the instance mapping"
  printf 'codex=codex\nclaude=claudeSecond\n' > "$HOME_DIR/config/t3code-instances"
  out=$(run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 0 "$rc" "the mapped instance's own folder is measured: $out"
  printf 'claude=claudeThird\n' > "$HOME_DIR/config/t3code-instances"
  out=$(run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 3 "$rc" "a ~ homePath is expanded and trimmed: $out"
  assert_contains "$out" "T3 instance claudeThird ($USER_HOME/third)" "the instance and its folder are named"
  printf 'claude=claudeMissing\n' > "$HOME_DIR/config/t3code-instances"
  out=$(run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 0 "$rc" "an instance absent from T3 settings must not block"
  assert_contains "$out" "uncertain: T3 provider settings at $CASE/t3/userdata/settings.json have no instance 'claudeMissing'" "the missing instance is named"
  printf 'claude=codex\n' > "$HOME_DIR/config/t3code-instances"
  out=$(run_tool --model "$FABLE" --backend t3code)
  assert_contains "$out" "uncertain: T3 instance 'codex' runs driver 'codex'" "a non-Claude instance is uncertainty"
  pass "the T3 backend measures the mapped instance's own login folder from T3's settings"
}

test_t3_settings_of_another_server_are_not_read() {
  local out rc
  new_tool_case t3-env
  floors 'fable_weekly=2'
  t3_settings "$CASE/t3" env-other
  printf '{"environment_id":"env-1"}\n' > "$HOME_DIR/config/t3code-token"
  account "$CASE/ordinary" 80 40 1
  out=$(T3CODE_HOME_TEST="$CASE/t3" run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 0 "$rc" "another server's settings must not decide the verdict"
  assert_contains "$out" "belong to env-other T3 environment, not the signed-in server env-1" "the mismatch is named"
  assert_absent "$CASE/reads" "no account is read when the instance's folder is unproven"
  pass "T3 settings whose environment id differs from the signed-in server's are not used"
}

test_t3_finds_the_signed_in_servers_data_folder() {
  local out rc
  new_tool_case t3-discover
  floors 'fable_weekly=2'
  printf '{"environment_id":"env-fork"}\n' > "$HOME_DIR/config/t3code-token"
  t3_settings "$USER_HOME/.t3" env-other
  t3_settings "$USER_HOME/.t3-fork" env-fork
  printf 'claude=claudeSecond\n' > "$HOME_DIR/config/t3code-instances"
  account "$CASE/second" 80 40 1
  out=$(run_tool --model "$FABLE" --backend t3code); rc=$?
  expect_code 3 "$rc" "without t3_home the signed-in server's own folder is read: $out"
  assert_contains "$out" "T3 instance claudeSecond ($CASE/second)" "the instance's login folder comes from the matching folder"
  pass "without t3_home, the T3 data folder is the one whose environment id matches the signed-in server"
}

test_a_malformed_floor_file_is_an_error() {
  local out rc
  new_tool_case malformed
  account "$CASE/acct" 80 40 40
  floors 'fable_weekly=two'
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/acct"); rc=$?
  expect_code 2 "$rc" "a non-numeric floor is an error"
  assert_contains "$out" "fable_weekly must be a whole percent" "the bad value is named"
  floors 'fable=2'
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/acct"); rc=$?
  expect_code 2 "$rc" "an unknown key is an error"
  floors '# only a comment'
  out=$(run_tool --model "$FABLE" --backend tmux --root "$CASE/acct"); rc=$?
  expect_code 2 "$rc" "a file with no floor is an error"
  assert_absent "$CASE/reads" "a malformed file reads no quota"
  pass "a malformed floor file is reported, never checked around"
}

# --- through fm-spawn ---------------------------------------------------------

# new_spawn_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_spawn_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_fake_quota "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/launch.log"
}

spawn_ship() {  # <id> [fm-spawn args...]
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/acct" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode local-only --yolo off "$@"
}

test_spawn_refuses_before_launch() {
  local out rc id=floor-refuse
  new_spawn_case spawn-refuse
  floors
  account "$CASE/acct" 80 40 1
  out=$(spawn_ship "$id" --model "$FABLE"); rc=$?
  expect_code 1 "$rc" "a Fable spawn on a nearly-out account must refuse: $out"
  assert_contains "$out" "Fable weekly 1% left (floor 2%)" "the refusal reaches the caller"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
  pass "fm-spawn refuses a Fable worker on a nearly-out account before launching anything"
}

test_spawn_passes_and_leaves_the_record_unchanged() {
  local out rc id=floor-pass
  new_spawn_case spawn-pass
  floors
  account "$CASE/acct" 80 40 40
  out=$(spawn_ship "$id" --model "$FABLE"); rc=$?
  expect_code 0 "$rc" "a Fable spawn on a fresh account should start: $out"
  assert_no_grep "fable_floor_" "$HOME_DIR/state/$id.meta" "a passing check adds nothing to the task record"
  assert_grep "$CASE/acct|" "$CASE/reads" "the launch's own forwarded account is measured"
  rm -f "$HOME_DIR/config/fable-quota-floor" "$CASE/reads"
  out=$(spawn_ship "$id-off" --model "$FABLE"); rc=$?
  expect_code 0 "$rc" "without the floor file a Fable spawn starts: $out"
  assert_absent "$CASE/reads" "without the floor file nothing is read"
  pass "a passing or absent floor check starts the worker with an unchanged record"
}

test_spawn_proceeds_on_an_unmeasured_account() {
  local out rc id=floor-unmeasured
  new_spawn_case spawn-unmeasured
  floors
  mkdir -p "$CASE/acct"
  out=$(spawn_ship "$id" --model "$FABLE"); rc=$?
  expect_code 0 "$rc" "an unmeasured account must not block: $out"
  assert_contains "$out" "warning: Fable quota floor not checked, starting anyway: quota-axi could not measure $CASE/acct" "the warning is printed"
  assert_grep "fable_floor_uncertain=quota-axi could not measure $CASE/acct" "$HOME_DIR/state/$id.meta" "the warning is recorded"
  pass "an unmeasured account starts with a recorded one-line warning"
}

test_spawn_override_records_its_reason() {
  local out rc id=floor-override
  new_spawn_case spawn-override
  floors
  account "$CASE/acct" 80 40 0 exhausted_now
  out=$(spawn_ship "$id" --model "$FABLE" --fable-floor-override "captain said start on this account"); rc=$?
  expect_code 0 "$rc" "the override starts the worker anyway: $out"
  assert_grep "fable_floor_override=captain said start on this account" "$HOME_DIR/state/$id.meta" "the reason is recorded"
  assert_absent "$CASE/reads" "an overridden launch reads no quota"
  out=$(spawn_ship "$id-empty" --model "$FABLE" --fable-floor-override ""); rc=$?
  expect_code 1 "$rc" "the override needs a reason"
  assert_contains "$out" "--fable-floor-override requires a printable reason" "the missing reason is named"
  out=$(spawn_ship "$id-opus" --model claude-opus-5-5 --fable-floor-override "why"); rc=$?
  expect_code 1 "$rc" "the override applies only to a Fable launch"
  assert_contains "$out" "applies only to a claude launch with --model claude-fable-*" "the wrong model is named"
  assert_absent "$HOME_DIR/state/$id-opus.meta" "a refused override publishes no record"
  pass "the override starts a Fable worker anyway and records its reason"
}

test_absent_file_and_other_models_read_nothing
test_measured_values_at_or_below_a_floor_refuse
test_values_above_every_floor_pass
test_an_unmeasured_account_proceeds_with_its_reason
test_the_ordinary_login_is_read_with_the_root_unset
test_t3_reads_the_mapped_instance_login_folder
test_t3_settings_of_another_server_are_not_read
test_t3_finds_the_signed_in_servers_data_folder
test_a_malformed_floor_file_is_an_error
test_spawn_refuses_before_launch
test_spawn_passes_and_leaves_the_record_unchanged
test_spawn_proceeds_on_an_unmeasured_account
test_spawn_override_records_its_reason

echo "# all fm-fable-floor tests passed"
