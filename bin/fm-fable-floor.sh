#!/usr/bin/env bash
# fm-fable-floor.sh - refuse a Fable worker launch on a Claude account that is
# at or below this home's opt-in quota floor.
#
# Usage:
#   fm-fable-floor.sh check --model <model> --backend <backend> [--root <dir>] [--account <label>] [--instance <id>]
#
# bin/fm-spawn.sh runs this for every ship or scout launch before anything is
# leased or launched. docs/configuration.md "Fable quota floor" owns the
# config/fable-quota-floor schema and the operator contract; this header owns
# the mechanics.
#
# Opt-in: without config/fable-quota-floor, or for a model that is not
# claude-fable-*, it exits 0 having read nothing, so a home that did not opt in
# behaves exactly as before.
#
# The account measured is the one the launch actually uses:
#   - backend t3code: --instance, the provider instance this one launch was
#     given (fm-spawn --t3-instance, or the worker sizing pick), else
#     fm_claude_login_standing_instance, and that instance's login folder
#     from fm_claude_login_t3_root, where <t3-home> is
#     fm_claude_login_default_t3_home of the file's t3_home: the signed-in
#     server's own data folder unless t3_home or $T3CODE_HOME names one
#     (bin/fm-claude-login-lib.sh owns all three).
#   - any other backend: --root, the Claude config directory the launch
#     exports (empty means the ordinary login, CLAUDE_CONFIG_DIR unset).
#     --account names it in messages, such as a config/claude-accounts entry.
#
# The read is fm_claude_login_read with --max-age 60s, read-only. The snapshot
# is joined with FM_QUOTA_ROW_JQ.
# Window percentages come from the row's windows[] (five_hour, seven_day,
# model:fable), using percentRemaining, else 100 - percentUsed.
#
# Verdicts:
#   exit 0, no output        under every floor, or the check does not apply.
#   exit 0, `uncertain: <why>` on stdout
#                            the account could not be measured (no quota-axi,
#                            a failed or invalid read, a vendor rate limit, no
#                            claude row, no Fable or weekly window, unreadable
#                            T3 settings); the launch proceeds and the caller
#                            records the line.
#   exit 3, refusal on stderr a measured window at or below its floor, or
#                            quota-axi's exhausted_now runway on all_models or
#                            model:fable. The message names the account, each
#                            figure and floor, and the two ways forward.
#   exit 2                   a usage error or a malformed floor file, which is
#                            reported rather than checked around.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FLOOR_FILE="$CONFIG/fable-quota-floor"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-claude-login-lib.sh
. "$SCRIPT_DIR/fm-claude-login-lib.sh"

FM_FABLE_FLOOR_SECONDS=${FM_FABLE_FLOOR_SECONDS:-60}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
uncertain() { printf 'uncertain: %s\n' "$1" | tr -d '\r' | head -1; exit 0; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

case "${1-}" in
  check) shift ;;
  -h|--help|help) usage; exit 0 ;;
  *) die "usage: fm-fable-floor.sh check --model <model> --backend <backend> [--root <dir>] [--account <label>] [--instance <id>]" ;;
esac

MODEL=''
BACKEND=''
ROOT=''
ROOT_SET=0
LABEL=''
INSTANCE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--backend|--root|--account|--instance)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --model) MODEL=$2 ;;
        --backend) BACKEND=$2 ;;
        --root) ROOT=$2; ROOT_SET=1 ;;
        --account) LABEL=$2 ;;
        --instance) INSTANCE=$2 ;;
      esac
      shift 2
      ;;
    *) die "unexpected argument: $1" ;;
  esac
done

[ -f "$FLOOR_FILE" ] || exit 0
case "$MODEL" in claude-fable-*) ;; *) exit 0 ;; esac
[ -n "$BACKEND" ] || die "--backend is required"

# --- floor file ---------------------------------------------------------------
FLOOR_FABLE_WEEKLY=''
FLOOR_WEEKLY=''
FLOOR_FIVE_HOUR=''
T3_HOME_SETTING=''
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%%#*}
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$line" ] || continue
  case "$line" in *=*) ;; *) die "$FLOOR_FILE line $lineno is not key=value: $line" ;; esac
  key=$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//')
  value=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//')
  case "$key" in
    fable_weekly|weekly|five_hour)
      case "$value" in ''|*[!0-9]*) die "$FLOOR_FILE line $lineno: $key must be a whole percent from 0 to 100, not '$value'" ;; esac
      [ "$value" -le 100 ] || die "$FLOOR_FILE line $lineno: $key must be a whole percent from 0 to 100, not '$value'"
      case "$key" in
        fable_weekly) FLOOR_FABLE_WEEKLY=$value ;;
        weekly) FLOOR_WEEKLY=$value ;;
        five_hour) FLOOR_FIVE_HOUR=$value ;;
      esac
      ;;
    t3_home)
      [ -n "$value" ] || die "$FLOOR_FILE line $lineno: t3_home needs a directory"
      T3_HOME_SETTING=$value
      ;;
    *) die "$FLOOR_FILE line $lineno: unknown key '$key' (expected fable_weekly, weekly, five_hour, or t3_home)" ;;
  esac
done < "$FLOOR_FILE"
[ -n "$FLOOR_FABLE_WEEKLY$FLOOR_WEEKLY$FLOOR_FIVE_HOUR" ] ||
  die "$FLOOR_FILE sets no floor; set fable_weekly, weekly, or five_hour, or remove the file"

command -v jq >/dev/null 2>&1 || uncertain "jq is not installed, so the Fable quota floor could not be checked"
: "${HOME:?HOME is required}"

# --- the account this launch uses --------------------------------------------
REMEDY=
if [ "$BACKEND" = t3code ]; then
  instance=$INSTANCE
  [ -n "$instance" ] || instance=$(fm_claude_login_standing_instance "$CONFIG" "$SCRIPT_DIR/fm-t3-mcp.mjs")
  [ -n "$instance" ] || uncertain "could not tell which T3 provider instance runs the claude harness"
  t3_home=$(fm_claude_login_default_t3_home "$T3_HOME_SETTING" "$CONFIG")
  if ! fm_claude_login_t3_root "$CONFIG" "$t3_home" "$instance"; then
    case "$FM_CLAUDE_LOGIN_WHY" in
      *"not the signed-in server"*) uncertain "$FM_CLAUDE_LOGIN_WHY; set t3_home in config/fable-quota-floor" ;;
      *) uncertain "$FM_CLAUDE_LOGIN_WHY" ;;
    esac
  fi
  ROOT=$FM_CLAUDE_LOGIN_ROOT
  LABEL="T3 instance $instance"
  REMEDY="map claude to another instance in config/t3code-instances, or start on another instance with --t3-instance <id>"
else
  [ "$ROOT_SET" = 1 ] || die "--root is required for backend $BACKEND (empty for the ordinary login)"
  [ -n "$LABEL" ] || LABEL=${ROOT:-ordinary}
  REMEDY="point the spawn at another account (--account <entry> from config/claude-accounts, or another config/claude-account pin)"
fi
ROOT=$(fm_claude_login_normalize "$ROOT")
LABEL="$LABEL (${ROOT:-~/.claude, the ordinary login})"

# --- the read -----------------------------------------------------------------
command -v quota-axi >/dev/null 2>&1 || uncertain "quota-axi is not installed, so $LABEL was not measured"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-fable-floor.XXXXXX") || uncertain "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT
fm_claude_login_read "$ROOT" 60s "$FM_FABLE_FLOOR_SECONDS" "$WORK/snapshot.json" ||
  uncertain "quota-axi could not measure $LABEL"

verdict=$(jq -r \
  --arg fable_weekly "$FLOOR_FABLE_WEEKLY" --arg weekly "$FLOOR_WEEKLY" --arg five_hour "$FLOOR_FIVE_HOUR" "$FM_QUOTA_ROW_JQ"'
  def left($w):
    if ($w.percentRemaining | type) == "number" then $w.percentRemaining
    elif ($w.percentUsed | type) == "number" then 100 - $w.percentUsed
    else null end;
  def window($row; $id): ([$row.windows[]? | select(type == "object" and .id == $id)] | first) as $w |
    if $w == null then null else left($w) end;
  quota_row(.; "claude"; "") as $row |
  if $row == null then "uncertain\tno claude quota row"
  elif $row.quotaSemantics.status == "unknown" then
    "uncertain\tquota unknown\(if $row.state.status then " (\($row.state.status): \($row.state.error // "no reason given"))" else "" end)"
  else
    [ ($row.quotaSemantics.effectiveAvailability[]?
        | select((.scope == "all_models" or .scope == "model:fable") and .runway.status == "exhausted_now")
        | "\(if .scope == "model:fable" then "Fable" else "all-models" end) allowance exhausted now"),
      (if $fable_weekly != "" then window($row; "model:fable") as $v |
         if $v != null and $v <= ($fable_weekly | tonumber) then "Fable weekly \($v)% left (floor \($fable_weekly)%)" else empty end
       else empty end),
      (if $weekly != "" then window($row; "seven_day") as $v |
         if $v != null and $v <= ($weekly | tonumber) then "weekly \($v)% left (floor \($weekly)%)" else empty end
       else empty end),
      (if $five_hour != "" then window($row; "five_hour") as $v |
         if $v != null and $v <= ($five_hour | tonumber) then "5-hour window \($v)% left (floor \($five_hour)%)" else empty end
       else empty end)
    ] as $over |
    [ (if $fable_weekly != "" and window($row; "model:fable") == null then "no Fable weekly window" else empty end),
      (if $weekly != "" and window($row; "seven_day") == null then "no weekly window" else empty end)
    ] as $missing |
    if ($over | length) > 0 then "refuse\t\($over | unique | join("; "))"
    elif ($missing | length) > 0 then "uncertain\t\($missing | join(", ")) reported"
    else "ok\t" end
  end
' "$WORK/snapshot.json" 2>/dev/null) || uncertain "cannot read the quota-axi snapshot for $LABEL"
verdict=$(printf '%s' "$verdict" | tr -d '\r\n')
kind=${verdict%%$'\t'*}
detail=${verdict#*$'\t'}
case "$kind" in
  ok) exit 0 ;;
  uncertain) uncertain "$LABEL: $detail" ;;
  refuse)
    printf 'error: refusing to start a Fable worker (%s) on Claude account %s: %s. Either %s, or, with the captain'"'"'s word to start anyway, pass --fable-floor-override <reason> (docs/configuration.md "Fable quota floor").\n' \
      "$MODEL" "$LABEL" "$detail" "$REMEDY" >&2
    exit 3
    ;;
  *) uncertain "cannot read the quota-axi snapshot for $LABEL" ;;
esac
