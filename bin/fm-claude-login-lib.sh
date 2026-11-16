#!/usr/bin/env bash
# fm-claude-login-lib.sh - which Claude login folder a launch uses, and one
# read-only quota-axi snapshot of that login.
#
# Sourced by bin/fm-fable-floor.sh and bin/fm-size.sh, so the account a quota
# check measures is resolved and read exactly one way. The caller sources
# bin/fm-timeout-lib.sh and bin/fm-quota-axi-lib.sh first.
#
# fm_claude_login_standing_instance <config-dir> <helper>
#   The T3 provider instance a claude launch runs on when no per-spawn
#   instance is named: the claude= line of <config-dir>/t3code-instances (the
#   last one wins), else the claude row of <helper> (bin/fm-t3-mcp.mjs)'s
#   HARNESSES table. Prints nothing when neither answers.
#
# fm_claude_login_t3_root <config-dir> <t3-home> <instance>
#   That instance's login folder from T3's own provider settings
#   (<t3-home>/userdata/settings.json providerInstances.<id>.config.homePath,
#   trimmed, a leading ~ expanded). An empty homePath is the ordinary login,
#   as T3's Claude driver resolves it when its server inherits no
#   CLAUDE_CONFIG_DIR. When <config-dir>/t3code-token records an environment
#   id, <t3-home>/userdata/environment-id must match it, so another T3
#   install's settings are never read as this server's. On success sets
#   FM_CLAUDE_LOGIN_ROOT (normalized, empty for the ordinary login) and
#   returns 0; otherwise sets FM_CLAUDE_LOGIN_WHY to one line and returns 1.
#
# fm_claude_login_default_t3_home <setting> [config-dir]
#   <setting> when non-empty, else $T3CODE_HOME, else the T3 data folder of
#   the signed-in server: the first of ~/.t3 and ~/.t3-* whose
#   userdata/environment-id matches <config-dir>/t3code-token's
#   environment_id (a fork keeps its own folder, such as ~/.t3-fork), else
#   ~/.t3; ~ is expanded.
#
# fm_claude_login_normalize <root>
#   A trailing slash dropped, and ~/.claude by name read as the ordinary login
#   (empty), because a set CLAUDE_CONFIG_DIR names a different Keychain entry.
#
# fm_claude_login_read <root> <max-age> <seconds> <out-file>
#   One bounded
#     quota-axi --provider claude --json --no-credential-refresh --max-age <max-age>
#   under that login (CLAUDE_CONFIG_DIR set, or unset for the ordinary login),
#   with QUOTA_AXI_CLAUDE_PROFILES and QUOTA_AXI_SNAPSHOT removed so it reports
#   that one account. It never refreshes or writes a credential and never
#   prompts; --max-age reuses quota-axi's own cache so repeated reads do not
#   hit the vendor's rate limit. Returns 0 when <out-file> holds a valid
#   snapshot (a nonzero quota-axi exit that still prints one names the
#   vendor's own state, such as a rate limit), 1 otherwise.

# fm_claude_login_expand_home <path>
fm_claude_login_expand_home() {
  local tilde='~' home=${HOME:-}
  case "$1" in
    "$tilde") printf '%s' "$home" ;;
    "$tilde/"*) printf '%s/%s' "$home" "${1#"$tilde/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_claude_login_default_t3_home() {  # <setting> [config-dir]
  local token_env dir
  if [ -n "${1:-}" ] || [ -n "${T3CODE_HOME:-}" ] || [ -z "${2:-}" ] || [ ! -f "$2/t3code-token" ]; then
    fm_claude_login_expand_home "${1:-${T3CODE_HOME:-${HOME:-}/.t3}}"
    return 0
  fi
  token_env=$(jq -r '.environment_id // empty' "$2/t3code-token" 2>/dev/null) || token_env=
  if [ -n "$token_env" ]; then
    for dir in "${HOME:-}/.t3" "${HOME:-}"/.t3-*; do
      [ -f "$dir/userdata/environment-id" ] || continue
      [ "$(tr -d '[:space:]' < "$dir/userdata/environment-id" 2>/dev/null)" = "$token_env" ] || continue
      printf '%s' "$dir"
      return 0
    done
  fi
  printf '%s' "${HOME:-}/.t3"
}

fm_claude_login_normalize() {
  local root=${1%/}
  [ "$root" != "${HOME:-}/.claude" ] || root=
  printf '%s' "$root"
}

fm_claude_login_standing_instance() {  # <config-dir> <helper>
  local config=$1 helper=$2 line instance=
  if [ -f "$config/t3code-instances" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in claude=*) instance=${line#claude=} ;; esac
    done < "$config/t3code-instances"
  fi
  if [ -z "$instance" ]; then
    instance=$(node "$helper" harness --harness claude 2>/dev/null | jq -r '.instanceId // empty' 2>/dev/null) ||
      instance=
  fi
  printf '%s' "$instance"
}

# shellcheck disable=SC2034  # FM_CLAUDE_LOGIN_ROOT and _WHY are the caller's outputs.
fm_claude_login_t3_root() {  # <config-dir> <t3-home> <instance>
  local config=$1 t3_home=$2 instance=$3 settings token_env settings_env instance_json driver home_path
  FM_CLAUDE_LOGIN_ROOT=
  FM_CLAUDE_LOGIN_WHY=
  settings="$t3_home/userdata/settings.json"
  token_env=
  [ ! -f "$config/t3code-token" ] || token_env=$(jq -r '.environment_id // empty' "$config/t3code-token" 2>/dev/null) || token_env=
  if [ -n "$token_env" ]; then
    settings_env=$(tr -d '[:space:]' < "$t3_home/userdata/environment-id" 2>/dev/null) || settings_env=
    if [ "$settings_env" != "$token_env" ]; then
      FM_CLAUDE_LOGIN_WHY="T3 settings at $t3_home belong to ${settings_env:-an unknown} T3 environment, not the signed-in server $token_env"
      return 1
    fi
  fi
  [ -r "$settings" ] || { FM_CLAUDE_LOGIN_WHY="cannot read T3 provider settings at $settings"; return 1; }
  instance_json=$(jq -c --arg id "$instance" '.providerInstances[$id] // empty' "$settings" 2>/dev/null) ||
    { FM_CLAUDE_LOGIN_WHY="cannot parse T3 provider settings at $settings"; return 1; }
  [ -n "$instance_json" ] || { FM_CLAUDE_LOGIN_WHY="T3 provider settings at $settings have no instance '$instance'"; return 1; }
  driver=$(printf '%s' "$instance_json" | jq -r '.driver // empty')
  [ "$driver" = claudeAgent ] || { FM_CLAUDE_LOGIN_WHY="T3 instance '$instance' runs driver '${driver:-none}', not claudeAgent"; return 1; }
  home_path=$(printf '%s' "$instance_json" | jq -r '.config.homePath // "" | sub("^\\s+"; "") | sub("\\s+$"; "")')
  FM_CLAUDE_LOGIN_ROOT=$(fm_claude_login_normalize "$(fm_claude_login_expand_home "$home_path")")
  return 0
}

fm_claude_login_read() {  # <root> <max-age> <seconds> <out-file>
  local root=$1 max_age=$2 seconds=$3 out=$4
  local -a read_env=(env -u QUOTA_AXI_CLAUDE_PROFILES -u QUOTA_AXI_SNAPSHOT)
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$root" ]; then read_env+=(CLAUDE_CONFIG_DIR="$root"); else read_env+=(-u CLAUDE_CONFIG_DIR); fi
  fm_run_timed "$seconds" "${read_env[@]}" \
    quota-axi --provider claude --json --no-credential-refresh --max-age "$max_age" \
    > "$out" 2>/dev/null </dev/null || :
  fm_quota_json_valid < "$out"
}
