#!/usr/bin/env bash
# fm-rules.sh - record the captain's answers to his rules from T3's Bridge
# (docs/t3code-backend.md "Rules").
#
# The home's data/rules/inventory.json lists every standing rule the Bridge
# shows ({rules[], pendingEdits[]}; bin/fm-t3-mcp.mjs rules-payload owns the
# rule fields). A pending rule's recommendation chip sends FirstMate a message
# whose machine line reads `rule-answer: <id> <choice>`; this records it.
#
# Usage:
#   fm-rules.sh answer <id> <choice> [--words-file <path>]
#     <choice> is keep, keep-narrower, make-rule, fact or drop. Only a pending
#     rule takes an answer. keep and make-rule approve the rule as worded
#     (status approved, approvedOn today); keep-narrower approves it with its
#     recommendation's proposedText as the new text; fact and drop take it out
#     of the inventory. keep-narrower, fact and drop also list the rule-file
#     edit firstmate still has to make in pendingEdits ({id, choice, source,
#     on, text, and for keep-narrower the replaced wording as from}), and the
#     follow-up is printed. One entry is appended to
#     data/archived/rules-history/log.md under the heading
#     "### <date> (Bridge rule answers)", with his words: the --words-file
#     text, else, only when <choice> is the rule's recommendation, the chip's
#     sentence "Agree with your recommendation on rule <id>: <label>.". The
#     rule files themselves are never edited here.
#   fm-rules.sh edited <id>
#     Removes <id>'s pendingEdits entry once firstmate has made that edit.
#
# Both verbs end with one bin/fm-t3-needs-me.sh sync pass, so the Bridge shows
# the change. FM_RULES_TODAY (YYYY-MM-DD) overrides today's date for tests.
#
# Exit: 0; 1 when the inventory or log is missing or malformed, the rule is not
# found or not pending, or a write failed; 2 for usage errors. Bash 3.2
# compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INVENTORY="$DATA/rules/inventory.json"
LOG="$DATA/archived/rules-history/log.md"
TODAY=${FM_RULES_TODAY:-$(date +%F)}

usage() {
  sed -n '10,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "fm-rules: $*" >&2
  exit 1
}

[ "$#" -ge 2 ] || usage
VERB=$1
ID=$2
shift 2
CHOICE=''
WORDS_FILE=''
case "$VERB" in
  answer)
    [ "$#" -ge 1 ] || usage
    CHOICE=$1
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --words-file) [ "$#" -ge 2 ] || usage; WORDS_FILE=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$CHOICE" in keep|keep-narrower|make-rule|fact|drop) ;; *) echo "fm-rules: unknown choice '$CHOICE'" >&2; usage ;; esac
    ;;
  edited) [ "$#" = 0 ] || usage ;;
  *) usage ;;
esac
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "fm-rules: malformed rule id '$ID'" >&2; exit 2 ;; esac
case "$TODAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) echo "fm-rules: FM_RULES_TODAY must be YYYY-MM-DD" >&2; exit 2 ;; esac
[ -z "$WORDS_FILE" ] || [ -r "$WORDS_FILE" ] || { echo "fm-rules: cannot read $WORDS_FILE" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v node >/dev/null 2>&1 || die "node is required"
[ -f "$INVENTORY" ] || die "no inventory at $INVENTORY"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_lock_acquire_wait_max "$DATA/rules/.lock" 30 || die "another answer holds $DATA/rules/.lock"
TMP="$INVENTORY.tmp.$$"
cleanup() {
  rm -f -- "$TMP"
  fm_lock_release "$DATA/rules/.lock" || true
}
trap cleanup EXIT

# valid <file>: the file holds to the Bridge contract, else its fault is named.
valid() {
  local err
  err=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" rules-payload --file "$1" 2>&1 >/dev/null) \
    || die "$(printf '%s' "$err" | head -n 1 | sed 's/^fm-t3-mcp: //')"
}

# commit: the staged inventory replaces the real one.
commit() {
  valid "$TMP"
  mv -f "$TMP" "$INVENTORY" || die "could not write $INVENTORY"
}

sync_bridge() {
  "$SCRIPT_DIR/fm-t3-needs-me.sh" sync || true
}

valid "$INVENTORY"

if [ "$VERB" = edited ]; then
  jq -e --arg id "$ID" 'any(.pendingEdits[]?; .id == $id)' "$INVENTORY" >/dev/null || die "no pending edit for rule $ID"
  jq --arg id "$ID" '.pendingEdits |= map(select(.id != $id))' "$INVENTORY" > "$TMP" || die "could not stage $INVENTORY"
  commit
  echo "rule $ID: its pending edit is done"
  sync_bridge
  exit 0
fi

[ -f "$LOG" ] || die "no rules-history log at $LOG"
RULE=$(jq -c --arg id "$ID" '.rules[] | select(.id == $id)' "$INVENTORY")
[ -n "$RULE" ] || die "no rule $ID in $INVENTORY"
[ "$(printf '%s' "$RULE" | jq -r '.status')" = pending ] || die "rule $ID is already approved"

REC_CHOICE=$(printf '%s' "$RULE" | jq -r '.recommendation.choice')
if [ "$CHOICE" = "$REC_CHOICE" ]; then
  LABEL=$(printf '%s' "$RULE" | jq -r '.recommendation.label')
else
  case "$CHOICE" in
    keep) LABEL='Keep' ;;
    keep-narrower) LABEL='Keep narrower' ;;
    make-rule) LABEL='Make it a rule' ;;
    fact) LABEL='Fact' ;;
    drop) LABEL='Drop' ;;
  esac
fi
if [ -n "$WORDS_FILE" ]; then
  WORDS=$(tr '\n\r\t' '   ' < "$WORDS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')
  [ -n "$WORDS" ] || die "$WORDS_FILE is empty"
elif [ "$CHOICE" = "$REC_CHOICE" ]; then
  WORDS="Agree with your recommendation on rule $ID: $LABEL."
else
  die "rule $ID's recommendation is $REC_CHOICE; record a different answer with --words-file holding his words"
fi
NEW_TEXT=''
if [ "$CHOICE" = keep-narrower ]; then
  NEW_TEXT=$(printf '%s' "$RULE" | jq -r '.recommendation.proposedText // ""')
  [ -n "$NEW_TEXT" ] || die "rule $ID has no narrower wording to approve; agree the wording with him and edit the inventory by hand"
fi

jq --arg id "$ID" --arg choice "$CHOICE" --arg today "$TODAY" --arg new "$NEW_TEXT" '
  (.rules[] | select(.id == $id)) as $r
  | if $choice == "fact" or $choice == "drop" then
      .rules |= map(select(.id != $id))
      | .pendingEdits = ((.pendingEdits // []) + [{id: $id, choice: $choice} + ($r | {source}) + {on: $today, text: $r.text}])
    else
      .rules |= map(if .id == $id then
          del(.recommendation) + {status: "approved", approvedOn: $today} + (if $new != "" then {text: $new} else {} end)
        else . end)
      | if $choice == "keep-narrower" then
          .pendingEdits = ((.pendingEdits // []) + [{id: $id, choice: $choice} + ($r | {source}) + {on: $today, from: $r.text, text: $new}])
        else . end
    end' "$INVENTORY" > "$TMP" || die "could not stage $INVENTORY"
valid "$TMP"

SOURCE=$(printf '%s' "$RULE" | jq -r '.source // .group')
TEXT=$(printf '%s' "$RULE" | jq -r '.text | gsub("\\s*\n\\s*"; " ")')
case "$CHOICE" in
  keep|make-rule)
    OUTCOME="Approved as a standing rule on his \"$LABEL\" chip on the Bridge."
    FOLLOW="no rule-file edit: the rule stays as worded in $SOURCE" ;;
  keep-narrower)
    OUTCOME="Approved as a standing rule in narrower wording on his \"$LABEL\" chip on the Bridge: \"$(printf '%s' "$NEW_TEXT" | tr '\n' ' ')\"; replaced the wording quoted."
    FOLLOW="in $SOURCE, rewrite rule $ID to: $NEW_TEXT" ;;
  fact)
    OUTCOME="No longer a rule, on his \"$LABEL\" chip on the Bridge: it becomes a fact."
    FOLLOW="in $SOURCE, move rule $ID into that file's facts as a present-tense fact (data/captain.md's facts go to data/learnings.md): $TEXT" ;;
  drop)
    OUTCOME="Dropped on his \"$LABEL\" chip on the Bridge."
    FOLLOW="in $SOURCE, remove rule $ID: $TEXT" ;;
esac

HEADING="### $TODAY (Bridge rule answers)"
LAST_HEADING=$(grep '^#' "$LOG" | tail -n 1)
TICK='`'
{
  [ "$LAST_HEADING" = "$HEADING" ] || printf '\n%s\n\n' "$HEADING"
  printf -- '- %s, %s%s%s: "%s". %s His words: "%s"\n' "$ID" "$TICK" "$SOURCE" "$TICK" "$TEXT" "$OUTCOME" "$WORDS"
} >> "$LOG" || die "could not append to $LOG"
commit

echo "rule $ID: $LABEL recorded in data/rules/inventory.json and the rules-history log"
case "$CHOICE" in
  keep|make-rule) echo "follow-up: $FOLLOW" ;;
  *) echo "follow-up: $FOLLOW"
     echo "then: bin/fm-rules.sh edited $ID" ;;
esac
sync_bridge
exit 0
