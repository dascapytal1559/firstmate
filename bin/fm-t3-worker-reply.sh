#!/usr/bin/env bash
# fm-t3-worker-reply.sh - name the task behind a captain message that T3
# forwarded from a worker's thread (docs/t3code-backend.md "Replies from a
# worker's thread").
#
# Usage: fm-t3-worker-reply.sh [<message-file>]
#   Reads the message from the file, or from stdin without one, and prints the
#   task id it names. The message names its worker on one line, either way:
#     kept-thread: <thread-id>     the worker's T3 thread, whose task is the
#                                  one record in state/*.meta with that
#                                  t3_thread_id
#     needs-me-task: <task-id>     the task itself
#   A leading `>` or spaces before the marker are ignored, so a quoted message
#   still reads.
#
# Exit: 0 with the task id; 1 when the message names no worker, or a thread no
# task records; 2 when it names more than one, both forms at once, a malformed
# id, or a thread more than one task records. Read-only. Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "$#" -gt 1 ]; then
  sed -n '/^# Usage:/,/^#   still reads./p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

slug_ok() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# marker <name>: every value the message gives on a `<name>: <value>` line,
# one per line, each once.
marker() {
  printf '%s\n' "$message" | sed -n "s/^[[:space:]>]*$1:[[:space:]]*\([^[:space:]]*\)[[:space:]]*\$/\1/p" | sort -u
}

count() {
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

# thread_tasks <thread-id>: the task ids whose record names that thread, one
# per line.
thread_tasks() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    slug_ok "$id" || continue
    [ "$(sed -n 's/^t3_thread_id=//p' "$meta" | tail -n 1)" = "$1" ] && printf '%s\n' "$id"
  done
  return 0
}

message=$(cat ${1:+"$1"}) || exit 1
ids=$(marker needs-me-task)
threads=$(marker kept-thread)
if [ -n "$threads" ]; then
  [ -z "$ids" ] || { echo "the message names both a task and a thread" >&2; exit 2; }
  [ "$(count "$threads")" = 1 ] || { echo "the message names more than one thread: $(printf '%s' "$threads" | tr '\n' ' ')" >&2; exit 2; }
  case "$threads" in *[!A-Za-z0-9:._-]*) echo "the message names a malformed thread id: $threads" >&2; exit 2 ;; esac
  ids=$(thread_tasks "$threads")
  [ -n "$ids" ] || { echo "no task records thread $threads" >&2; exit 1; }
  [ "$(count "$ids")" = 1 ] || { echo "thread $threads is recorded by more than one task: $(printf '%s' "$ids" | tr '\n' ' ')" >&2; exit 2; }
fi
[ -n "$ids" ] || exit 1
[ "$(count "$ids")" = 1 ] || { echo "the message names more than one task: $(printf '%s' "$ids" | tr '\n' ' ')" >&2; exit 2; }
slug_ok "$ids" || { echo "the message names a malformed task id: $ids" >&2; exit 2; }
printf '%s\n' "$ids"
