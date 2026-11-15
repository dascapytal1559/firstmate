#!/usr/bin/env bash
# Behavior tests for the fork's nightly clear check (bin/fm-clear-watch.sh,
# FORK.md "A nightly check watches every clear").
#
# Every transcript is made up: a week of main FirstMate sessions with one clear
# of each cause, one supervision-host session that must be ignored, and each
# sign of harm planted once. The check runs through its public entry point
# against a scratch home, with the clock fixed by --now and TZ=UTC.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }

export TZ=UTC
TMP_ROOT=$(fm_test_tmproot fm-clear-watch)
trap fm_test_cleanup EXIT
WATCH="$ROOT/bin/fm-clear-watch.sh"
T="$TMP_ROOT/transcripts"
mkdir -p "$T"
MON=$(jq -n '"2026-11-16T00:00:00Z" | fromdate')
at() { printf '%s' $(( MON + $1 * 60 )); }  # minutes after Monday 00:00 UTC

# --- transcript writers -------------------------------------------------------
prompt() {  # <session> <minute> <text>
  jq -cn --argjson t "$(at "$2")" --arg c "$3" \
    '{type:"user",timestamp:($t|todate),message:{role:"user",content:$c}}' >> "$T/$1.jsonl"
}
call() {  # <session> <minute> <message-id> <context-tokens>
  jq -cn --argjson t "$(at "$2")" --arg id "$3" --argjson ctx "$4" \
    '{type:"assistant",timestamp:($t|todate),message:{id:$id,model:"claude-test",
      usage:{input_tokens:10,cache_read_input_tokens:($ctx-10),cache_creation_input_tokens:0},
      content:[{type:"text",text:"ok"}]}}' >> "$T/$1.jsonl"
}
run() {  # <session> <minute> <tool-id> <command> <output> [is_error]
  jq -cn --argjson t "$(at "$2")" --arg id "$3" --arg cmd "$4" \
    '{type:"assistant",timestamp:($t|todate),message:{id:("msg_"+$id),model:"claude-test",
      usage:{input_tokens:10,cache_read_input_tokens:1000,cache_creation_input_tokens:0},
      content:[{type:"tool_use",id:$id,name:"Bash",input:{command:$cmd}}]}}' >> "$T/$1.jsonl"
  jq -cn --argjson t "$(at "$2")" --arg id "$3" --arg out "$5" --argjson err "${6:-false}" \
    '{type:"user",timestamp:($t|todate),message:{role:"user",
      content:[{type:"tool_result",tool_use_id:$id,content:$out,is_error:$err}]}}' >> "$T/$1.jsonl"
}
hook() {  # <session> <minute> <text>
  jq -cn --argjson t "$(at "$2")" --arg c "$3" \
    '{type:"attachment",timestamp:($t|todate),attachment:{type:"hook_success",content:$c}}' >> "$T/$1.jsonl"
}
digest() {  # <session> <minute>
  hook "$1" "$2" "SESSION START - /home
--- LOCK
lock acquired: harness pid 4242"
}
quote() {  # <session> <minute> <quoted-message-id>
  prompt "$1" "$2" "[assistant-quote-1]

<assistant_citations>
[{\"id\":\"assistant-quote-1\",\"citation\":{\"messageId\":\"message:provider:claudeAgent:native-item:$3%3Atext%3A0\",\"text\":\"An earlier reply.\",\"comment\":\"do this\"}}]
</assistant_citations>"
}
# The cold reroute rings its wake as the operational-input owner's doorbell.
mkdir -p "$TMP_ROOT/home/state"
REROUTE=$(printf 'A supervision wake is waiting.' | FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-operational-input.sh" record watcher) \
  || fail "the operational-input owner could not write a doorbell"
ACK_REQUIRED() { printf 'queue presented\nWAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation 1.2.x\n' "$1"; }

# s0, Monday 00:00 (before the day): answers dec-a, dispatches task-x, is shown
# wake 41 and never acknowledges it; ends at 300k.
digest s0 0
prompt s0 1 "Start the morning sweep and tell me what changed overnight, please."
call s0 2 msg_s0a 50000
run s0 60 t01 "bin/fm-captain-hold.sh answer dec-a --decision-file /tmp/answer" "answered dec-a"
run s0 90 t02 "bin/fm-spawn.sh task-x /p --mode local-only --yolo on" "spawned task-x harness=claude kind=ship window=w worktree=/wt"
run s0 100 t03 "bin/fm-captain-hold.sh answer dec-b --decision-file /tmp/answer" "refused" true
run s0 110 t04 "bin/fm-wake-drain.sh" "$(ACK_REQUIRED 41)"
call s0 120 msg_s0z 300000

# s1, 06:00: a cold start from a notification, four hours idle. The lock comes
# 10 minutes late, task-x is dispatched again, dec-a is held again, dec-b (whose
# answer failed) is held again harmlessly, and wake 41 is never acknowledged.
prompt s1 360 "$REROUTE"
digest s1 370
run s1 380 t11 "bin/fm-spawn.sh task-x /p --mode local-only --yolo on" "spawned task-x harness=claude kind=ship window=w worktree=/wt"
run s1 390 t12 "bin/fm-captain-hold.sh hold dec-a --reason again" "held dec-a"
run s1 395 t13 "bin/fm-captain-hold.sh hold dec-b --reason again" "held dec-b"
run s1 400 t14 "bin/fm-wake-drain.sh --ack-through 41 --recovery-generation 1.2.x" "wake drain: nothing was acknowledged through 41"
call s1 540 msg_s1z 150000

# s2, 09:30: his /clear after half an hour. A bare "yes", then a recall phrase.
digest s2 570
prompt s2 571 "yes"
call s2 575 msg_s2a 80000
prompt s2 580 "Like we discussed earlier, ship the second option now."
call s2 720 msg_s2z 200000

# s3, 14:00: a cold start from his message, two hours idle over 200k. He quotes
# the new session's own reply (no sign), then s2's reply (a sign). Wake 50 is
# shown and acknowledged.
digest s3 840
prompt s3 841 "Please look at the morning briefing layout and move the decisions to the top."
call s3 842 msg_s3a 75000
quote s3 845 msg_s3a
quote s3 850 msg_s2a
run s3 900 t31 "bin/fm-wake-drain.sh" "$(ACK_REQUIRED 50)"
run s3 905 t32 "bin/fm-wake-drain.sh --ack-through 50 --recovery-generation 1.2.x" ""
call s3 960 msg_s3z 90000

# s4, 18:00: two hours idle but only 90k, so his /clear. Nothing wrong.
digest s4 1080
prompt s4 1081 "Draft the release notes for the life archive's new timeline view."
call s4 1200 msg_s4z 120000

# The supervision host's session: never a main session, never a clear.
prompt host 1210 "MAIN DIALOG MIRROR (read-only context: what the captain and MAIN said)"
call host 1211 msg_h1 5000

# s5, 22:00: a fresh start after a T3 restart that never takes the lock.
prompt s5 1320 "The T3 server restarted. Continue where you left off after running session start."
hook s5 1321 "SESSION START - /home
--- LOCK
error: another live firstmate session holds the lock; operate read-only until resolved"
call s5 1400 msg_s5z 80000

# s6, Tuesday 05:30: his clean /clear, inside the last hour of the first run.
digest s6 1770
prompt s6 1771 "Good morning. What is on the list for today, in order of priority?"
call s6 1780 msg_s6z 60000

home() {  # <name>: a fresh scratch home
  mkdir -p "$TMP_ROOT/$1"
  printf '%s' "$TMP_ROOT/$1"
}
watch() {  # <home> <minute> [args...]
  local h=$1 minute=$2
  shift 2
  FM_HOME="$h" "$WATCH" --now "$(at "$minute")" --transcripts "$T" "$@"
}
TUE=1800 WED=3240 NEXT_MON=10440

test_day_lists_every_clear_with_cause_and_saving() {
  local h out
  h=$(home day)
  out=$(watch "$h" "$TUE") || fail "the run failed: $out"
  local report="$h/data/clear-watch/2026-11-17.md"
  [ -f "$report" ] || fail "no listing written"
  grep -qF '| Mon 06:00 | cold start from a notification | 300k | 229k |' "$report" || fail "notification clear row missing: $(cat "$report")"
  grep -qF '| Mon 09:30 | your /clear | 150k | 79k |' "$report" || fail "manual clear row missing"
  grep -qF '| Mon 14:00 | cold start from your message | 200k | 129k |' "$report" || fail "cold message row missing"
  grep -qF '| Mon 18:00 | your /clear | 90k | 19k | none |' "$report" || fail "small idle session must read as his /clear with no sign"
  grep -qF '| Mon 22:00 | fresh start after a T3 restart | 120k | 49k |' "$report" || fail "restart row missing"
  [ "$(grep -c '^| [MT][a-z][a-z] ' "$report")" -eq 5 ] || fail "expected exactly five clears (host ignored, last hour deferred): $(cat "$report")"
  ! grep -q 'Tue 05:30' "$report" || fail "a clear in the last hour must wait for the next run"
  grep -qF '5 clears, about 505k tokens of context dropped.' "$report" || fail "day total wrong: $(cat "$report")"
  printf '%s\n' "$out" | grep -qF '| Mon 06:00 | cold start from a notification' || fail "listing not printed"
  pass "the day lists every clear with its cause and saving"
}

test_each_sign_of_harm_is_found() {
  local report="$TMP_ROOT/day/data/clear-watch/2026-11-17.md" row
  row=$(grep -F '| Mon 06:00 |' "$report")
  printf '%s' "$row" | grep -qF 'a decision you had answered was asked again (dec-a)' || fail "re-asked decision missed: $row"
  ! printf '%s' "$row" | grep -qF 'dec-b' || fail "a failed answer must not count as answered: $row"
  printf '%s' "$row" | grep -qF 'a task was dispatched twice (task-x)' || fail "double dispatch missed: $row"
  printf '%s' "$row" | grep -qF 'a notification was left unacknowledged across the clear' || fail "unacknowledged wake missed: $row"
  printf '%s' "$row" | grep -qF 'FirstMate was not back at the helm for 10 minutes' || fail "late lock missed: $row"
  row=$(grep -F '| Mon 09:30 |' "$report")
  printf '%s' "$row" | grep -qF 'your first message was short and quoted nothing' || fail "bare reply missed: $row"
  printf '%s' "$row" | grep -qF 'you used a recall phrase ("earlier", "we discussed")' || fail "recall phrase missed: $row"
  ! printf '%s' "$row" | grep -qF 'helm' || fail "the lock check applies only after an automatic clear: $row"
  row=$(grep -F '| Mon 14:00 |' "$report")
  printf '%s' "$row" | grep -qF 'you quoted the previous session' || fail "quote of the previous session missed: $row"
  ! printf '%s' "$row" | grep -qF 'unacknowledged' || fail "an acknowledged wake must not count: $row"
  row=$(grep -F '| Mon 22:00 |' "$report")
  printf '%s' "$row" | grep -qF 'FirstMate was not back at the helm within the hour' || fail "missing lock missed: $row"
  ! grep -qi 'ship the second option\|release notes' "$report" || fail "message text must never be written out"
  pass "each sign of harm is found, and nothing else"
}

test_briefing_gets_one_line_appended_once() {
  local h=$TMP_ROOT/day brief before
  brief="$h/data/morning/2026-11-17.md"
  [ -f "$brief" ] || fail "no briefing line written"
  [ "$(grep -c 'Clear check:\*\*' "$brief")" -eq 1 ] || fail "expected one daily line: $(cat "$brief")"
  grep -qF -- '- **Clear check:** 4 of 5 clears in the last day showed a sign of harm: after the cold start from a notification at Mon 06:00,' "$brief" || fail "daily line wrong: $(cat "$brief")"
  grep -qF '; and 1 more. Details: data/clear-watch/2026-11-17.md' "$brief" || fail "daily line must cap its list and point at the listing: $(cat "$brief")"
  ! grep -q 'Clears this week' "$brief" || fail "no weekly total on a Tuesday"
  before=$(cat "$brief")
  watch "$h" "$TUE" >/dev/null || fail "rerun failed"
  [ "$(cat "$brief")" = "$before" ] || fail "a rerun must add nothing: $(cat "$brief")"
  pass "the briefing gets one line, written once"
}

test_existing_briefing_is_kept() {
  local h brief
  h=$(home existing)
  brief="$h/data/morning/2026-11-17.md"
  mkdir -p "${brief%/*}"
  printf '# Overnight report, Tue 17 Nov 2026\n\n## Start here\n\nThe demo.' > "$brief"
  watch "$h" "$TUE" >/dev/null || fail "run failed"
  [ "$(sed -n 1p "$brief")" = '# Overnight report, Tue 17 Nov 2026' ] || fail "report heading lost: $(cat "$brief")"
  [ "$(sed -n 5p "$brief")" = 'The demo.' ] || fail "report body lost: $(cat "$brief")"
  [ "$(sed -n 7p "$brief")" = '## Clear check' ] || fail "section not appended after the report: $(cat "$brief")"
  pass "an existing briefing is kept and the line goes after it"
}

test_quiet_day_writes_no_briefing_line() {
  local h out
  h=$(home quiet)
  out=$(watch "$h" "$WED") || fail "run failed: $out"
  grep -qF '| Tue 05:30 | your /clear | 80k | 9k | none |' "$h/data/clear-watch/2026-11-18.md" || fail "deferred clear not judged the next day: $out"
  [ ! -e "$h/data/morning/2026-11-18.md" ] || fail "a day with no sign must leave the briefing alone"
  ! printf '%s' "$out" | grep -q 'Morning briefing' || fail "nothing should be offered for the briefing: $out"
  pass "a quiet day writes no briefing line"
}

test_monday_adds_the_weekly_total() {
  local h brief
  h=$(home weekly)
  watch "$h" "$NEXT_MON" >/dev/null || fail "run failed"
  brief="$h/data/morning/2026-11-23.md"
  grep -qxF -- '- **Clears this week:** 6 (3 by your /clear, 1 cold start from your message, 1 cold start from a notification, 1 fresh start after a T3 restart), dropping about 514k tokens of context; 4 showed a sign of harm.' "$brief" ||
    fail "weekly total wrong: $(cat "$brief" 2>/dev/null)"
  ! grep -q 'Clear check:' "$brief" || fail "no daily line when the day had no clear"
  grep -qF 'No clears.' "$h/data/clear-watch/2026-11-23.md" || fail "an empty day must still be listed"
  pass "a Monday adds the weekly total"
}

test_no_write_only_prints() {
  local h out
  h=$(home nowrite)
  out=$(watch "$h" "$TUE" --no-write) || fail "run failed"
  printf '%s' "$out" | grep -qF -- '- **Clear check:** 4 of 5' || fail "briefing line not printed: $out"
  [ ! -e "$h/data" ] || fail "--no-write wrote files"
  pass "--no-write only prints"
}

test_usage_and_missing_transcripts() {
  local rc
  "$WATCH" --help | grep -q '^Usage: fm-clear-watch.sh' || fail "--help must print usage"
  rc=0; "$WATCH" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown flag must exit 2, got $rc"
  rc=0; FM_HOME="$TMP_ROOT/none" "$WATCH" --transcripts "$TMP_ROOT/absent" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "a missing transcript directory must exit 1, got $rc"
  pass "usage and a missing transcript directory"
}

# The default folders: this home's transcripts under the default account and
# under each login folder, read together, a copied session counted once.
make_account_home() {  # <name>: a scratch HOME and a FM_HOME path; sets ACCOUNT_HOME and ACCOUNT_FM
  ACCOUNT_HOME="$TMP_ROOT/$1-user"
  ACCOUNT_FM="$TMP_ROOT/$1-home"
  mkdir -p "$ACCOUNT_FM"
  ACCOUNT_ENC=$(printf '%s' "$ACCOUNT_FM" | sed 's/[^A-Za-z0-9]/-/g')
}
account_dir() {  # <relative config folder>: that account's folder for this home
  mkdir -p "$ACCOUNT_HOME/$1/projects/$ACCOUNT_ENC"
  printf '%s' "$ACCOUNT_HOME/$1/projects/$ACCOUNT_ENC"
}
watch_default() {  # <minute> [args...]: no --transcripts, so the default folders
  local minute=$1
  shift
  HOME="$ACCOUNT_HOME" FM_HOME="$ACCOUNT_FM" env -u CLAUDE_CONFIG_DIR "$WATCH" --now "$(at "$minute")" "$@"
}

test_every_account_folder_is_read_and_a_copied_session_counts_once() {
  local saved=$T out a b
  make_account_home accounts
  a=$(account_dir .claude)
  b=$(account_dir .claude-profiles/second)
  T=$a
  digest sa 0
  prompt sa 1 "Plan the week for the made-up garden project, please."
  call sa 100 msg_sa 90000
  T=$b
  digest sb 300
  prompt sb 301 "Good afternoon. Where did the seedlings get to today?"
  call sb 320 msg_sb 60000
  cp "$b/sb.jsonl" "$a/sb.jsonl"
  T=$saved
  out=$(watch_default 480 --no-write) || fail "run failed: $out"
  printf '%s' "$out" | grep -qF '1 clears, about' || fail "one clear across two accounts, the copy counted once: $out"
  printf '%s' "$out" | grep -qF 'your /clear' || fail "the clear must be read across the two folders: $out"
  ! printf '%s' "$out" | grep -qF 'No current main session' || fail "main sessions exist, so none may be reported missing: $out"
  pass "every account folder is read, and a session copied into two folders counts once"
}

test_no_current_main_session_is_reported_not_zero_clears() {
  local saved=$T out h a
  make_account_home missing
  a=$(account_dir .claude)
  account_dir .claude-profiles/second >/dev/null
  T=$a
  prompt host 10 "MAIN DIALOG MIRROR (read-only context: what the captain and MAIN said)"
  call host 11 msg_hm 5000
  T=$saved
  h=$ACCOUNT_FM
  out=$(watch_default 480) || fail "run failed: $out"
  printf '%s' "$out" | grep -qF 'No current main session found' || fail "a missing main session must be said plainly: $out"
  ! printf '%s' "$out" | grep -qF 'No clears.' || fail "a missing main session must not read as zero clears: $out"
  printf '%s' "$out" | grep -qF -- '- **Clear check:** no current main session found in 2 transcript folder(s)' ||
    fail "the briefing must carry the finding: $out"
  grep -qF 'no current main session' "$h/data/morning/2026-11-16.md" || fail "the briefing line was not written"
  pass "no current main session in any folder is reported, not shown as zero clears"
}

fm_test_run \
  test_day_lists_every_clear_with_cause_and_saving \
  test_each_sign_of_harm_is_found \
  test_briefing_gets_one_line_appended_once \
  test_existing_briefing_is_kept \
  test_quiet_day_writes_no_briefing_line \
  test_monday_adds_the_weekly_total \
  test_no_write_only_prints \
  test_every_account_folder_is_read_and_a_copied_session_counts_once \
  test_no_current_main_session_is_reported_not_zero_clears \
  test_usage_and_missing_transcripts
