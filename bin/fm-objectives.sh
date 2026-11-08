#!/usr/bin/env bash
# fm-objectives.sh - print this home's priorities and high level objectives as JSON.
#
# The one reader of the home-private data/priorities.md and
# data/high-level-objectives.md. Each file is a plain bullet list: every top-level
# "- text" line becomes one {"text"} row, in file order, and any other line is
# ignored. A missing file is an empty list.
# Prints {"priorities":[...],"objectives":[...]} and exits 0.
#
# Read-only. fm-bearings-snapshot.sh projects these as its priorities and objectives
# fields, the /ahoy recap runs this directly, and fm-t3-needs-me.sh builds T3's
# Bridge objectives from its output. Writing and editing either file is not this
# script's concern.
set -u

case "${1:-}" in
  '') ;;
  -h|--help) echo "usage: fm-objectives.sh"; echo "Print this home's priorities and high level objectives as one JSON object of {text} rows."; exit 0 ;;
  *) echo "usage: fm-objectives.sh" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

bullets() {  # <file>
  [ -f "$1" ] || { echo '[]'; return 0; }
  jq -Rcn '[inputs | capture("^- +(?<text>.*\\S)\\s*$")]' "$1"
}

PRIORITIES=$(bullets "$FM_HOME/data/priorities.md") || exit 1
OBJECTIVES=$(bullets "$FM_HOME/data/high-level-objectives.md") || exit 1
exec jq -cn --argjson priorities "$PRIORITIES" --argjson objectives "$OBJECTIVES" \
  '{priorities:$priorities,objectives:$objectives}'
