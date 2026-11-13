#!/usr/bin/env bash
# fm-t3-review-lib.sh - the one reader of a retained T3 review's record
# (docs/t3code-backend.md "Retained reviews"). bin/fm-t3-review.sh owns every
# write of these fields and their transitions; this file only reads them, so
# the card, the watcher, recovery, and cleanup agree on what counts.
#
# A task's record (state/<id>.meta) carries a retained review while all hold:
#   kind=scout        a ship never keeps its thread, so a promoted scout's
#                     leftover fields count for nothing;
#   backend=t3code    other backends keep today's cleanup;
#   t3_review=<state> pending (the handoff is persisted, its publication not
#                     yet proven), waiting (published and proven: the thread
#                     carries the tag and automatic settling off; no
#                     note is posted), or closed (the captain archived or
#                     deleted the thread; cleanup may now run);
#   t3_review_target= the thread the review was kept on, equal to the
#                     record's t3_thread_id, so a record bound to another
#                     thread never inherits it.
# Sourced; defines functions only. Bash 3.2 compatible.

# The exact tag a kept thread carries in T3; bin/fm-t3-review.sh applies it.
# shellcheck disable=SC2034  # read by the scripts that source this file
FM_T3_REVIEW_TAG='waiting for captain'

# _fm_t3_review_field <meta> <key>: the last value of key= in <meta>.
_fm_t3_review_field() {
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2="*) value=${line#*=} ;;
    esac
  done < "$1" 2>/dev/null || true
  printf '%s' "$value"
}

# fm_t3_review_state <meta>: prints pending, waiting, or closed for a record
# that carries a retained review, and nothing otherwise. Never fails.
fm_t3_review_state() {
  local meta=$1 state kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  state=$(_fm_t3_review_field "$meta" t3_review)
  case "$state" in
    pending|waiting|closed) ;;
    *) return 0 ;;
  esac
  kind=$(_fm_t3_review_field "$meta" kind)
  [ "$kind" = scout ] || return 0
  [ "$(_fm_t3_review_field "$meta" backend)" = t3code ] || return 0
  [ -n "$(_fm_t3_review_field "$meta" t3_thread_id)" ] || return 0
  [ "$(_fm_t3_review_field "$meta" t3_review_target)" = "$(_fm_t3_review_field "$meta" t3_thread_id)" ] || return 0
  printf '%s' "$state"
}
