#!/usr/bin/env bash
# fm-fleet-idle.sh - is any direct report of this home mid-turn right now?
#
# Usage: fm-fleet-idle.sh [-q]
#
# Exit 0 when no direct report is mid-turn (the fleet is idle), 1 when at
# least one is, and 2 on an error such as an unreadable state directory.
# Prints one line per direct report that keeps the fleet active, then a
# summary line; -q prints nothing. The exit codes match the condition
# contract of bin/fm-procevent-when.sh, so the usual use is as a watch
# condition: "do X when the fleet goes idle" (docs/configuration.md owns that
# pattern).
#
# A direct report is any task recorded in this home's state/<id>.meta. The
# main firstmate session has no task record, so it is never counted. A task
# is read from its live session and its own running processes only - never
# from its status log or a no-mistakes run - so the check stays cheap enough
# to run on every worker event:
#   - ship and scout: the endpoint is probed first where the backend can
#     answer that (tmux, herdr, rex, t3code); a missing or dead endpoint has
#     no session. Otherwise the semantic busy verdict from bin/fm-busy-lib.sh
#     decides: busy counts, and unknown or unreadable counts as active, so a
#     worker whose state cannot be read never lets the fleet read as idle.
#     A worker whose session reads idle or gone still counts while it has its
#     own work running: any process whose working directory is inside its
#     recorded worktree, such as a background test run, a dev server, or a
#     run it started, other than the agent itself, the agent's process
#     group, and the agent's parents (such as a tmux pane's shell). Once the
#     endpoint reads dead, the pane's own shells (its root shell and the
#     shells in its foreground, as tmux, herdr, or rex report them) are not
#     counted either, so the prompt left behind by an exited agent does not
#     keep its worker active. So a paused wait with nothing running (captain
#     feedback, a PR maintainer) reads idle, and a paused wait on the
#     worker's own background job does not. A detached job the worker started
#     with bin/fm-job.sh is the exception: its runner and every process under
#     it are left out while the runner is the recorded live process and its
#     parent is init (or a systemd user manager), which proves it is no longer
#     a descendant of the agent or the app hosting it, so restarting that app
#     cannot stop it. A worker waiting only on such a job reads idle, and a job
#     whose runner is still inside the agent's tree counts as before. The
#     process listing comes from
#     /proc where it exists, else lsof;
#     when neither can list working directories this exits 2 rather than
#     guess.
#   - secondmate: an idle secondmate pane is its healthy waiting state, so
#     only an exact busy verdict counts, the same rule the watcher uses for a
#     secondmate's active turn. A remote secondmate cannot be read locally
#     and does not count. A secondmate's own workers live in its home and are
#     not read from here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

QUIET=0
case "${1-}" in
  -q) QUIET=1; shift ;;
  -h|--help|help) sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ "$#" -eq 0 ] || { printf 'error: unexpected argument: %s\n' "$1" >&2; exit 2; }

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }

[ -d "$STATE" ] || { printf 'error: state directory is unavailable: %s\n' "$STATE" >&2; exit 2; }

# task_verdict <meta> <id>: print "active <why>" or "idle <why>".
task_verdict() {
  local meta=$1 id=$2 kind backend target harness agent tail40 verdict
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" = secondmate ] && [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    printf 'idle remote secondmate, not read locally'
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    [ "$kind" = secondmate ] && { printf 'idle secondmate has no endpoint'; return 0; }
    printf 'active no endpoint recorded'
    return 0
  fi
  case "$backend" in
    tmux|herdr|rex|t3code)
      agent=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent=unreadable
      case "$agent" in
        missing|dead) printf 'idle endpoint %s' "$agent"; return 0 ;;
        alive) ;;
        *)
          [ "$kind" = secondmate ] && { printf 'idle secondmate endpoint %s' "${agent:-unreadable}"; return 0; }
          printf 'active endpoint %s' "${agent:-unreadable}"
          return 0
          ;;
      esac
      ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 "fm-$id" 2>/dev/null) || tail40=''
  verdict=$(fm_busy_classify "$backend" "$target" "$harness" "$id" "$STATE" "$tail40" 2>/dev/null) \
    || verdict='unknown classify-failed'
  [ -n "$verdict" ] || verdict='unknown classify-failed'
  case "${verdict%% *}" in
    busy) printf 'active busy (%s)' "${verdict#* }" ;;
    idle) printf 'idle (%s)' "${verdict#* }" ;;
    dead) printf 'idle endpoint gone' ;;
    *)
      if [ "$kind" = secondmate ]; then
        printf 'idle secondmate %s' "$verdict"
      else
        printf 'active state unreadable (%s)' "$verdict"
      fi
      ;;
  esac
}

# pane_pids <meta>: print the pids of a dead endpoint's pane, one per line:
# its root shell and its foreground processes, as its backend reports them.
# Prints nothing where the backend has no pane or the read fails.
pane_pids() {
  local meta=$1 backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_source "$backend" 2>/dev/null || return 0
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null
      fm_backend_tmux_foreground_pids "$target"
      ;;
    herdr)
      fm_backend_herdr_parse_target "$target" || return 0
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
        | jq -r '.result.process_info | .shell_pid, .foreground_processes[]?.pid | numbers' 2>/dev/null
      ;;
    rex)
      fm_backend_rex_process_chain "$target" 2>/dev/null || return 0
      printf '%s\n' "$FM_BACKEND_REX_CHAIN" | cut -f2
      ;;
  esac
  return 0
}

# cwd_table: print "<pid><TAB><cwd>" for every process this user can see,
# from /proc where it exists, else lsof. Returns 1 when neither can list
# working directories.
cwd_table() {
  if [ -d /proc/self ] && [ -L /proc/self/cwd ]; then
    find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%h\t%l\n' 2>/dev/null \
      | sed 's#^/proc/##'
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -w -a -d cwd -Fpn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { printf "%s\t%s\n", pid, substr($0, 2) }
  '
}

# running_work <worktrees-file> [pane-pids] [job-runner-pids]: for each
# "<id><TAB><worktree>" line, print "<id><TAB><pid> <command>" for the first
# process working inside that worktree that is not the agent, in the agent's
# process group, one of the agent's parents, a shell among the space-separated
# pane-pids of dead endpoints, or a detached job: a process at or under one of
# the space-separated job-runner-pids whose runner's parent is init or a
# systemd user manager. Returns 2 when processes cannot be listed.
running_work() {
  local wts=$1 panes=" ${2-} " runners=${3-} tmp candidates agents agent_groups skip_pids id pid ppid pgid comm
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-idle.XXXXXX") || return 2
  if ! LC_ALL=C ps -axo pid=,ppid=,pgid=,comm= > "$tmp/ps" 2>/dev/null \
    || ! cwd_table > "$tmp/cwd" || [ ! -s "$tmp/cwd" ]; then
    rm -rf "$tmp"
    return 2
  fi
  # Processes whose working directory is a worktree or inside one.
  candidates=$(awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] { wt[$1] = $2; next }
    FILENAME == ARGV[2] {
      split($0, f, " "); p = f[1]; pp[p] = f[2]; pg[p] = f[3]
      c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", c); cm[p] = c; next
    }
    {
      for (id in wt) {
        w = wt[id]
        if (($2 == w || index($2, w "/") == 1) && ($1 in pp))
          print id, $1, pp[$1], pg[$1], cm[$1]
      }
    }
  ' "$wts" "$tmp/ps" "$tmp/cwd")
  # This check's own process tree (the watch runner that started it, and its
  # listing commands) is never a worker's running work, wherever it started.
  agents=" $$"
  skip_pids=''
  agent_groups=" $(awk -v p="$$" '$1 == p { print $3 }' "$tmp/ps")"
  while IFS=$'\t' read -r id pid ppid pgid comm; do
    [ -n "$pid" ] || continue
    case "$(fm_agent_process_classify_name "$comm")" in
      agent)
        agents="$agents $pid"
        agent_groups="$agent_groups $pgid"
        ;;
      shell) case "$panes" in *" $pid "*) skip_pids="$skip_pids $pid" ;; esac ;;
    esac
  done <<EOF
$candidates
EOF
  printf '%s\n' "$candidates" | awk -F '\t' -v agents="$agents" -v groups="$agent_groups" -v panes="$skip_pids" -v runners="$runners" '
    FILENAME == ARGV[1] {
      split($0, f, " "); parent[f[1]] = f[2]
      c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", c); comm[f[1]] = c
      next
    }
    FNR == 1 {
      n = split(runners, r, " ")
      for (i = 1; i <= n; i++) {
        pp = parent[r[i]]
        if (pp == 1 || comm[pp] ~ /(^|\/)systemd$/) detached[r[i]] = 1
      }
      n = split(panes, s, " ")
      for (i = 1; i <= n; i++) skip[s[i]] = 1
      n = split(agents, a, " ")
      for (i = 1; i <= n; i++) {
        p = a[i]
        for (hop = 0; p != "" && p > 1 && hop < 64; hop++) { skip[p] = 1; p = parent[p] }
      }
      n = split(groups, g, " ")
      for (i = 1; i <= n; i++) group[g[i]] = 1
    }
    $2 == "" || ($2 in skip) || ($4 in group) || ($1 in seen) { next }
    {
      p = $2
      for (hop = 0; p != "" && p > 1 && hop < 64; hop++) {
        if (p in detached) next
        p = parent[p]
      }
      seen[$1] = 1; printf "%s\t%s %s\n", $1, $2, $5
    }
  ' "$tmp/ps" -
  rm -rf "$tmp"
  return 0
}

active=0
total=0
idle_worktrees=''
dead_panes=''
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  total=$((total + 1))
  v=$(task_verdict "$meta" "$id")
  case "$v" in
    active\ *) active=$((active + 1)); say "active: $id - ${v#active }"; continue ;;
  esac
  # A ship or scout whose session is idle or gone may still have its own work
  # running; secondmates keep their session-only rule.
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  wt=$(cd "$wt" 2>/dev/null && pwd -P) || continue
  idle_worktrees="$idle_worktrees$id"$'\t'"$wt"$'\n'
  [ "$v" != "idle endpoint dead" ] || dead_panes="$dead_panes $(pane_pids "$meta" | tr '\n' ' ')"
done

if [ -n "$idle_worktrees" ]; then
  wts_file=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-idle-wts.XXXXXX") || { printf 'error: cannot stage the worktree list\n' >&2; exit 2; }
  printf '%s' "$idle_worktrees" > "$wts_file"
  job_runners=''
  if compgen -G "$STATE/*.jobs/*/record" >/dev/null; then
    job_runners=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-job.sh" live 2>/dev/null | cut -f2 | tr '\n' ' ')
  fi
  if ! running=$(running_work "$wts_file" "$dead_panes" "$job_runners"); then
    rm -f "$wts_file"
    printf 'error: cannot list running processes and their working directories (needs /proc or lsof)\n' >&2
    exit 2
  fi
  rm -f "$wts_file"
  while IFS=$'\t' read -r id what; do
    [ -n "$id" ] || continue
    active=$((active + 1))
    say "active: $id - its own work is still running (pid $what)"
  done <<EOF
$running
EOF
fi

if [ "$active" -eq 0 ]; then
  say "idle: no direct report mid-turn ($total recorded)"
  exit 0
fi
say "busy: $active of $total direct reports mid-turn"
exit 1
