#!/usr/bin/env bash
# fm-nm-agent-env.sh - start a no-mistakes pipeline agent under the FirstMate
# task its run serves, so the session-register hook T3 Code installs
# (docs/t3code-backend.md "Usage claims") registers that agent's session to the
# task instead of to a terminal.
#
# Usage:
#   fm-nm-agent-env.sh <command> [args...]
#
# The no-mistakes daemon starts each review and fix agent in its run's own
# folder, <no-mistakes home>/worktrees/<repo>/<run>, with the daemon's own
# environment, which names no task. A launcher ends with this script in front
# of the agent binary. In a run folder it reads that run's branch and
# repository from no-mistakes' state database, read only, and looks for the one
# FirstMate task recorded for them: a state/<task>.meta holding both
# project=<repository> and branch=<branch>, in the home that holds the
# repository - the repository itself (a home's own checkout) or the home whose
# projects/ folder holds it. When exactly one task matches, it exports
# FM_TASK_ID=<task> and FM_HOME=<that home> before running <command>.
#
# It never stands in the agent's way: with FM_TASK_ID already set, outside a
# run folder, or with no single matching task, <command> runs unchanged, and
# its exit status is the command's own. The no-mistakes home is NM_HOME, else
# ~/.no-mistakes.
set -u

if [ "$#" -lt 1 ]; then
  echo "usage: fm-nm-agent-env.sh <command> [args...]" >&2
  exit 2
fi
TAB=$(printf '\t')

# task_of_run_folder: print "<task> TAB <home>" for the current folder's run,
# or nothing.
task_of_run_folder() {
  local root here rel run row branch repo parent home meta task='' task_home='' n=0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  root=${NM_HOME:-${HOME:-}/.no-mistakes}
  root=$(cd "$root" 2>/dev/null && pwd -P) || return 0
  here=$(pwd -P 2>/dev/null) || return 0
  case "$here/" in "$root"/worktrees/*/*/) ;; *) return 0 ;; esac
  rel=${here#"$root"/worktrees/*/}
  run=${rel%%/*}
  case "$run" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  row=$(sqlite3 -cmd '.timeout 2000' -separator "$TAB" "file:$root/state.sqlite?mode=ro" \
    "select r.branch, p.working_path from runs r join repos p on p.id = r.repo_id where r.id = '$run'" 2>/dev/null) || return 0
  case "$row" in *"$TAB"/*) ;; *) return 0 ;; esac
  case "$row" in *"
"*) return 0 ;; esac
  branch=${row%%"$TAB"*}
  repo=${row#*"$TAB"}
  [ -n "$branch" ] || return 0
  parent=$(dirname "$repo")
  for home in "$repo" "$(dirname "$parent")"; do
    [ "$home" = "$repo" ] || [ "$(basename "$parent")" = projects ] || continue
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] || continue
      grep -Fqx -- "branch=$branch" "$meta" 2>/dev/null || continue
      grep -Fqx -- "project=$repo" "$meta" 2>/dev/null || continue
      n=$((n + 1))
      task=$(basename "$meta" .meta)
      task_home=$home
    done
  done
  [ "$n" -eq 1 ] || return 0
  printf '%s\t%s\n' "$task" "$task_home"
}

if [ -z "${FM_TASK_ID:-}" ]; then
  found=$(task_of_run_folder)
  if [ -n "$found" ]; then
    FM_TASK_ID=${found%%"$TAB"*}
    FM_HOME=${found#*"$TAB"}
    export FM_TASK_ID FM_HOME
  fi
fi
exec "$@"
