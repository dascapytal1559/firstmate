#!/usr/bin/env bash
# tests/fm-rules.test.sh - bin/fm-rules.sh records the captain's answers to his
# rules from T3's Bridge: the inventory, the rules-history log entry, the
# pending rule-file edits, and the follow-up it prints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq absent"; exit 0; }

RULES="$ROOT/bin/fm-rules.sh"
TMP_ROOT=$(fm_test_tmproot fm-rules)
trap fm_test_cleanup EXIT

# make_home <name> -> HOME_DIR: a home with a made-up inventory and log, and
# no T3 credential, so the closing sync pass takes no part.
make_home() {
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data/rules" "$HOME_DIR/data/archived/rules-history" "$HOME_DIR/state" "$HOME_DIR/config"
  cat > "$HOME_DIR/data/rules/inventory.json" <<'EOF'
{
  "rules": [
    { "id": "R1", "group": "FirstMate · How to work", "source": "data/captain.md \"How to work\"", "text": "Warm starts.",
      "status": "approved", "approvedOn": "2026-11-08" },
    { "id": "R2", "group": "FirstMate · How to work", "source": "data/captain.md \"How to work\"", "text": "Search widely before saying not found.",
      "status": "pending", "recommendation": { "choice": "keep-narrower", "label": "Keep narrower", "proposedText": "Search X before saying not found." } },
    { "id": "R3", "group": "Workers", "source": "config/brief-include.md", "text": "Use short commands.",
      "status": "pending", "recommendation": { "choice": "keep", "label": "Keep" } },
    { "id": "R4", "group": "Workers", "source": "config/brief-include.md", "text": "Docker runs on port 4000.",
      "status": "pending", "recommendation": { "choice": "fact", "label": "Fact", "note": "Says how things are." } },
    { "id": "R5", "group": "Workers", "text": "Ping him on Discord.",
      "status": "pending", "recommendation": { "choice": "drop", "label": "Drop" } }
  ]
}
EOF
  printf '# Rules history log\n\n## 2026-11-10\n\n- An older entry.\n' > "$HOME_DIR/data/archived/rules-history/log.md"
}

rules() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_RULES_TODAY=2026-11-11 "$RULES" "$@"
}

rule() {  # <id> -> the rule's JSON, or nothing
  jq -c --arg id "$1" '.rules[] | select(.id == $id)' "$HOME_DIR/data/rules/inventory.json"
}

log_tail() {
  tail -n "$1" "$HOME_DIR/data/archived/rules-history/log.md"
}

test_keep_approves_as_worded() {
  make_home keep
  local out
  out=$(rules answer R3 keep 2>&1) || fail "keep should record: $out"
  assert_equals '{"id":"R3","group":"Workers","source":"config/brief-include.md","text":"Use short commands.","status":"approved","approvedOn":"2026-11-11"}' \
    "$(rule R3)" "the rule is approved today, its recommendation gone"
  assert_contains "$out" "no rule-file edit" "and needs no file edit"
  assert_equals "null" "$(jq -c '.pendingEdits' "$HOME_DIR/data/rules/inventory.json")" "so none is listed"
  # shellcheck disable=SC2016 # the backticks are the log's literal Markdown
  assert_equals "$(printf '%s\n' '' '### 2026-11-11 (Bridge rule answers)' '' \
    '- R3, `config/brief-include.md`: "Use short commands.". Approved as a standing rule on his "Keep" chip on the Bridge. His words: "Agree with your recommendation on rule R3: Keep."')" \
    "$(log_tail 4)" "one log entry under today's heading, his chip's words"
  out=$(rules answer R3 keep 2>&1)
  expect_code 1 "$?" "an approved rule takes no second answer"
  assert_contains "$out" "already approved" "and says so"
  assert_equals "1" "$(grep -c '^- R3' "$HOME_DIR/data/archived/rules-history/log.md")" "nor a second log entry"
  pass "fm-rules.sh answer keep: approves the rule as worded, logs his chip's words once"
}

test_keep_narrower_rewrites_and_lists_the_edit() {
  make_home narrower
  local out
  out=$(rules answer R2 keep-narrower 2>&1) || fail "keep-narrower should record: $out"
  assert_equals "Search X before saying not found. approved 2026-11-11" "$(rule R2 | jq -r '"\(.text) \(.status) \(.approvedOn)"')" \
    "the narrower wording is the rule now"
  assert_equals '[{"id":"R2","choice":"keep-narrower","source":"data/captain.md \"How to work\"","on":"2026-11-11","from":"Search widely before saying not found.","text":"Search X before saying not found."}]' \
    "$(jq -c '.pendingEdits' "$HOME_DIR/data/rules/inventory.json")" "the rule-file edit is listed"
  assert_contains "$out" 'follow-up: in data/captain.md "How to work", rewrite rule R2 to: Search X before saying not found.' "and printed"
  assert_contains "$(log_tail 1)" 'narrower wording on his "Keep narrower" chip on the Bridge: "Search X before saying not found."' "the log has the new wording"
  out=$(rules edited R2 2>&1) || fail "edited should clear the pending edit: $out"
  assert_equals "[]" "$(jq -c '.pendingEdits' "$HOME_DIR/data/rules/inventory.json")" "the edit is no longer pending"
  out=$(rules edited R2 2>&1)
  expect_code 1 "$?" "a second edited finds nothing"
  pass "fm-rules.sh answer keep-narrower: the proposed wording becomes the rule and its file edit is listed until edited"
}

test_fact_and_drop_leave_the_inventory() {
  make_home leave
  local out
  out=$(rules answer R4 fact 2>&1) || fail "fact should record: $out"
  assert_equals "" "$(rule R4)" "a fact is no rule"
  assert_contains "$out" "in config/brief-include.md, move rule R4 into that file's facts" "the move is the follow-up"
  out=$(rules answer R5 drop 2>&1) || fail "drop should record: $out"
  assert_equals "" "$(rule R5)" "a dropped rule is gone"
  assert_contains "$out" "in Workers, remove rule R5: Ping him on Discord." "a rule with no source names its group"
  assert_equals "R4 fact Docker runs on port 4000.|R5 drop Ping him on Discord." \
    "$(jq -r '[.pendingEdits[] | "\(.id) \(.choice) \(.text)"] | join("|")' "$HOME_DIR/data/rules/inventory.json")" "both edits are listed"
  assert_equals "1" "$(grep -c '^### 2026-11-11 (Bridge rule answers)$' "$HOME_DIR/data/archived/rules-history/log.md")" "one heading for the day"
  assert_contains "$(log_tail 1)" 'Dropped on his "Drop" chip on the Bridge.' "the drop is logged"
  pass "fm-rules.sh answer fact and drop: the rule leaves the inventory and its file edit is listed"
}

test_another_answer_needs_his_words() {
  make_home words
  local out
  out=$(rules answer R3 drop 2>&1)
  expect_code 1 "$?" "an answer other than the recommendation needs his words"
  assert_contains "$out" "--words-file" "and says how to give them"
  assert_equals "pending" "$(rule R3 | jq -r '.status')" "nothing changed"
  printf 'Drop it,\nwe never do that.\n' > "$HOME_DIR/words"
  out=$(rules answer R3 drop --words-file "$HOME_DIR/words" 2>&1) || fail "with his words it records: $out"
  assert_contains "$(log_tail 1)" 'His words: "Drop it, we never do that."' "his words, on one line"
  out=$(rules answer R4 keep-narrower --words-file "$HOME_DIR/words" 2>&1)
  expect_code 1 "$?" "keep-narrower needs a proposed wording"
  out=$(rules answer R9 keep 2>&1)
  expect_code 1 "$?" "an unknown rule is refused"
  out=$(rules answer R3 maybe 2>&1)
  expect_code 2 "$?" "an unknown choice is a usage error"
  pass "fm-rules.sh answer: a different answer is recorded only with his words; bad ids and choices are refused"
}

test_a_malformed_inventory_is_left_alone() {
  make_home malformed
  local out before
  jq '.rules[0].recommendation = {choice: "keep", label: "Keep"}' "$HOME_DIR/data/rules/inventory.json" > "$HOME_DIR/next"
  mv "$HOME_DIR/next" "$HOME_DIR/data/rules/inventory.json"
  before=$(cat "$HOME_DIR/data/rules/inventory.json" "$HOME_DIR/data/archived/rules-history/log.md")
  out=$(rules answer R3 keep 2>&1)
  expect_code 1 "$?" "a malformed inventory is refused"
  assert_contains "$out" "is approved, so it takes no recommendation" "naming the fault"
  assert_equals "$before" "$(cat "$HOME_DIR/data/rules/inventory.json" "$HOME_DIR/data/archived/rules-history/log.md")" "and nothing is written"
  pass "fm-rules.sh answer: a malformed inventory changes nothing"
}

test_keep_approves_as_worded
test_keep_narrower_rewrites_and_lists_the_edit
test_fact_and_drop_leave_the_inventory
test_another_answer_needs_his_words
test_a_malformed_inventory_is_left_alone

echo "ok: fm-rules"
