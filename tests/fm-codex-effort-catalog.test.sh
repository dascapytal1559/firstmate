#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh's Codex effort catalog subcommands, the
# single reader of which reasoning efforts a Codex model offers.
# Pins the bug where a Codex worker launched with --effort max on gpt-6.1-sol or
# gpt-6-astra silently ran without max because only one model name was allowed.
# Every case uses a fake CODEX_HOME so nothing reads the invoking machine's cache.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-effort-catalog)
fm_test_write_codex_catalog "$TMP_ROOT/codex-home" || fail "could not write the fake catalog"

check() {  # <codex-home> <model> <effort>
  CODEX_HOME=$1 "$HARNESS" codex-effort-check "$2" "$3"
}

test_catalog_models_offer_max() {
  local model
  for model in gpt-6.1-sol gpt-6-astra gpt-5.6-luna; do
    assert_equals supported "$(check "$TMP_ROOT/codex-home" "$model" max)" "$model must offer max"
  done
  pass "models whose catalog entry lists max are supported at max"
}

test_catalog_model_without_the_effort_is_unsupported() {
  assert_equals unsupported "$(check "$TMP_ROOT/codex-home" gpt-5 max)" "gpt-5 stops at high"
  assert_equals unsupported "$(check "$TMP_ROOT/codex-home" gpt-5.6-luna ultra)" "Luna does not offer ultra"
  assert_equals supported "$(check "$TMP_ROOT/codex-home" gpt-5 high)" "gpt-5 offers high"
  pass "a listed model without the effort is unsupported"
}

test_no_evidence_is_unknown() {
  assert_equals unknown "$(check "$TMP_ROOT/codex-home" not-in-catalog max)" "an unlisted model"
  assert_equals unknown "$(check "$TMP_ROOT/codex-home" '' max)" "no model named"
  assert_equals unknown "$(check "$TMP_ROOT/absent-home" gpt-6.1-sol max)" "no catalog file"
  mkdir -p "$TMP_ROOT/broken-home"
  printf 'not json' > "$TMP_ROOT/broken-home/models_cache.json"
  assert_equals unknown "$(check "$TMP_ROOT/broken-home" gpt-6.1-sol max)" "an unreadable catalog"
  pass "a missing, malformed, or non-listing catalog is unknown, never a guess"
}

test_models_lists_only_models_offering_the_effort() {
  assert_equals '["gpt-6.1-sol","gpt-6-astra","gpt-5.6-luna"]' \
    "$(CODEX_HOME="$TMP_ROOT/codex-home" "$HARNESS" codex-effort-models max)" "max models"
  assert_equals '["gpt-6.1-sol","gpt-6-astra"]' \
    "$(CODEX_HOME="$TMP_ROOT/codex-home" "$HARNESS" codex-effort-models ultra)" "ultra models"
  assert_equals '[]' "$(CODEX_HOME="$TMP_ROOT/absent-home" "$HARNESS" codex-effort-models max)" "no catalog"
  pass "codex-effort-models lists exactly the models that offer the effort"
}

test_catalog_models_offer_max
test_catalog_model_without_the_effort_is_unsupported
test_no_evidence_is_unknown
test_models_lists_only_models_offering_the_effort
