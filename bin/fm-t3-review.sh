#!/usr/bin/env bash
# fm-t3-review.sh - keep a finished T3 scout's thread and worker copy for the
# captain until he closes it (docs/t3code-backend.md "Retained reviews").
#
# This script owns the retained-review record in state/<id>.meta and every
# transition of it; bin/fm-t3-review-lib.sh is its one reader, and
# bin/fm-t3-mcp.mjs (review-support, review-publish, state, fence) owns the T3
# calls. Ships, and scouts on any other backend, never get a record and keep
# today's cleanup.
#
# Usage:
#   fm-t3-review.sh retain <task-id> --summary-file <file> --body-file <file>
#     Firstmate runs this for a finished T3 scout once it has read the whole
#     report and the captain-call completion gate (bin/fm-captain-hold.sh
#     verify) passes. It composes the one handoff note in a fixed order -
#     "Firstmate summary", "Full explanation", then a link to the report at
#     data/<id>/report.md by absolute path - writes it to
#     data/<id>/handoff-r<n>.md, records t3_review=pending with its revision
#     and stable request id, and only then publishes (as publish below).
#     The request id is derived from this home, the task, its spawn
#     generation, the report, and the note, so running retain again with the
#     same words is the same publication, and a revised report or handoff is
#     a new revision with a new note. Exit 4 without writing anything when
#     the task is not a T3 scout, the gate fails, the captain already closed
#     the review, or T3 cannot keep threads (then clean up as usual). An
#     unreachable T3 still records the handoff, which the watcher retries.
#   fm-t3-review.sh publish <task-id>
#     Publish a pending handoff: one passive note (no worker turn), the tag
#     "waiting for captain", automatic settling off, each proven by
#     read-back; then t3_review=waiting. A thread he archived or deleted
#     first records t3_review=closed instead (his close wins). A busy thread
#     exits 75 and stays pending; any other failure exits 1 and stays pending
#     for retry, never archived. A T3 too old to keep threads drops the
#     record, leaves the same cleanup wake as a close, and exits 4, so the
#     scout is cleaned up as usual.
#   fm-t3-review.sh reconcile
#     The watcher's minute pass over every retained review: a pending one is
#     published; a waiting one whose thread now reads archived or deleted is
#     recorded closed, and leaves one wake for firstmate in
#     state/t3-review/<id>.closed; a closed one he has reopened goes back to
#     waiting (or pending, if it was never published). A thread T3 cannot
#     read changes nothing. A record whose lock is held (cleanup is running)
#     is skipped until the next pass. Never revives, steers, or archives.
#   fm-t3-review.sh check-close <task-id>
#     bin/fm-teardown.sh runs this, holding the task's meta lock
#     (FM_T3_REVIEW_META_LOCK_HELD=1), before any destructive step: exit 0
#     when the thread reads deleted, or archived on a T3 that can fence it
#     (recorded closed either way); exit 1 while it is still open, or when
#     this T3 can never fence it; exit 3 when T3 cannot be read, which never
#     counts as closed.
#
# Record fields (state/<id>.meta): t3_review (pending|waiting|closed),
# t3_review_target (the thread), t3_review_revision, t3_review_request (the
# note's stable request id), t3_review_message (the published note's id).
#
# Exit: 0 success; 1 failure (a line on stdout or stderr says which); 2 usage;
# 3 T3 unreadable (check-close); 4 not retained (retain, publish); 75 busy
# (publish). Bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ALERTS="$STATE/t3-review"

usage() {
  sed -n '11,49p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
VERB=$1
shift

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-t3-review-lib.sh
. "$SCRIPT_DIR/fm-t3-review-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-review.XXXXXX") || { echo "t3-review: no temporary directory" >&2; exit 1; }
LOCK_HELD=
release() {
  [ -z "$LOCK_HELD" ] || fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=
}
trap 'release; rm -rf -- "$WORK"' EXIT

die() {
  echo "t3-review: $*" >&2
  exit 1
}

sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# lock <id> [try]: the task's meta lock, unless the caller already holds it.
lock() {
  local path
  [ "${FM_T3_REVIEW_META_LOCK_HELD:-0}" != 1 ] || return 0
  path=$(fm_meta_lock_path "$STATE/$1.meta") || return 1
  if [ "${2:-}" = try ]; then
    fm_lock_try_acquire "$path" || return 1
  else
    fm_lock_acquire_wait_max "$path" 30 || return 1
  fi
  LOCK_HELD=$path
}

# set_fields <meta> <key=value>...: rewrite the record with each key's new
# value (an empty value drops the key), atomically, keeping every other line.
set_fields() {
  local meta=$1 tmp line key kv drop
  shift
  tmp=$(mktemp "$STATE/.$(basename "$meta").review.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    drop=0
    for kv in "$@"; do
      key=${kv%%=*}
      case "$line" in "$key="*) drop=1 ;; esac
    done
    [ "$drop" = 1 ] || printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done < "$meta"
  for kv in "$@"; do
    [ -z "${kv#*=}" ] || printf '%s\n' "$kv" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

CLEARED_FIELDS=(t3_review= t3_review_target= t3_review_revision= t3_review_request= t3_review_message=)

mcp() {
  fm_backend_source t3code >/dev/null 2>&1 || { echo '{"ok":false,"error":{"code":"adapter","message":"the T3 adapter could not load"}}'; return 1; }
  fm_backend_t3code_mcp "$@" 2>"$WORK/mcp.err"
}

json() {  # <key> on stdin's JSON
  node -e 'let d; try { d = JSON.parse(require("fs").readFileSync(0, "utf8")); } catch { process.exit(1); }
const v = process.argv[1].split(".").reduce((o, k) => (o == null ? o : o[k]), d);
if (v === undefined || v === null) process.exit(1);
process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));' "$1"
}

refresh_cards() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-t3-crew-status.sh" sync >/dev/null 2>&1 </dev/null || true
}

leave_close_wake() {  # <id> [what happened]
  local reason="check: t3-review $1: ${2:-the captain closed the kept review thread}; clean it up with bin/fm-teardown.sh $1"
  mkdir -p "$ALERTS" && { printf '%s\n' "$reason" > "$ALERTS/$1.closed.tmp" && mv -f "$ALERTS/$1.closed.tmp" "$ALERTS/$1.closed"; } \
    || echo "t3-review: could not leave the close notice for $1" >&2
}

# publish_task <id>: see publish in the header. Prints one outcome line.
publish_task() {
  local id=$1 meta="$STATE/$1.meta" state thread rev request handoff out rc=0 outcome message
  lock "$id" || die "cannot lock $id's record"
  state=$(fm_t3_review_state "$meta")
  thread=$(fm_meta_get "$meta" t3_thread_id)
  rev=$(fm_meta_get "$meta" t3_review_revision)
  request=$(fm_meta_get "$meta" t3_review_request)
  release
  case "$state" in
    pending) ;;
    waiting) echo "t3-review: $id is published and waiting for the captain"; return 0 ;;
    closed) echo "t3-review: $id was closed by the captain; nothing to publish"; return 0 ;;
    *) echo "t3-review: $id keeps no review" >&2; return 4 ;;
  esac
  handoff="$DATA/$id/handoff-r$rev.md"
  [ -f "$handoff" ] || die "$id's handoff $handoff is missing; run retain again"
  out=$(mcp review-publish --thread "$thread" --note-file "$handoff" --request-id "$request" --tag "$FM_T3_REVIEW_TAG") || rc=$?
  outcome=$(printf '%s' "$out" | json outcome || true)
  if [ "$rc" = 4 ] && [ "$(printf '%s' "$out" | json error.code || true)" = review_unsupported ]; then
    lock "$id" || die "cannot lock $id's record"
    [ "$(fm_meta_get "$meta" t3_review_request)" != "$request" ] || set_fields "$meta" "${CLEARED_FIELDS[@]}" || die "cannot drop $id's review record"
    release
    leave_close_wake "$id" "this T3 cannot keep the review thread"
    echo "t3-review: this T3 cannot keep $id's thread ($(head -n 1 "$WORK/mcp.err")); it is cleaned up as usual" >&2
    return 4
  fi
  [ "$rc" = 0 ] || { echo "t3-review: $id's handoff is not published yet ($(head -n 1 "$WORK/mcp.err" | grep . || echo "exit $rc")); it stays kept and is retried" >&2; return 1; }
  lock "$id" || die "cannot lock $id's record"
  if [ "$(fm_meta_get "$meta" t3_review_request)" != "$request" ] || [ "$(fm_t3_review_state "$meta")" != pending ]; then
    release
    echo "t3-review: $id's record changed while publishing; the next pass reconciles it"
    return 0
  fi
  case "$outcome" in
    published)
      message=$(printf '%s' "$out" | json messageId)
      set_fields "$meta" t3_review=waiting "t3_review_message=$message" || die "cannot record $id's publication"
      release
      echo "t3-review: $id's handoff is published; the thread waits for the captain"
      ;;
    closed)
      set_fields "$meta" t3_review=closed || die "cannot record $id's close"
      release
      leave_close_wake "$id"
      echo "t3-review: the captain closed $id's thread before the handoff landed; clean it up with bin/fm-teardown.sh $id"
      ;;
    busy)
      release
      echo "t3-review: $id's thread is busy; its handoff waits for the turn to end"
      return 75
      ;;
    *)
      release
      die "T3 answered $id's publication with no outcome"
      ;;
  esac
}

cmd_retain() {
  local id=${1:-} summary='' body='' meta thread gen report abs_report note key request rev prev state out rc=0 supported link
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary-file) summary=${2:-}; shift 2 || usage ;;
      --body-file) body=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  valid_id "$id" && [ -f "$summary" ] && [ -f "$body" ] || usage
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "no task record at $meta"
  [ "$(fm_meta_get "$meta" kind)" = scout ] && [ "$(fm_backend_of_meta "$meta")" = t3code ] || {
    echo "t3-review: $id is not a T3 scout; only those keep their thread, so clean it up as usual" >&2
    return 4
  }
  thread=$(fm_meta_get "$meta" t3_thread_id)
  [ -n "$thread" ] || die "$id records no T3 thread"
  [ "$(fm_t3_review_state "$meta")" != closed ] || {
    echo "t3-review: the captain already closed $id's thread; it is not reopened for a new note" >&2
    return 4
  }
  report="$DATA/$id/report.md"
  [ -f "$report" ] || { echo "t3-review: $id has no report at $report" >&2; return 4; }
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-captain-hold.sh" verify "$id" >/dev/null 2>"$WORK/verify.err" || {
    echo "t3-review: $id has not passed the captain-call completion gate: $(head -n 1 "$WORK/verify.err")" >&2
    return 4
  }
  out=$(mcp review-support) || rc=$?
  if [ "$rc" = 0 ]; then
    supported=$(printf '%s' "$out" | json supported || true)
    if [ "$supported" != true ]; then
      echo "t3-review: this T3 cannot keep $id's thread (it lacks $(printf '%s' "$out" | json missing || echo '?')); clean it up as usual" >&2
      return 4
    fi
  else
    echo "t3-review: T3 could not be asked whether it keeps threads ($(head -n 1 "$WORK/mcp.err")); the handoff is recorded and retried" >&2
  fi
  [ -s "$summary" ] && [ -s "$body" ] || die "the summary and the body must both hold text"
  abs_report="$(cd "$(dirname "$report")" && pwd -P)/report.md"
  case "$abs_report" in *' '*) link="<$abs_report>" ;; *) link=$abs_report ;; esac
  note="$WORK/note.md"
  {
    printf '**Firstmate summary**\n\n'
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$summary"
    printf '\n**Full explanation**\n\n'
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$body"
    printf '\n[Full report (Markdown)](%s)\n' "$link"
  } > "$note" || die "cannot compose the handoff"
  [ "$(wc -c < "$note" | tr -d ' ')" -le 120000 ] || die "the handoff is longer than the 120000 characters a T3 note holds"
  gen=$(fm_meta_get "$meta" spawn_gen | sha | cut -c1-8)
  key=$( { cat "$note"; sha < "$report"; } | sha | cut -c1-12)
  request="fm-review-$(printf '%s' "$FM_HOME" | sha | cut -c1-8)-$id-$gen-$key"
  [ "${#request}" -le 256 ] || die "the task id is too long for a T3 note request id"
  lock "$id" || die "cannot lock $id's record"
  state=$(fm_t3_review_state "$meta")
  [ "$state" != closed ] || { release; echo "t3-review: the captain closed $id's thread meanwhile" >&2; return 4; }
  if [ -n "$state" ] && [ "$(fm_meta_get "$meta" t3_review_request)" = "$request" ]; then
    release
  else
    prev=$(fm_meta_get "$meta" t3_review_revision)
    rev=$(( ${prev:-0} + 1 ))
    { mkdir -p "$DATA/$id" && cp -f -- "$note" "$DATA/$id/handoff-r$rev.md"; } || { release; die "cannot write $id's handoff"; }
    set_fields "$meta" t3_review=pending "t3_review_target=$thread" "t3_review_revision=$rev" \
      "t3_review_request=$request" t3_review_message= || { release; die "cannot record $id's handoff"; }
    release
    echo "t3-review: $id's handoff revision $rev is recorded; its thread and copy are kept until the captain closes the thread"
  fi
  rc=0
  publish_task "$id" || rc=$?
  refresh_cards
  return "$rc"
}

# reconcile_task <id>: one record of the minute pass.
reconcile_task() {
  local id=$1 meta="$STATE/$1.meta" state thread out exists archived next
  state=$(fm_t3_review_state "$meta")
  [ -n "$state" ] || return 0
  if [ "$state" = pending ]; then
    # Never wait on a record cleanup is holding; the next pass gets it.
    lock "$id" try || return 0
    release
    ( trap release EXIT; publish_task "$id" ) >/dev/null 2>&1 || true
    return 0
  fi
  thread=$(fm_meta_get "$meta" t3_thread_id)
  out=$(mcp state --thread "$thread") || return 0
  exists=$(printf '%s' "$out" | json exists) || return 0
  archived=$(printf '%s' "$out" | json archived || echo false)
  lock "$id" try || return 0
  [ "$(fm_t3_review_state "$meta")" = "$state" ] || { release; return 0; }
  if [ "$exists" = false ] || [ "$archived" = true ]; then
    if [ "$state" = waiting ]; then
      set_fields "$meta" t3_review=closed || { release; return 1; }
      release
      leave_close_wake "$id"
    fi
  elif [ "$state" = closed ]; then
    next=pending
    [ -z "$(fm_meta_get "$meta" t3_review_message)" ] || next=waiting
    set_fields "$meta" "t3_review=$next" || { release; return 1; }
    rm -f -- "$ALERTS/$id.closed"
  fi
  release
}

cmd_reconcile() {
  local meta id rc=0
  [ "$#" = 0 ] || usage
  [ -e "$CONFIG/t3code-token" ] || [ -L "$CONFIG/t3code-token" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ -n "$(fm_t3_review_state "$meta")" ] || continue
    reconcile_task "$id" || rc=1
  done
  return "$rc"
}

cmd_check_close() {
  local id=${1:-} meta out exists archived
  { [ "$#" = 1 ] && valid_id "$id"; } || usage
  meta="$STATE/$id.meta"
  [ -n "$(fm_t3_review_state "$meta")" ] || { echo "t3-review: $id keeps no review" >&2; return 1; }
  out=$(mcp state --thread "$(fm_meta_get "$meta" t3_thread_id)") || {
    echo "t3-review: T3 could not be read ($(head -n 1 "$WORK/mcp.err")), so $id's kept thread is not known to be closed" >&2
    return 3
  }
  exists=$(printf '%s' "$out" | json exists) || { echo "t3-review: T3 answered $id's thread read with no state" >&2; return 3; }
  archived=$(printf '%s' "$out" | json archived || echo false)
  if [ "$exists" = false ] || [ "$archived" = true ]; then
    lock "$id" || die "cannot lock $id's record"
    [ "$(fm_meta_get "$meta" t3_review)" = closed ] || set_fields "$meta" t3_review=closed || { release; die "cannot record $id's close"; }
    release
    rm -f -- "$ALERTS/$id.closed"
    # An archived thread is fenced before its copy goes back; a T3 that can
    # never fence is refused here, before cleanup records anything.
    if [ "$exists" != false ]; then
      out=$(mcp review-support) || { echo "t3-review: T3 could not be asked whether it can fence $id's thread ($(head -n 1 "$WORK/mcp.err"))" >&2; return 3; }
      [ "$(printf '%s' "$out" | json supported || true)" = true ] || {
        echo "t3-review: this T3 cannot fence $id's closed thread, so its copy cannot safely go back; update T3 and re-run cleanup" >&2
        return 1
      }
    fi
    return 0
  fi
  echo "t3-review: $id's thread is kept open for the captain; it is cleaned up once he archives or deletes it in T3" >&2
  return 1
}

case "$VERB" in
  retain) cmd_retain "$@" ;;
  publish)
    { [ "$#" = 1 ] && valid_id "$1"; } || usage
    rc=0
    publish_task "$1" || rc=$?
    refresh_cards
    exit "$rc"
    ;;
  reconcile) cmd_reconcile "$@" ;;
  check-close) cmd_check_close "$@" ;;
  *) usage ;;
esac
