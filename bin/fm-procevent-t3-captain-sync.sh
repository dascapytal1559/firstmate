#!/usr/bin/env bash
# Process-event adapter for the captain's T3 list listener
# (bin/fm-t3-captain-sync.sh owns the listener and its arming).
#
# Usage:
#   fm-procevent-t3-captain-sync.sh relisten
#   fm-procevent-t3-captain-sync.sh terminal <result-file>
#
# relisten   Exit 0: the listener runs for as long as its home does, so the
#            runner starts it again in the same claim whenever it stops,
#            which is how a listener that died comes back without firstmate.
# terminal   Exit 1: no result ends this source. The listener prints nothing
#            on stdout, so anything captured is unexpected and reaches
#            firstmate as an ordinary wake.
set -u

case "${1-}:$#" in
  relisten:1) exit 0 ;;
  terminal:2) exit 1 ;;
  *) sed -n '/^# Usage:/,/^#            firstmate as/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
