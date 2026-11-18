#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the commit the task's newest ready report names,
# the last `done: ready in branch <branch> at <commit id>` line of
# state/<task-id>.status as bin/fm-dod-lib.sh reads it. A task with no ready
# report, or whose newest one names no commit on its branch, refuses with the
# line to write. Exactly the reported commit lands: later commits on the branch
# that no report names stay there, and the output says how many.
#
# Usage:
#   fm-merge-local.sh <task-id> [--expected-head <full-commit-id>]
#   fm-merge-local.sh -h | --help
#
# --expected-head names the commit the approver reviewed, one full lowercase hex
# id of 40 or 64 characters. The landing then refuses unless the newest report
# names that commit, or a rebase of it that fm_dod_local_rebase_matches proves
# carries exactly its changes; the refusal names the commits that differ. A task
# whose record does not say yolo=on lands on the captain's approval of one
# commit, so it requires the flag.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward. A diverged branch needs a
# rebase and a fresh ready report before landing, under bin/fm-dod-lib.sh's
# ready-report contract. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# A per-checkout lock in the project's Git directory serializes different
# tasks across the checks, checkout update, ref transaction, and rollback.
# tests/fm-merge-local.test.sh covers reported-commit landing, successive
# reports, refusals, the approved-commit check, and race refusals.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-t3-origin-lib.sh
. "$SCRIPT_DIR/fm-t3-origin-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

EXPECTED_HEAD=
case "$#:${1:-}:${2:-}" in
  1:-h:|1:--help:)
    usage
    exit 0
    ;;
  1:*:) ;;
  3:*:--expected-head)
    EXPECTED_HEAD=$3
    case "$EXPECTED_HEAD" in ''|*[!0-9a-f]*) EXPECTED_HEAD= ;; esac
    case ${#EXPECTED_HEAD} in
      40|64) ;;
      *)
        echo "error: --expected-head takes one full lowercase hex commit id" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "error: invalid local merge request" >&2
    exit 2
    ;;
esac
if ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
MERGE_PROJECT_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_PROJECT_LOCK" ] || fm_lock_release "$MERGE_PROJECT_LOCK" || true
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
MERGE_META_LOCK=$(fm_meta_lock_path "$META")
fm_lock_acquire_wait "$MERGE_META_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
branch_head() {
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}"
}
ready_line() {
  fm_dod_local_newest_ready "$STATE/$ID.status"
}
project_git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir) || {
  echo "error: cannot determine the project checkout's Git directory" >&2
  exit 1
}
MERGE_PROJECT_LOCK="$project_git_dir/fm-local-landing.lock"
fm_lock_acquire_wait "$MERGE_PROJECT_LOCK"
BRANCH_HEAD=$(branch_head) || { echo "error: branch $BRANCH is missing; refusing" >&2; exit 1; }
READY_LINE=$(ready_line) || {
  echo "error: task $ID has no ready report in its status log; report readiness before approval" >&2
  exit 1
}
# The commit that lands is the one this report names, never the branch tip.
MERGE_HEAD=$(fm_dod_local_ready_head "$PROJ" "$READY_LINE" "$BRANCH") || {
  echo "error: $MERGE_HEAD" >&2
  exit 1
}
if ! git -C "$PROJ" merge-base --is-ancestor "$MERGE_HEAD" "$BRANCH_HEAD" >/dev/null 2>&1; then
  echo "error: the newest ready report of task $ID names $MERGE_HEAD, which is not on branch $BRANCH; after a rebase or an amend, have the worker append a fresh ready report naming the branch's current commit" >&2
  exit 1
fi

DEFAULT=$(fm_dod_local_default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be a strict ancestor of the reported commit.
before=$(git -C "$PROJ" rev-parse "$DEFAULT")
if git -C "$PROJ" merge-base --is-ancestor "$MERGE_HEAD" "$before"; then
  echo "error: nothing to land: the newest ready report of task $ID names $MERGE_HEAD, which is already on $DEFAULT" >&2
  exit 1
fi
if ! git -C "$PROJ" merge-base --is-ancestor "$before" "$MERGE_HEAD"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT and report ready again, then retry." >&2
  exit 1
fi

hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
# The approver's commit, when named, must be what the newest report carries.
if [ -n "$EXPECTED_HEAD" ]; then
  if [ "$EXPECTED_HEAD" != "$MERGE_HEAD" ] \
    && ! rebase_diff=$(fm_dod_local_rebase_matches "$PROJ" "$EXPECTED_HEAD" "$MERGE_HEAD" "$before"); then
    echo "error: the newest ready report of task $ID names $MERGE_HEAD, which is not the approved $EXPECTED_HEAD and does not carry exactly its changes; refusing: $rebase_diff" >&2
    exit 1
  fi
elif [ "$YOLO" != on ]; then
  echo "error: task $ID lands on the captain's approval of one commit; pass --expected-head <full-commit-id> naming the commit he approved (the newest ready report names $MERGE_HEAD)" >&2
  exit 1
fi
# Recheck after the approval read. Git's ref transaction below verifies and
# locks the worker branch together with the default-branch update.
if [ "$(ready_line)" != "$READY_LINE" ] || [ "$(branch_head)" != "$BRANCH_HEAD" ]; then
  echo "error: the ready report or branch changed during approval check; refusing" >&2
  exit 1
fi
merge_status=0
# Stage the fast-forward with Git's two-tree checkout, which preserves local
# changes made since the clean-tree check and refuses obstructing files.
git -C "$PROJ" read-tree -m -u "$before" "$MERGE_HEAD" || exit $?
git -C "$PROJ" update-ref -m "merge $BRANCH: Fast-forward" --stdin >/dev/null <<EOF || merge_status=$?
start
verify refs/heads/$BRANCH $BRANCH_HEAD
update refs/heads/$DEFAULT $MERGE_HEAD $before
prepare
commit
EOF
if [ "$merge_status" -ne 0 ]; then
  # The transaction left main untouched. Undo only the staged fast-forward;
  # the two-tree checkout also protects any intervening local edits here.
  git -C "$PROJ" read-tree -m -u "$MERGE_HEAD" "$before" || {
    echo "error: local merge refused and checkout restoration failed in $PROJ" >&2
    exit 1
  }
fi
fm_lock_release "$MERGE_META_LOCK" || true
MERGE_META_LOCK=
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
later=$(git -C "$PROJ" rev-list --count "$MERGE_HEAD..$BRANCH_HEAD")
fm_lock_release "$MERGE_PROJECT_LOCK" || true
MERGE_PROJECT_LOCK=
# The latest landed origin, which a T3 restart names (bin/fm-t3-origin-lib.sh).
fm_t3_origin_landed_record "$STATE" "$ID"
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
[ "$later" = 0 ] \
  || echo "landed the reported commit $MERGE_HEAD; $BRANCH has $later later commit(s) that no ready report names, left on the branch"
