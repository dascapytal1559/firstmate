#!/usr/bin/env bash
# tests/fm-nm-agent-env.test.sh - bin/fm-nm-agent-env.sh, which starts a
# no-mistakes pipeline agent under the FirstMate task its run serves. Driven
# through its CLI from fixture run folders, against a fixture no-mistakes state
# database and fixture FirstMate homes; `env` stands in for the agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-nm-agent-env-tests)
trap 'fm_test_cleanup' EXIT
WRAP="$ROOT/bin/fm-nm-agent-env.sh"
NM="$TMP_ROOT/nm"
HOME_A="$TMP_ROOT/home-a"
SELF_HOME="$TMP_ROOT/self-home"

# The fixture: one no-mistakes home with two repositories - a project cloned
# into HOME_A's projects/ folder, and SELF_HOME, a home that is its own
# checkout - and a run folder per run.
mkdir -p "$NM/worktrees/repoa/01RUNA/sub" "$NM/worktrees/repoa/01RUNX" "$NM/worktrees/repos/01RUNS" \
  "$HOME_A/projects/demo" "$HOME_A/state" "$SELF_HOME/state"
sqlite3 "$NM/state.sqlite" "
create table repos (id text primary key, working_path text not null);
create table runs (id text primary key, repo_id text not null, branch text not null);
insert into repos values ('repoa', '$HOME_A/projects/demo'), ('repos', '$SELF_HOME');
insert into runs values ('01RUNA', 'repoa', 'fm/demo-task'), ('01RUNX', 'repoa', 'fm/nobody'), ('01RUNS', 'repos', 'fm/self-task');"
printf 'project=%s\nkind=ship\nbranch=fm/demo-task\n' "$HOME_A/projects/demo" > "$HOME_A/state/demo-task.meta"
printf 'project=%s\nkind=ship\nbranch=fm/other\n' "$HOME_A/projects/demo" > "$HOME_A/state/other-task.meta"
printf 'project=%s\nkind=ship\nbranch=fm/self-task\n' "$SELF_HOME" > "$SELF_HOME/state/self-task.meta"

# agent_env <folder> [env assignments...]: the FM_ variables the agent sees
# when the wrapper starts it in <folder> from the daemon's task-free
# environment, one per line, sorted.
agent_env() {
  local dir=$1
  shift
  (cd "$dir" && env -u FM_TASK_ID -u FM_HOME NM_HOME="$NM" "$@" "$WRAP" env) | grep -E '^FM_(TASK_ID|HOME)=' | sort
}

test_run_folder_names_its_task() {
  assert_equals "FM_HOME=$HOME_A
FM_TASK_ID=demo-task" "$(agent_env "$NM/worktrees/repoa/01RUNA")" "a project's run starts its agent under the task of that branch"
  assert_equals "FM_HOME=$HOME_A
FM_TASK_ID=demo-task" "$(agent_env "$NM/worktrees/repoa/01RUNA/sub")" "a folder inside the run counts too"
  assert_equals "FM_HOME=$SELF_HOME
FM_TASK_ID=self-task" "$(agent_env "$NM/worktrees/repos/01RUNS")" "a home that is its own checkout is found too"
  pass "fm-nm-agent-env: an agent started in a run folder carries the FirstMate task its run serves"
}

test_no_single_task_leaves_the_agent_alone() {
  assert_equals "" "$(agent_env "$NM/worktrees/repoa/01RUNX")" "a branch no task records names nothing"
  assert_equals "" "$(agent_env "$TMP_ROOT")" "a folder outside every run names nothing"
  printf 'project=%s\nkind=ship\nbranch=fm/demo-task\n' "$HOME_A/projects/demo" > "$HOME_A/state/twin-task.meta"
  assert_equals "" "$(agent_env "$NM/worktrees/repoa/01RUNA")" "two tasks on one branch name neither"
  rm -f "$HOME_A/state/twin-task.meta"
  assert_equals "" "$(cd "$NM/worktrees/repoa/01RUNA" && env -u FM_TASK_ID -u FM_HOME NM_HOME="$TMP_ROOT/missing" "$WRAP" env | grep -E '^FM_(TASK_ID|HOME)=')" \
    "a missing state database names nothing"
  assert_equals "FM_HOME=/kept
FM_TASK_ID=kept-task" "$(agent_env "$NM/worktrees/repoa/01RUNA" FM_TASK_ID=kept-task FM_HOME=/kept)" \
    "an agent that already carries a task keeps it"
  pass "fm-nm-agent-env: with no single task to name, the agent starts with its environment unchanged"
}

# shellcheck disable=SC2016  # $1, $2 and $x are the agent's own, never this shell's.
test_the_agent_runs_as_given() {
  local out rc=0
  out=$(cd "$NM/worktrees/repoa/01RUNA" && NM_HOME="$NM" "$WRAP" sh -c 'printf "%s|%s" "$1" "$2"; exit 7' sh 'two words' "\$x") || rc=$?
  expect_code 7 "$rc" "the agent's own exit status"
  assert_equals 'two words|$x' "$out" "arguments reach the agent untouched"
  rc=0
  "$WRAP" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no command is invalid use"
  pass "fm-nm-agent-env: the agent receives its arguments untouched and its exit status is the wrapper's"
}

fm_test_run \
  test_run_folder_names_its_task \
  test_no_single_task_leaves_the_agent_alone \
  test_the_agent_runs_as_given
