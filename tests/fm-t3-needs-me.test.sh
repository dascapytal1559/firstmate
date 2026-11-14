#!/usr/bin/env bash
# tests/fm-t3-needs-me.test.sh - T3's Bridge feeds follow their sources
# (bin/fm-t3-needs-me.sh sync), and reply-task reads which task a captain
# reply names, against the fake T3 server.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

NEEDS_ME="$ROOT/bin/fm-t3-needs-me.sh"
TMP_ROOT=$(fm_test_tmproot fm-t3-needs-me)
t3_fake_start "$TMP_ROOT/server"
cleanup() {
  t3_fake_stop
  fm_test_cleanup
}
trap cleanup EXIT

FM_THREAD='mcp:00000000-0000-4000-8000-00000000f1f1'

# make_home <name> [world-js] -> HOME_DIR: a main home with the T3 credential,
# a backlog with rows w1 and w2, and a fake T3 whose project is rooted at the
# home and whose FirstMate thread is pinned as coordinator.
make_home() {
  local fakebin real
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
  real=$(cd "$HOME_DIR" && pwd -P)
  fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  fakebin=$(fm_fakebin "$HOME_DIR")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  t3_fake_case "$HOME_DIR/world"
  FM_T3_ROOT=$real FM_T3_FM=$FM_THREAD t3_fake_set '
    w.coordinatorRestartNote = true;
    w.projects = [{ id: "proj-fm", title: "firstmate", workspaceRoot: process.env.FM_T3_ROOT, defaultModelSelection: null, deletedAt: null }];
    w.threads = { [process.env.FM_T3_FM]: { threadId: process.env.FM_T3_FM, projectId: "proj-fm", title: "FirstMate",
      status: "completed", activeRunId: null, archived: false, worktreePath: null, coordinator: true, items: [], runs: [] } };'
  [ -z "${2:-}" ] || t3_fake_set "$2"
  t3_fake_credential "$HOME_DIR/config/t3code-token"
  (cd "$HOME_DIR" && tasks-axi add w1 "Pick the print layout" --repo sample && tasks-axi add w2 "Buy the camera" --repo sample) >/dev/null \
    || fail "could not seed the backlog rows"
}

home_env() {
  env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

needs_me() {  # <args...>
  home_env "$NEEDS_ME" "$@"
}

sync_now() {
  needs_me sync
}

# --- reply marker ----------------------------------------------------------

test_reply_marker() {
  local f="$TMP_ROOT/reply.txt" out rc
  printf '**Decision · Buy the camera**\nneeds-me-task: w2\n\n> Buy the camera?\n>\n> A or B?\n\nYes, buy it.\n' > "$f"
  assert_equals "w2" "$(home_env "$NEEDS_ME" reply-task "$f")" "the marker names the task"
  assert_equals "w2" "$(printf '> needs-me-task: w2\nyes\n' | "$NEEDS_ME" reply-task)" "a quoted marker reads from stdin"
  printf 'Just chatting, no marker.\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 1 "$rc" "no marker is not a reply: $out"
  printf 'needs-me-task: w1\nneeds-me-task: w2\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 2 "$rc" "two tasks are ambiguous: $out"
  printf 'needs-me-task: ../w1\n' > "$f"
  out=$("$NEEDS_ME" reply-task "$f" 2>&1)
  rc=$?
  expect_code 2 "$rc" "a malformed id is refused: $out"
  pass "fm-t3-needs-me.sh reply-task: reads exactly one needs-me-task line"
}

# A reply typed on a kept card names the card's thread; its task is the one
# record that keeps that thread.
test_reply_on_a_kept_card() {
  local state="$TMP_ROOT/kept-reply/state" f="$TMP_ROOT/kept-reply/reply.txt" out rc
  local kept='mcp:7a1b2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d' other='mcp:00000000-0000-4000-8000-0000000000b2'
  mkdir -p "$state"
  fm_write_meta "$state/s1.meta" kind=scout backend=t3code "t3_thread_id=$kept"
  fm_write_meta "$state/w9.meta" kind=ship backend=t3code "t3_thread_id=$other"
  reply() {  # <message> -> OUT, RC
    printf '%s' "$1" > "$f"
    OUT=$(FM_STATE_OVERRIDE="$state" "$NEEDS_ME" reply-task "$f" 2>&1)
    RC=$?
  }
  reply "**Reply · Camera options**
kept-thread: $kept

Looks good, but check the lens too.
"
  expect_code 0 "$RC" "a kept-card reply names its task: $OUT"
  assert_equals s1 "$OUT" "the task is the one keeping that thread"
  reply "**Reply · Camera options**
kept-thread: mcp:00000000-0000-4000-8000-00000000dead

Hello.
"
  expect_code 1 "$RC" "a thread no task records names no task: $OUT"
  assert_contains "$OUT" "no task records" "the refusal says the thread is unknown"
  reply "kept-thread: $kept
needs-me-task: w2
"
  expect_code 2 "$RC" "a reply naming both a task and a thread is ambiguous: $OUT"
  reply "kept-thread: mcp:../s1
"
  expect_code 2 "$RC" "a malformed thread id is refused: $OUT"
  fm_write_meta "$state/s2.meta" kind=scout backend=t3code "t3_thread_id=$kept"
  reply "kept-thread: $kept
"
  expect_code 2 "$RC" "a thread two records name is ambiguous: $OUT"
  pass "fm-t3-needs-me.sh reply-task: a kept-card reply names the task that keeps its thread, and nothing ambiguous"
}

# --- objectives ------------------------------------------------------------

# write_objectives <file>: a made-up objectives file in the shape the home
# keeps: a heading, a preamble, the review line, then one bullet each.
write_objectives() {
  cat > "$1" <<'MD'
# High level objectives

The broad direction right now. Nothing gets ticked off.

Last reviewed: 2026-10-01

- **Garden shed:** build the shed before winter. The plans are drawn. Plans so far: /home/someone/notes/shed/plans.md
- **Sourdough (or any bread):** bake one loaf a week, in the style of the corner bakery; keep the starter alive. Added from the 3 October journal, which holds the full details: /home/someone/journal/2026-10-03.md
- **Running:** "a 10k by spring"; two runs a week. Added from the 4 October journal: ~/journal/2026-10-04.md
- **Reading:** a book a month. Added from the 4 October journal (same file).
- A bullet with no name, see https://example.com/list
MD
}

# objectives_payload <objectives-md>: the Bridge payload for a home whose
# objectives file is <objectives-md> (none when it does not exist), read as
# the sync reads it.
objectives_payload() {
  local home="$TMP_ROOT/payload-home"
  mkdir -p "$home/data"
  rm -f "$home/data/high-level-objectives.md"
  [ ! -f "$1" ] || cp "$1" "$home/data/high-level-objectives.md"
  FM_HOME="$home" "$ROOT/bin/fm-objectives.sh" > "$home/source.json" || return 1
  node "$ROOT/bin/fm-t3-mcp.mjs" objectives-payload --file "$home/source.json"
}

test_objectives_payload_shape() {
  local f="$TMP_ROOT/objectives.md" out want
  write_objectives "$f"
  out=$(objectives_payload "$f") || fail "the payload should build"
  want=$(printf '%s\n' \
    '- **Garden shed** — build the shed before winter. The plans are drawn.' \
    '- **Sourdough (or any bread)** — bake one loaf a week, in the style of the corner bakery; keep the starter alive.' \
    '- **Running** — "a 10k by spring"; two runs a week.' \
    '- **Reading** — a book a month. Added from the 4 October journal (same file).' \
    '- A bullet with no name, see https://example.com/list')
  assert_equals "$want" "$(printf '%s' "$out" | jq -r '.markdown')" "only the bullets, names bold, local path pointers dropped"
  assert_equals "false" "$(printf '%s' "$out" | jq 'has("lastReviewed")')" "the review line does not travel"
  assert_equals "5 0" "$(printf '%s' "$out" | jq -r '"\(.objectives) \(.shortened)"')" "five objectives, none shortened"
  printf '# High level objectives\n\nLast reviewed: 2026-10-01\n\n- **Only:** one. Notes: /tmp/x\n' > "$f"
  out=$(objectives_payload "$f")
  assert_equals "- **Only** — one." "$(printf '%s' "$out" | jq -r '.markdown')" "a single objective keeps its text"
  printf '# High level objectives\n\nNothing yet.\n' > "$f"
  assert_equals "null" "$(objectives_payload "$f" | jq -r '.markdown')" "a file with no bullets clears them"
  assert_equals "null" "$(objectives_payload "$TMP_ROOT/none.md" | jq -r '.markdown')" "an absent file clears them"
  pass "fm-t3-mcp.mjs objectives-payload: the bullets, bold names, no local paths, and no review day"
}

test_objectives_payload_fits_the_limit() {
  local f="$TMP_ROOT/objectives-long.md" out md n long
  long=$(head -c 3000 /dev/zero | tr '\0' 'x')
  { printf '# High level objectives\n\nLast reviewed: 2026-10-01\n\n- **Short:** stays whole.\n'
    for n in 1 2 3 4; do printf -- '- **Long %s:** %s\n' "$n" "$long"; done; } > "$f"
  out=$(objectives_payload "$f") || fail "the payload should build"
  md=$(printf '%s' "$out" | jq -r '.markdown')
  [ "$(printf '%s' "$out" | jq '.markdown | length')" -le 8192 ] || fail "the list fits T3's 8192 characters"
  assert_equals "5" "$(printf '%s\n' "$md" | grep -c '^- \*\*')" "no objective is dropped"
  assert_equals "- **Short** — stays whole." "$(printf '%s\n' "$md" | head -n 1)" "a short objective is not cut"
  assert_equals "4" "$(printf '%s\n' "$md" | grep -c '…$')" "each long objective's text is cut, with an ellipsis"
  assert_equals "4" "$(printf '%s' "$out" | jq -r '.shortened')" "and the count says so"
  pass "fm-t3-mcp.mjs objectives-payload: past the limit every objective stays, its text cut"
}

objectives_calls() {
  t3_fake_calls t3_objectives_set | grep -c . || true
}

test_objectives_push_only_when_changed() {
  make_home objectives 'w.objectivesTool = true'
  local out rc
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "the first pass pushes them: $out"
  assert_equals "1" "$(objectives_calls)" "one push"
  assert_equals '["markdown"]' "$(t3_fake_calls t3_objectives_set | jq -sc '.[0] | keys')" "carrying only the list, no review day"
  assert_equals "$(objectives_payload "$HOME_DIR/data/high-level-objectives.md" | jq -r '.markdown')" \
    "$(jq -r '.objectives.markdown' "$T3_FAKE_WORLD")" "and the built list"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an unchanged pass should succeed"
  assert_equals "0" "$(objectives_calls)" "unchanged objectives are not pushed again"
  printf -- '- **Swimming:** once a week.\n' >> "$HOME_DIR/data/high-level-objectives.md"
  t3_fake_set 'w.failTools = { t3_objectives_set: { code: "unavailable", message: "settings are busy" } }'
  out=$(sync_now)
  rc=$?
  expect_code 1 "$rc" "a failed push is reported: $out"
  assert_contains "$out" "objectives" "the line names the objectives"
  t3_fake_set 'delete w.failTools'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(objectives_calls)" "the next pass retries"
  assert_contains "$(jq -r '.objectives.markdown' "$T3_FAKE_WORLD")" "- **Swimming** — once a week." "with the new objective"
  t3_fake_set 'w.objectivesAnswer = { markdown: "something else" }'
  printf -- '- **Cycling:** to work.\n' >> "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 1 "$?" "an answer that differs from what was sent is not proven: $out"
  t3_fake_set 'delete w.objectivesAnswer'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(objectives_calls)" "so it is pushed again"
  printf -- '- **Long:** %s\n' "$(head -c 9000 /dev/zero | tr '\0' 'x')" >> "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 0 "$?" "a list past the limit is still pushed: $out"
  assert_contains "$out" "1 of 8 objectives were shortened" "and the pass says it was cut"
  pass "fm-t3-needs-me.sh sync: objectives are pushed when they change, retried when a push fails"
}

test_objectives_clear_once_and_back_off() {
  make_home objectives-clear 'w.objectivesTool = true; w.objectives = { markdown: "- **Old** — gone." }'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals '{"markdown":null}' "$(t3_fake_calls t3_objectives_set)" "with no objectives file they are cleared"
  assert_equals "null" "$(jq -c '.objectives' "$T3_FAKE_WORLD")" "and T3 holds none"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals "0" "$(objectives_calls)" "only once"
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  t3_fake_set 'w.failTools = { t3_objectives_set: { code: "unavailable", message: "settings are busy" } }'
  local now n out
  now=$(date +%s)
  : > "$T3_FAKE_LOG"
  for n in 1 2 3 4; do FM_NEEDS_ME_NOW=$now needs_me sync >/dev/null; done
  assert_equals "3" "$(objectives_calls)" "three failures in a row, then it waits"
  FM_NEEDS_ME_NOW=$((now + 900)) needs_me sync >/dev/null
  assert_equals "4" "$(objectives_calls)" "and tries again 15 minutes later"
  make_home objectives-old-t3
  write_objectives "$HOME_DIR/data/high-level-objectives.md"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without objectives is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  for n in 1 2 3 4; do sync_now >/dev/null || fail "a T3 without objectives stays quiet once held back"; done
  pass "fm-t3-needs-me.sh sync: a missing file clears them once; failures back off; an older T3 is quiet"
}

# --- model routing -----------------------------------------------------------

# write_routing <file>: a made-up config/crew-dispatch.json.
write_routing() {
  cat > "$1" <<'EOF'
{
  "rules": [
    { "when": "Hard design work.", "approval": "captain",
      "use": [{ "harness": "claude", "model": "claude-fable-9", "effort": "xhigh" }, { "harness": "codex", "model": "gpt-9-sol", "effort": "high" }],
      "why": "Strongest reasoning." },
    { "when": "Small fixes.", "use": { "harness": "claude", "model": "claude-sonnet-9", "effort": "high" } },
    { "when": "Long chats.", "use": { "harness": "claude", "model": "claude-opus-9" } },
    { "when": "Browsing.", "use": { "harness": "codex", "model": "gpt-9-sol", "effort": "high" } },
    { "when": "Odd jobs.", "use": { "harness": "local", "model": "big|model" } },
    { "when": "Quick drafts.", "use": { "harness": "claude", "model": "claude-fable-9", "effort": "high" } }
  ],
  "default": { "harness": "claude", "model": "claude-opus-9" }
}
EOF
}

routing_payload() {
  node "$ROOT/bin/fm-t3-mcp.mjs" routing-payload --file "$1"
}

routing_calls() {
  t3_fake_calls t3_routing_set | grep -c . || true
}

test_routing_payload_shape() {
  local f="$TMP_ROOT/routing.json" out want long
  write_routing "$f"
  out=$(routing_payload "$f") || fail "the list should build"
  want=$(cat <<'EOF'
#### Opus

- `claude · claude-opus-9`\
  Default · Long chats.

#### Fable

- `claude · claude-fable-9 · xhigh`\
  Hard design work. (captain approves)
- `claude · claude-fable-9 · high`\
  Quick drafts.

#### Sol

- `codex · gpt-9-sol · high`\
  Hard design work. (captain approves) · Browsing.

#### Sonnet

- `claude · claude-sonnet-9 · high`\
  Small fixes.

#### big|model

- `local · big|model`\
  Odd jobs.
EOF
)
  assert_equals "$want" "$(printf '%s' "$out" | jq -r '.markdown')" "grouped by family, the default first, one entry per model with its Whens joined"
  assert_equals "8 0" "$(printf '%s' "$out" | jq -r '"\(.rows) \(.shortened)"')" "eight routes, none shortened"
  assert_not_contains "$(printf '%s' "$out" | jq -r '.markdown')" "Strongest reasoning" "the Why is not shown"
  assert_not_contains "$(printf '%s' "$out" | jq -r '.markdown')" "Anthropic" "no provider heading"
  jq -n '{rules: [{when: "- not a list", use: {harness: "a`b"}}, {when: "2. not a list", use: {harness: "c"}}]}' > "$f"
  want=$(cat <<'EOF'
#### Other

- ``a`b``\
  \- not a list
- `c`\
  2\. not a list
EOF
)
  assert_equals "$want" "$(routing_payload "$f" | jq -r '.markdown')" "no model goes under Other; a backtick in the model and a block marker in the When stay text"
  printf '{"rules": []}\n' > "$f"
  assert_equals "null" "$(routing_payload "$f" | jq -r '.markdown')" "no rules and no default give no list"
  long=$(head -c 3000 /dev/zero | tr '\0' 'x')
  jq -n --arg when "$long" '{rules: [range(6) | {when: "Rule \(.) \($when)", approval: (if . == 0 then "captain" else null end), use: {harness: "claude", model: "m\(.)"}, why: $when}], default: {harness: "codex"}}' > "$f"
  out=$(routing_payload "$f") || fail "a long list should build"
  [ "$(printf '%s' "$out" | jq -r '.markdown | length')" -le 8192 ] || fail "the list fits T3's limit"
  assert_equals "7" "$(printf '%s' "$out" | jq -r '.markdown' | grep -c '^- `')" "no entry is dropped"
  assert_equals "6" "$(printf '%s' "$out" | jq -r '.markdown' | grep -c '^  Rule [0-5] x*…\( (captain approves)\)\{0,1\}$')" "each long When is cut, with an ellipsis"
  assert_contains "$(printf '%s' "$out" | jq -r '.markdown')" '… (captain approves)' "the captain's mark survives the cut"
  assert_contains "$(printf '%s' "$out" | jq -r '.markdown')" $'\n  Default\n' "a short When is kept whole"
  assert_equals "6" "$(printf '%s' "$out" | jq -r '.shortened')" "and the count says so"
  printf '{"rules": [{"when": "x", "use": {"model": "m"}}]}\n' > "$f"
  out=$(routing_payload "$f" 2>/dev/null)
  expect_code 1 "$?" "a profile without a harness is malformed"
  assert_equals "routing_malformed" "$(printf '%s' "$out" | jq -r '.error.code')" "and named so"
  assert_contains "$(printf '%s' "$out" | jq -r '.error.message')" "rules[0].use needs harness" "with the field"
  pass "fm-t3-mcp.mjs routing-payload: grouped by family, one entry per model, fits the limit, refuses a malformed file"
}

test_routing_push_only_when_changed() {
  make_home routing 'w.routingTool = true'
  local out rc
  write_routing "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 0 "$?" "the first pass pushes the table: $out"
  assert_equals "1" "$(routing_calls)" "one push"
  assert_equals "$(routing_payload "$HOME_DIR/config/crew-dispatch.json" | jq -r '.markdown')" \
    "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "of the built table"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "an unchanged pass should succeed"
  assert_equals "0" "$(routing_calls)" "an unchanged table is not pushed again"
  jq '.rules[1].use.model = "newer-model"' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/next.json"
  mv "$HOME_DIR/config/next.json" "$HOME_DIR/config/crew-dispatch.json"
  t3_fake_set 'w.failTools = { t3_routing_set: { code: "unavailable", message: "settings are busy" } }'
  out=$(sync_now)
  rc=$?
  expect_code 1 "$rc" "a failed push is reported: $out"
  assert_contains "$out" "routing" "the line names the routing table"
  t3_fake_set 'delete w.failTools'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the retry should succeed"
  assert_equals "1" "$(routing_calls)" "the next pass retries"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "newer-model" "with the new model"
  printf '{"rules": "oops"}\n' > "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  out=$(sync_now)
  expect_code 1 "$?" "a malformed file is reported: $out"
  assert_contains "$out" "rules must be an array" "naming the fault"
  assert_equals "0" "$(routing_calls)" "and nothing is sent"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "newer-model" "so the Bridge keeps the last table"
  rm -f "$HOME_DIR/config/crew-dispatch.json"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a pass without the file should succeed"
  assert_equals '{"markdown":null}' "$(t3_fake_calls t3_routing_set)" "a removed file clears the table"
  assert_equals "null" "$(jq -c '.modelRouting' "$T3_FAKE_WORLD")" "and T3 holds none"
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "the pass should succeed"
  assert_equals "0" "$(routing_calls)" "only once"
  pass "fm-t3-needs-me.sh sync: the routing table is pushed when it changes, retried, kept on a malformed file, cleared once"
}

test_routing_absent_or_unsupported() {
  make_home routing-none 'w.routingTool = true'
  : > "$T3_FAKE_LOG"
  sync_now >/dev/null || fail "a home without a dispatch file should succeed"
  assert_equals "0" "$(routing_calls)" "never sent, so nothing is cleared"
  local out n
  make_home routing-old-t3
  write_routing "$HOME_DIR/config/crew-dispatch.json"
  out=$(sync_now)
  expect_code 0 "$?" "a T3 without the routing table is not a failure: $out"
  assert_equals "" "$out" "and says nothing"
  for n in 1 2 3 4; do sync_now >/dev/null || fail "a T3 without the routing table stays quiet once held back"; done
  t3_fake_set 'w.routingTool = true'
  FM_NEEDS_ME_NOW=$(( $(date +%s) + 900 )) needs_me sync >/dev/null || fail "the retry should succeed"
  assert_contains "$(jq -r '.modelRouting.markdown' "$T3_FAKE_WORLD")" "claude-fable-9" "and a T3 that gains it gets the table"
  pass "fm-t3-needs-me.sh sync: no dispatch file sends no routing table; an older T3 is quiet and retried"
}


test_objectives_payload_shape
test_objectives_payload_fits_the_limit
test_routing_payload_shape
test_routing_push_only_when_changed
test_routing_absent_or_unsupported
test_objectives_push_only_when_changed
test_objectives_clear_once_and_back_off
test_reply_marker
test_reply_on_a_kept_card

echo "ok: fm-t3-needs-me"
