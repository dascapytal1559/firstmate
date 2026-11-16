#!/usr/bin/env bash
# fm-clear-watch.sh - nightly check of every clear of FirstMate's main session
# (fork, FORK.md "A nightly check watches every clear").
#
# Usage: fm-clear-watch.sh [--now <epoch>] [--transcripts <dir>]... [--weekly] [--no-write]
#
# Resolves this home (FM_HOME, else the code root) and runs
# bin/fm-clear-watch.py, whose header owns the whole contract: which
# transcripts it reads, how each clear's cause, saving, and signs of harm are
# judged, and what it writes into data/clear-watch/ and the morning briefing.
# No model is called. Runs once a night as a step of bin/fm-nightly-checks.sh.
#
# Requires python3.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME

command -v python3 >/dev/null 2>&1 || { echo "fm-clear-watch: python3 is required" >&2; exit 1; }
exec python3 -B "$SCRIPT_DIR/fm-clear-watch.py" "$@"
