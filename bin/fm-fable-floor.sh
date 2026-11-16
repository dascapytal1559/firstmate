#!/usr/bin/env bash
# fm-fable-floor.sh - refuse a Fable worker launch on a Claude account that is
# at or below this home's opt-in quota floor.
#
# Usage:
#   fm-fable-floor.sh check --model <model> --backend <backend> [--root <dir>] [--account <label>]
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
#   - backend t3code: the provider instance config/t3code-instances names for
#     the claude harness, else the claude row of bin/fm-t3-mcp.mjs's HARNESSES
#     table, and that instance's login folder from T3's own provider settings
#     (<t3-home>/userdata/settings.json providerInstances.<id>.config.homePath,
#     where <t3-home> is the file's t3_home, else $T3CODE_HOME, else ~/.t3).
#     An empty homePath is the ordinary login, as T3's Claude driver resolves it
#     when its server inherits no CLAUDE_CONFIG_DIR. When config/t3code-token
#     records an environment id, <t3-home>/userdata/environment-id must match
#     it, so another T3 install's settings are never read as this server's.
#   - any other backend: --root, the Claude config directory the launch
#     exports (empty means the ordinary login, CLAUDE_CONFIG_DIR unset).
#     --account names it in messages, such as a config/claude-accounts entry.
# A login folder equal to ~/.claude is read as the ordinary login, because a
# set CLAUDE_CONFIG_DIR names a different Keychain entry.
#
# The read is one bounded
#   quota-axi --provider claude --json --no-credential-refresh --max-age 60s
# under that login (CLAUDE_CONFIG_DIR set, or unset for the ordinary login),
# with QUOTA_AXI_CLAUDE_PROFILES and QUOTA_AXI_SNAPSHOT removed so it reports
# that one account. It is read-only: it never refreshes or writes a
# credential, and never prompts. The snapshot is validated with
# fm_quota_json_valid and its claude row joined with FM_QUOTA_ROW_JQ.
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
  *) die "usage: fm-fable-floor.sh check --model <model> --backend <backend> [--root <dir>] [--account <label>]" ;;
esac

MODEL=''
BACKEND=''
ROOT=''
ROOT_SET=0
LABEL=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--backend|--root|--account)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --model) MODEL=$2 ;;
        --backend) BACKEND=$2 ;;
        --root) ROOT=$2; ROOT_SET=1 ;;
        --account) LABEL=$2 ;;
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
HOME_DIR=${HOME:?HOME is required}

# A literal leading ~ in a config value or T3 setting names the home folder.
expand_home() {  # <path>
  local tilde='~'
  case "$1" in
    "$tilde") printf '%s' "$HOME_DIR" ;;
    "$tilde/"*) printf '%s/%s' "$HOME_DIR" "${1#"$tilde/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- the account this launch uses --------------------------------------------
REMEDY=
if [ "$BACKEND" = t3code ]; then
  instance=
  if [ -f "$CONFIG/t3code-instances" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in claude=*) instance=${line#claude=} ;; esac
    done < "$CONFIG/t3code-instances"
  fi
  if [ -z "$instance" ]; then
    instance=$(node "$SCRIPT_DIR/fm-t3-mcp.mjs" harness --harness claude 2>/dev/null | jq -r '.instanceId // empty' 2>/dev/null) ||
      instance=
  fi
  [ -n "$instance" ] || uncertain "could not tell which T3 provider instance runs the claude harness"
  t3_home=$(expand_home "${T3_HOME_SETTING:-${T3CODE_HOME:-$HOME_DIR/.t3}}")
  settings="$t3_home/userdata/settings.json"
  token_env=
  [ ! -f "$CONFIG/t3code-token" ] || token_env=$(jq -r '.environment_id // empty' "$CONFIG/t3code-token" 2>/dev/null) || token_env=
  if [ -n "$token_env" ]; then
    settings_env=$(tr -d '[:space:]' < "$t3_home/userdata/environment-id" 2>/dev/null) || settings_env=
    [ "$settings_env" = "$token_env" ] ||
      uncertain "T3 settings at $t3_home belong to ${settings_env:-an unknown} T3 environment, not the signed-in server $token_env; set t3_home in config/fable-quota-floor"
  fi
  [ -r "$settings" ] || uncertain "cannot read T3 provider settings at $settings"
  instance_json=$(jq -c --arg id "$instance" '.providerInstances[$id] // empty' "$settings" 2>/dev/null) ||
    uncertain "cannot parse T3 provider settings at $settings"
  [ -n "$instance_json" ] || uncertain "T3 provider settings at $settings have no instance '$instance'"
  driver=$(printf '%s' "$instance_json" | jq -r '.driver // empty')
  [ "$driver" = claudeAgent ] || uncertain "T3 instance '$instance' runs driver '${driver:-none}', not claudeAgent"
  home_path=$(printf '%s' "$instance_json" | jq -r '.config.homePath // "" | sub("^\\s+"; "") | sub("\\s+$"; "")')
  ROOT=$(expand_home "$home_path")
  LABEL="T3 instance $instance"
  REMEDY="map claude to another instance in config/t3code-instances"
else
  [ "$ROOT_SET" = 1 ] || die "--root is required for backend $BACKEND (empty for the ordinary login)"
  [ -n "$LABEL" ] || LABEL=${ROOT:-ordinary}
  REMEDY="point the spawn at another account (--account <entry> from config/claude-accounts, or another config/claude-account pin)"
fi
# A trailing slash or the default folder by name is still the ordinary login.
ROOT=${ROOT%/}
[ "$ROOT" != "$HOME_DIR/.claude" ] || ROOT=
LABEL="$LABEL (${ROOT:-~/.claude, the ordinary login})"

# --- the read -----------------------------------------------------------------
command -v quota-axi >/dev/null 2>&1 || uncertain "quota-axi is not installed, so $LABEL was not measured"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-fable-floor.XXXXXX") || uncertain "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT
read_env=(env -u QUOTA_AXI_CLAUDE_PROFILES -u QUOTA_AXI_SNAPSHOT)
if [ -n "$ROOT" ]; then read_env+=(CLAUDE_CONFIG_DIR="$ROOT"); else read_env+=(-u CLAUDE_CONFIG_DIR); fi
# A nonzero exit that still prints a valid snapshot names the vendor's own
# state, such as a rate limit, which the row below reports.
fm_run_timed "$FM_FABLE_FLOOR_SECONDS" "${read_env[@]}" \
  quota-axi --provider claude --json --no-credential-refresh --max-age 60s \
  > "$WORK/snapshot.json" 2>/dev/null </dev/null || :
fm_quota_json_valid < "$WORK/snapshot.json" || uncertain "quota-axi could not measure $LABEL"

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
