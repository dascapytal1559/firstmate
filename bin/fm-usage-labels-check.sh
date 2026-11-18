#!/usr/bin/env bash
# fm-usage-labels-check.sh - nightly check that every token T3 Code counted
# in a day carries a label (fork, FORK.md "A nightly check finds unlabelled
# usage"). One step of bin/fm-nightly-checks.sh.
#
# Usage: fm-usage-labels-check.sh [--day <YYYY-MM-DD>] [--no-write]
#
# Reads the T3 Code fork's labels watchdog, t3_usage_reasons, through
# bin/fm-t3-mcp.mjs usage-reasons for one day: --day, default yesterday in
# local time, in T3's own time zone. A token is unlabelled when its row is
# byDefault (no device evidence, so it counts to the computer only by default)
# or its reason is not one of the evidence reasons (typed, inherited, journal,
# upkeep, terminal).
#
#   - Everything labelled and no failed claim: nothing is written, one
#     summary line on stdout.
#   - Unlabelled tokens: backlog item usage-labels-gap names each reason and
#     provider with its tokens.
#   - Failed naming calls: the day's lines (by local time) in
#     state/t3-usage-claims.log, each a usage claim that failed
#     (bin/fm-t3-usage-claim.sh). A wake that fails to name its turn counts
#     as upkeep on the computer, which the T3 figure alone cannot tell from
#     real upkeep, so any such line raises the same item, counted and grouped
#     by error.
#   - The figure cannot be read (no T3 credential, a T3 without the watchdog,
#     T3 unreachable, an answer that does not read as a figure): the same item
#     says so and why. An unreadable figure is never taken as zero.
#
# There is only ever one such item. An open one (queued, held, or in flight)
# is retitled and its body replaced with tonight's finding, the previous body
# archived in the item; a done one is reopened first; otherwise it is added,
# queued, as kind scout. A night that finds everything labelled leaves an open
# item as it is: closing it is the fix's job. No model is called.
#
# --no-write prints the item it would raise and changes nothing.
#
# Requires node (for the helper) and jq; backlog writes go through
# bin/fm-tasks-axi.sh, so tasks-axi must be on PATH. The T3 credential is the
# helper's (FM_T3CODE_TOKEN_FILE, else <home>/config/t3code-token).
#
# Exit status: 0 when the check ran and any item was written, 1 when the
# backlog write failed, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
HELPER="$SCRIPT_DIR/fm-t3-mcp.mjs"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"
CLAIMS_LOG="${FM_STATE_OVERRIDE:-$FM_HOME/state}/t3-usage-claims.log"
ITEM=usage-labels-gap

usage() {
  sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"
}

day=
write=1
while [ $# -gt 0 ]; do
  case "$1" in
    --day)
      [ $# -ge 2 ] || { echo "fm-usage-labels-check: --day needs a value" >&2; exit 2; }
      day=$2
      shift 2
      ;;
    --no-write) write=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-usage-labels-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$day" ]; then
  day=$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)
fi
case "$day" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "fm-usage-labels-check: --day must be YYYY-MM-DD, not '$day'" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "fm-usage-labels-check: jq is required" >&2; exit 1; }

# The figure, or why it cannot be read.
figure=
problem=
if ! command -v node >/dev/null 2>&1; then
  problem="node is not on PATH, so the T3 helper cannot run"
else
  figure=$(node "$HELPER" usage-reasons --days 1 --until-day "$day" 2>/dev/null)
  if [ "$(printf '%s' "$figure" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    problem=$(printf '%s' "$figure" | jq -r '.error.message // empty' 2>/dev/null)
    [ -n "$problem" ] || problem="the T3 helper gave no answer"
  fi
fi

# shellcheck disable=SC2016  # $ev and $r are jq variables.
GAPS='["typed","inherited","journal","upkeep","terminal"] as $ev
  | [.rows[] | select(.tokens > 0 and (.byDefault or (.reason as $r | $ev | index($r) | not)))]
  | group_by([.reason, .provider])
  | map({reason: .[0].reason, provider: .[0].provider, tokens: (map(.tokens) | add)})
  | sort_by(-.tokens)'

# The day's failed naming calls, by local time: {count, groups: [{error, n}]}.
# shellcheck disable=SC2016  # $day and $f are jq variables.
failed='{"count":0,"groups":[]}'
if [ -f "$CLAIMS_LOG" ]; then
  failed=$(jq -R -s -c --arg day "$day" '
    [split("\n")[] | select(length > 0) | split("\t") as $f
      | select(($f[0] | try (fromdateiso8601 | localtime | strftime("%Y-%m-%d")) catch "") == $day)
      | ($f[2] // "")]
    | {count: length, groups: (group_by(.) | map({error: .[0], n: length}) | sort_by(-.n))}' "$CLAIMS_LOG" 2>/dev/null) \
    || failed='{"count":0,"groups":[]}'
fi
failed_count=$(printf '%s' "$failed" | jq -r '.count')
failed_body=
if [ "$failed_count" -gt 0 ]; then
  failed_body="FirstMate's usage claims failed $failed_count times on $day, so the turns they meant to name count as upkeep on the computer, which T3's figure cannot tell from real upkeep (state/t3-usage-claims.log):
$(printf '%s' "$failed" | jq -r '.groups[:5][] | "- \(.n)x \(.error)"')"
fi

if [ -n "$problem" ]; then
  title="Usage labels unreadable for $day"
  body="The nightly usage-label check could not read T3's labels watchdog (t3_usage_reasons) for $day, so that day's labelling is unknown, not zero: $problem."
else
  gaps=$(printf '%s' "$figure" | jq -c "$GAPS")
  total=$(printf '%s' "$figure" | jq -r '.tokens')
  zone=$(printf '%s' "$figure" | jq -r '.timeZone')
  if [ "$gaps" = "[]" ] && [ "$failed_count" -eq 0 ]; then
    echo "fm-usage-labels-check: $day ($zone): all $total tokens labelled"
    exit 0
  fi
  if [ "$gaps" = "[]" ]; then
    title="Usage labels: $failed_count failed naming calls on $day"
    body="The nightly usage-label check found all $total tokens on $day ($zone) labelled."
  else
    unlabelled=$(printf '%s' "$gaps" | jq -r 'map(.tokens) | add')
    title="Usage labels: $unlabelled tokens unlabelled on $day"
    [ "$failed_count" -eq 0 ] || title="Usage labels: $unlabelled tokens unlabelled and $failed_count failed naming calls on $day"
    body="The nightly usage-label check found $unlabelled of $total tokens on $day ($zone) with no device evidence (counted to the computer only by default):
$(printf '%s' "$gaps" | jq -r '.[] | "- \(.reason), \(.provider): \(.tokens) tokens"')
Read it again with \`t3 usage reasons --days 1 --until-day $day\`."
  fi
fi
[ -z "$failed_body" ] || body="$body
$failed_body"

if [ "$write" = 0 ]; then
  printf '%s\n%s\n' "$title" "$body"
  exit 0
fi

body_file=$(mktemp "${TMPDIR:-/tmp}/fm-usage-labels.XXXXXX") || exit 1
trap 'rm -f "$body_file"' EXIT
printf '%s\n' "$body" > "$body_file"

shown=$("$TASKS" show "$ITEM" 2>&1)
shown_rc=$?
if [ "$shown_rc" -ne 0 ]; then
  case "$shown" in
    *NOT_FOUND*) ;;
    *) echo "fm-usage-labels-check: cannot read backlog item $ITEM: $shown" >&2; exit 1 ;;
  esac
  "$TASKS" add "$ITEM" "$title" --kind scout --body-file "$body_file" >/dev/null || exit 1
  echo "fm-usage-labels-check: raised $ITEM: $title"
  exit 0
fi
state=$(printf '%s\n' "$shown" | awk '$1 == "state:" { print $2; exit }')
if [ "$state" = "done" ]; then
  "$TASKS" reopen "$ITEM" >/dev/null || exit 1
fi
"$TASKS" update "$ITEM" --title "$title" --body-file "$body_file" --archive-body >/dev/null || exit 1
echo "fm-usage-labels-check: updated $ITEM: $title"
