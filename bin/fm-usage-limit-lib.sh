#!/usr/bin/env bash
# fm-usage-limit-lib.sh - the one owner of a task's usage-limit record: the
# small durable note that a T3 worker's latest run stopped on a provider usage
# limit, written by the watcher (bin/fm-watch.sh usage_limit_stale) and acted
# on by bin/fm-usage-limit.sh (move and resume). Sourced; defines functions
# only.
#
# Record: <state>/<task>.usage-limit, key=value lines, the last value of a key
# winning:
#   thread=<T3 thread id>      run=<the failed run's id>
#   instance=<provider instance the run failed on, the account>
#   model=<model>              window=<five_hour, seven_day, ... or ->
#   reset=<reset time, epoch seconds, or ->
#   source=<typed|items: which evidence classified it (bin/fm-t3-mcp.mjs limit)>
#   at=<epoch the watcher recorded it>
# and, after bin/fm-usage-limit.sh acts on it:
#   moved_to=<instance> moved_at=<epoch>   the worker now runs on that account
#   resumed_at=<epoch>                     rung after its account was reset
# A record stays until the task's next limit stop replaces it or its cleanup
# removes it; one for a task no longer recorded is ignored.

# fm_usage_limit_path <state-dir> <task>
fm_usage_limit_path() {
  printf '%s/%s.usage-limit' "$1" "$2"
}

# fm_usage_limit_get <record> <key>: the last value of <key>, or nothing.
fm_usage_limit_get() {
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1"
  printf '%s' "$value"
}

# fm_usage_limit_write <record> <thread> <row>: replace the record with a new
# stop, <row> being bin/backends/t3code.sh fm_backend_t3code_usage_limit's
# tab-separated line (run, instance, model, window, reset, source).
fm_usage_limit_write() {
  local rec=$1 thread=$2 run instance model window reset source tmp
  IFS=$'\t' read -r run instance model window reset source <<EOF
$3
EOF
  tmp=$(mktemp "$rec.XXXXXX") || return 1
  if printf 'thread=%s\nrun=%s\ninstance=%s\nmodel=%s\nwindow=%s\nreset=%s\nsource=%s\nat=%s\n' \
    "$thread" "$run" "$instance" "$model" "$window" "$reset" "$source" "$(date +%s)" > "$tmp" \
    && mv -f "$tmp" "$rec"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# fm_usage_limit_note <record> <key> <value>: add one fact to an existing
# record (moved_to, moved_at, resumed_at).
fm_usage_limit_note() {
  [ -f "$1" ] || return 1
  printf '%s=%s\n' "$2" "$3" >> "$1"
}

# fm_usage_limit_reset_text <epoch|->: the reset time as UTC ISO, or unknown.
fm_usage_limit_reset_text() {
  case "$1" in
    ''|-|*[!0-9]*) printf 'unknown' ;;
    *) date -u -r "$1" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf '%s' "$1" ;;
  esac
}

# fm_usage_limit_reason <task> <row>: the check wake's one-line reason, naming
# the cause, the account, the window, and the reset time.
fm_usage_limit_reason() {
  local run instance model window reset source
  IFS=$'\t' read -r run instance model window reset source <<EOF
$2
EOF
  printf 'check: usage-limit: %s stopped on account %s (%s limit, resets %s); move it now with bin/fm-usage-limit.sh move, or escalate' \
    "$1" "$instance" "${window/#-/unknown}" "$(fm_usage_limit_reset_text "$reset")"
}
