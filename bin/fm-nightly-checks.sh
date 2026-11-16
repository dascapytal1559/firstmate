#!/usr/bin/env bash
# fm-nightly-checks.sh - this home's model-free nightly checks, run once a
# night from the host's scheduler.
#
# Usage: fm-nightly-checks.sh
#
# Runs each step in order, each on its own, so one step failing never stops
# the next; every step owns its contract in its own header:
#   1. bin/fm-clear-watch.sh        every clear of FirstMate's main session;
#   2. bin/fm-usage-labels-check.sh every T3 Code token of yesterday labelled.
# A step's diagnostics go to stderr as it wrote them. Exit status: 0 when
# every step succeeded, else 1, after all steps have run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  *) echo "fm-nightly-checks: takes no arguments" >&2; exit 2 ;;
esac

status=0
for step in fm-clear-watch.sh fm-usage-labels-check.sh; do
  if ! bash "$SCRIPT_DIR/$step"; then
    echo "fm-nightly-checks: $step failed" >&2
    status=1
  fi
done
exit "$status"
