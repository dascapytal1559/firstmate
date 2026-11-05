#!/usr/bin/env bash
# fm-objectives.sh - print this home's high level objectives as a JSON array.
#
# The one reader of the home-private data/OBJECTIVES.md. Each "- **Name:** text"
# bullet under its "## High level objectives" heading becomes {"name","text"}, in
# file order. The section ends at the next # or ## heading; anything else in it,
# and any lookalike bullet outside it, is ignored.
# A missing file or section prints [] and exits 0.
#
# Read-only. fm-bearings-snapshot.sh projects this as its objectives field, and the
# /ahoy recap runs it directly. Writing and editing objectives is not this script's
# concern.
set -u

case "${1:-}" in
  '') ;;
  -h|--help) echo "usage: fm-objectives.sh"; echo "Print this home's high level objectives as a JSON array of {name,text}."; exit 0 ;;
  *) echo "usage: fm-objectives.sh" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FILE="$FM_HOME/data/OBJECTIVES.md"

[ -f "$FILE" ] || { echo '[]'; exit 0; }

exec jq -Rcn '
  reduce inputs as $line ({inside:false, found:[]};
    if ($line | test("^##? ")) then
      .inside = ($line | test("^## High level objectives\\s*$"))
    elif .inside then
      .found += [$line | capture("^- \\*\\*(?<name>[^*]+):\\*\\*\\s+(?<text>.*\\S)\\s*$")]
    else . end)
  | .found
' "$FILE"
