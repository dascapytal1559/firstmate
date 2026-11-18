#!/usr/bin/env bash
# Local-only landing lands exactly the commit the task's newest ready report
# names: through successive reports of one long-lived task, revisions, and
# rebases, never a commit no report named, and safely across races.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-local)
fm_git_identity fmtest fmtest@example.invalid

make_case() {  # <name> [<yolo: on|off>]
  local name=$1
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  STATUS="$HOME_DIR/state/local-task.status"
  AT=1790000000
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/fm-guard.sh"
  chmod +x "$HOME_DIR/bin/fm-guard.sh"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nyolo=%s\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\n' \
    "${2:-on}" "$PROJ" "$WT" > "$META"
  : > "$STATUS"
}

# The worker commits one more made-up file and prints the new commit.
commit() {  # <file>
  printf '%s\n' "$1" > "$WT/$1"
  git -C "$WT" add "$1"
  git -C "$WT" commit -q -m "$1"
  git -C "$WT" rev-parse HEAD
}

say() {  # <whole status line after the stamp>: the worker appends one status line
  AT=$((AT + 1))
  printf '%s\n' "${1%%:*} [at=$AT]:${1#*:}" >> "$STATUS"
}

# The worker's ready report, naming the commit its copy is on.
report() {  # [<words after the commit id>]
  say "done: ready in branch fm/local-task at $(git -C "$WT" rev-parse HEAD)${1:+$1}"
}

# What every reader of the task does with a done line: ask the gate.
accept_line() {  # <line>
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" "$1" \
    "$HOME_DIR/state" local-task "$META"
}

land() {  # [<task>] [--expected-head <commit>]
  local task=local-task
  case "${1:-}" in ''|--*) ;; *) task=$1; shift ;; esac
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "${MERGE_SCRIPT:-$ROOT/bin/fm-merge-local.sh}" "$task" "$@"
}

main_head() {
  git -C "$PROJ" rev-parse refs/heads/main
}

assert_refused() {  # [land arguments]
  local rc=0
  REFUSAL=$(land "$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "landing unexpectedly succeeded: $REFUSAL"
  [ "$(main_head)" = "$BASE" ] || fail "refusal moved main: $REFUSAL"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'refusal left a dirty checkout'
}

assert_landed() {  # <commit> <label> [land arguments]
  local want=$1 label=$2 out
  shift 2
  out=$(land "$@" 2>&1) || fail "$label: landing refused: $out"
  [ "$(main_head)" = "$want" ] || fail "$label: main is not the reported commit: $out"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "$label: landing left a dirty checkout"
  LANDING=$out
  BASE=$want
}

# Safety 1. Commits a worker makes after a landing, and never reports, do not
# land: the old report still names the landed commit, so there is nothing to land.
test_unreported_commits_after_a_landing_do_not_land() {
  make_case unreported
  report
  assert_landed "$X" 'stage 1'
  commit unreported >/dev/null
  accept_line "$(tail -1 "$STATUS")" || fail 'the landed report stopped being a valid report'
  assert_refused
  assert_contains "$REFUSAL" 'nothing to land' 'the refusal did not say the report is already landed'
  pass 'commits made after a landing and never reported do not land'
}

# Safety 2. A caller that builds its own done line (bin/fm-pr-check.sh does)
# cannot attach the worker's current commit to an old report: a line naming no
# commit is refused, and nothing is stored for the landing to pick up.
test_a_caller_built_done_line_cannot_attach_unreported_commits() {
  local before
  make_case caller-line
  report
  assert_landed "$X" 'stage 1'
  commit unreported >/dev/null
  before=$(cat "$META")
  accept_line 'done: PR https://example.invalid/pull/1' >/dev/null \
    && fail 'a done line naming no commit was accepted for a local-only task'
  [ "$(cat "$META")" = "$before" ] || fail 'a refused line changed the task record'
  assert_refused
  pass 'a done line built by another caller cannot attach unreported commits'
}

# Safety 3. The next stage of the same task lands on its own report.
test_next_stage_lands_on_its_own_report() {
  local y
  make_case next-stage
  report
  assert_landed "$X" 'stage 1'
  y=$(commit stage-2)
  report
  assert_landed "$y" 'stage 2'
  pass 'the next stage of one task lands on its own ready report'
}

# Safety 4. A worker that has already started its next stage in the same copy:
# exactly the reported commit lands, and the later commit stays on the branch
# until a report names it.
test_only_the_reported_commit_lands_when_the_worker_moved_on() {
  local y z
  make_case moved-on
  report
  assert_landed "$X" 'stage 1'
  y=$(commit stage-2)
  report
  say 'paused: stage 3 is being built in this working copy'
  z=$(commit stage-3-in-progress)
  printf 't3_thread_id=mcp:worker-1\n' >> "$META"
  assert_landed "$y" 'stage 2'
  assert_contains "$LANDING" "landed the reported commit $y" 'the output did not name the reported commit'
  assert_contains "$LANDING" '1 later commit(s)' 'the output did not count the commit left on the branch'
  [ "$(git -C "$PROJ" rev-parse refs/heads/fm/local-task)" = "$z" ] || fail 'landing moved the worker branch'
  [ ! -e "$PROJ/stage-3-in-progress" ] || fail 'the unreported commit reached the project checkout'
  assert_equals "$(printf 'local-task\t{"threadId":"mcp:worker-1"}')" "$(cut -f2- "$HOME_DIR/state/t3-landed-origin")" \
    'the landing keeps its task thread as the latest landed origin, for a T3 restart to name'
  report
  assert_landed "$z" 'stage 3'
  pass 'exactly the reported commit lands when the worker has moved on, and the rest lands once reported'
}

# Safety 5. Work revised before it landed lands when the worker reports again.
test_revised_work_lands_on_the_new_report() {
  local revised
  make_case revised
  report
  printf 'approved X, revised\n' > "$WT/approved.txt"
  git -C "$WT" commit -q -a --amend --no-edit
  revised=$(git -C "$WT" rev-parse HEAD)
  accept_line "$(tail -1 "$STATUS")" >/dev/null && fail 'a report naming an amended-away commit was accepted'
  assert_refused
  assert_contains "$REFUSAL" 'append a fresh ready report' 'the refusal did not ask for a fresh report'
  report
  assert_landed "$revised" 'revised work'
  [ "$(cat "$PROJ/approved.txt")" = 'approved X, revised' ] || fail 'landing did not use the revised content'
  pass 'work revised before landing lands on the report that names the revision'
}

# Safety 6a. A promoted scout's own done line names no commit, so it is never a
# ready report; the ship's later report lands.
test_promoted_scout_lands_on_its_ship_report() {
  local finished
  make_case promoted
  say 'done: report written at data/local-task/report.md'
  commit in-progress >/dev/null
  accept_line "$(tail -1 "$STATUS")" >/dev/null && fail "a scout's done line was accepted as a ready report"
  finished=$(commit finished)
  report
  assert_landed "$finished" 'the promoted ship'
  pass "a promoted scout's ship report lands, whatever its scout-time done line said"
}

# Safety 6b. A landing attempted while that scout line is the only done line
# lands nothing.
test_landing_on_a_scout_done_line_refuses() {
  make_case scout-line
  say 'done: report written at data/local-task/report.md'
  commit in-progress >/dev/null
  assert_refused
  assert_contains "$REFUSAL" 'ready in branch fm/local-task at <commit id>' 'the refusal did not give the line to write'
  pass "a landing attempted on a scout's done line lands nothing and says what to report"
}

# Safety 7. A question still open for the captain does not hide the report.
test_report_with_an_open_question_lands() {
  make_case open-question
  say 'needs-decision [key=q1]: a made-up question'
  report
  say 'paused: waiting to land'
  assert_landed "$X" 'the reported stage'
  pass 'a ready report lands while a question is open and after the worker wrote more'
}

# Safety 8. A report that does not name its commit at the one fixed place is
# refused with the line to write; the accepted spellings are checked beside it.
test_reports_that_name_no_commit_refuse() {
  local label line reason
  while IFS='|' read -r label line <&3; do
    [ -n "$label" ] || continue
    make_case "unnamed-$label"
    line=${line//@X@/$X}
    line=${line//@SHORT@/${X:0:6}}
    say "$line"
    reason=$(accept_line "$(tail -1 "$STATUS")") && fail "$label: the report was accepted"
    [ -n "$reason" ] || fail "$label: the gate refused without a reason"
    assert_refused
    case "$label" in
      old-form|no-report-words|prose-first|other-branch|too-short|expression)
        # shellcheck disable=SC2016 # The backticks are part of the line the refusal quotes.
        assert_contains "$REFUSAL" 'append `done [at=<epoch>]: ready in branch fm/local-task at <commit id>`' \
          "$label: the refusal did not give the exact line to write"
        if [ "$label" = other-branch ]; then
          assert_contains "$REFUSAL" "names branch fm/another-task, not the task's branch fm/local-task" \
            "$label: the refusal did not say the report names the wrong branch"
        else
          assert_not_contains "$REFUSAL" 'names branch' "$label: a report naming no commit was blamed on its branch"
        fi ;;
      *) assert_contains "$REFUSAL" 'not one commit in the project clone' "$label: the refusal did not explain the id" ;;
    esac
  done 3<<'CASES'
old-form|done: ready in branch fm/local-task
no-report-words|done: finished, committed and tested
prose-first|done: stage one ready in branch fm/local-task at @X@
other-branch|done: ready in branch fm/another-task at @X@
too-short|done: ready in branch fm/local-task at @SHORT@
expression|done: ready in branch fm/local-task at HEAD
unknown-id|done: ready in branch fm/local-task at 0123456789abcdef0123456789abcdef01234567
not-a-commit|done: ready in branch fm/local-task at 4b825dc642cb6eb9a060e54bf8d69288fbee4904
CASES
  make_case named
  for line in "done: ready in branch fm/local-task at $X" \
    "done: ready in branch fm/local-task at ${X:0:10}, rebased onto main" \
    "done [key=ready]: ready in branch fm/local-task at $X; all checks pass"; do
    accept_line "$line" || fail "an accepted spelling was refused: $line"
  done
  say "done: ready in branch fm/local-task at ${X:0:10} = the head I tested"
  assert_landed "$X" 'a report naming a short unique id'
  pass 'a report that names no usable commit refuses with the line to write, and the accepted spellings land'
}

# Safety 9. A report naming a commit that is not on the task's branch lands
# nothing: one no branch holds is not a ready report at all, and one that only
# another branch holds is refused at landing.
test_report_naming_a_commit_off_the_branch_refuses() {
  local stray
  make_case off-branch
  stray=$(printf 'stray\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$BASE")
  say "done: ready in branch fm/local-task at $stray"
  accept_line "$(tail -1 "$STATUS")" >/dev/null && fail 'a commit no branch holds was accepted'
  assert_refused
  assert_contains "$REFUSAL" 'no branch of the project clone holds' 'the refusal did not say the commit is on no branch'
  git -C "$PROJ" update-ref refs/heads/fm/elsewhere "$stray"
  assert_refused
  assert_contains "$REFUSAL" 'not on branch fm/local-task' 'the refusal did not name the task branch'
  pass 'a report naming a commit that is not on the task branch refuses'
}

# Safety 10. One report lands once.
test_a_landed_report_does_not_land_again() {
  make_case twice
  report
  assert_landed "$X" 'the first landing'
  assert_refused
  assert_contains "$REFUSAL" 'nothing to land' 'the second landing did not say why it refused'
  pass 'a report that already landed does not land again'
}

# Safety 11. Without yolo the landing is the captain's approval of one commit:
# the approver names it, and a newer report is not that approval.
test_an_approval_names_one_commit() {
  local z rc bad
  make_case approval off
  report
  assert_refused
  assert_contains "$REFUSAL" "--expected-head" 'the refusal did not ask for the approved commit'
  assert_contains "$REFUSAL" "$X" 'the refusal did not name the reported commit'
  for bad in "${X:0:12}" refs/heads/fm/local-task ''; do
    rc=0
    land --expected-head "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "--expected-head '$bad' exited $rc, not 2"
  done
  z=$(commit more)
  report
  assert_refused --expected-head "$X"
  assert_contains "$REFUSAL" "not the approved $X" 'the refusal did not name the approved commit'
  assert_contains "$REFUSAL" 'extra commit' 'the refusal did not name the commit beyond the approval'
  assert_landed "$z" 'the approved newer report' --expected-head "$z"
  pass 'without yolo the approved commit must be named, and a newer report is not that approval'
}

# Another task lands on main after X was approved, and the worker rebases X
# onto it, as its instructions say. A second approved commit, when asked for,
# lets reorder and squash cases exist.
approve_then_rebase() {  # <case> [two]
  make_case "$1" off
  if [ "${2:-}" = two ]; then
    X=$(commit approved2.txt)
  fi
  report
  printf 'other task\n' > "$PROJ/other.txt"
  git -C "$PROJ" add other.txt
  git -C "$PROJ" commit -q -m other
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$WT" rebase -q main || fail "$1: rebase failed"
  [ "$(git -C "$WT" rev-parse HEAD)" != "$X" ] || fail "$1: rebase kept the approved commit"
}

# Safety 12. The approved commit, rebased over another task's landing with the
# same changes, is still the approved work.
test_approved_work_lands_after_an_identical_rebase() {
  local rebased
  approve_then_rebase rebased
  git -C "$WT" commit -q --amend -m 'X, reworded'
  rebased=$(git -C "$WT" rev-parse HEAD)
  report
  assert_landed "$rebased" 'the rebased approved work' --expected-head "$X"
  [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'landing did not update the checkout'
  [ -e "$PROJ/other.txt" ] || fail 'landing lost the other task'
  pass 'approved work rebased with the same changes lands under the approval of the original commit'
}

test_approved_work_changed_by_a_rebase_refuses() {
  local variant expect
  for variant in extra amended whitespace merge reordered squashed; do
    case "$variant" in
      reordered|squashed) approve_then_rebase "rebased-$variant" two ;;
      merge) make_case "rebased-$variant" off
        report
        printf 'other task\n' > "$PROJ/other.txt"
        git -C "$PROJ" add other.txt
        git -C "$PROJ" commit -q -m other
        BASE=$(git -C "$PROJ" rev-parse HEAD)
        git -C "$WT" merge -q --no-edit main ;;
      *) approve_then_rebase "rebased-$variant" ;;
    esac
    case "$variant" in
      extra)
        commit unfinished.txt >/dev/null
        expect='extra commit' ;;
      amended)
        printf 'approved X, changed\n' > "$WT/approved.txt"
        git -C "$WT" commit -q -a --amend --no-edit
        expect='differs from approved' ;;
      whitespace)
        printf 'approved  X\n' > "$WT/approved.txt"
        git -C "$WT" commit -q -a --amend --no-edit
        expect='differs from approved' ;;
      merge) expect='merge commit' ;;
      reordered)
        git -C "$WT" reset -q --hard main
        git -C "$WT" cherry-pick "$X" >/dev/null
        git -C "$WT" cherry-pick "$X~1" >/dev/null
        expect='differs from approved' ;;
      squashed)
        git -C "$WT" reset -q --soft HEAD~2
        git -C "$WT" commit -q -m squashed
        expect='missing approved commit' ;;
    esac
    report
    assert_refused --expected-head "$X"
    assert_contains "$REFUSAL" 'does not carry exactly its changes' "$variant: the refusal did not explain itself"
    assert_contains "$REFUSAL" "$expect" "$variant: the refusal did not name the differing commits"
  done
  pass 'approved work rebased with an extra, amended, whitespace-amended, merge, reordered, or squashed commit refuses'
}

# The landing identity lives in the report, so reading a task records nothing:
# the task record and the state folder are byte-for-byte what they were, a
# captured copy of the record answers the same, and a caller holding the task's
# locks is not made to wait.
test_accepting_a_report_writes_nothing() {
  local before listing captured
  make_case read-only
  report
  (
    local FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    local lock control="$HOME_DIR/state/.control-local-task.lock"
    lock=$(fm_meta_lock_path "$META") || exit 1
    fm_lock_try_acquire "$control" || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"; fm_lock_release "$control"' EXIT
    accept_line "$(tail -1 "$STATUS")" || exit 1
  ) || fail "the report was not accepted under a caller's locks"
  before=$(cat "$META")
  listing=$(ls -A "$HOME_DIR/state")
  captured="$CASE/captured.meta"
  cp "$META" "$captured"
  accept_line "$(tail -1 "$STATUS")" || fail 'the report was refused'
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" "$(tail -1 "$STATUS")" \
    "$HOME_DIR/state" local-task "$captured" || fail 'a captured record refused the report'
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" "$(tail -1 "$STATUS")" \
    || fail 'the report was refused without a task record'
  accept_line 'done: ready in branch fm/local-task' >/dev/null && fail 'an unnamed report was accepted'
  [ "$(cat "$META")" = "$before" ] || fail 'accepting a report changed the task record'
  [ "$(ls -A "$HOME_DIR/state")" = "$listing" ] || fail 'accepting a report left files in the state folder'
  pass 'accepting a ready report writes nothing and waits on no lock'
}

# One long-lived worker's real day, as made-up fixtures: 24 landings from 29
# ready reports on one branch, with 12 landings by other tasks in between. Only
# the order of events is taken from that day: ordinary stages, a stage reworked
# while it was rebased and then stacked under the next one, stages reported on a
# base that another landing had just overtaken and rebased unchanged, two stages
# reported together, questions left open, and the worker writing on after a
# report. Every landing must take exactly the commit its report named, unaided.
OWNER_DAY='
other; other; other; other
stage; stage
say needs-decision; say needs-decision; stage
start; commit; report; say working; say paused; other; say working; rework; report; say paused; commit; report; say paused; land
start; commit; commit; report; land
stage; stage; stage; stage; stage; stage; stage; stage; stage
say paused; start; commit; other; other; say needs-decision; report; say working; rebase; report; say working; land
other; start; commit; report; say paused; land
stage; stage; stage; stage; stage
other; say needs-decision; say needs-decision; start; commit; report; other; rebase; report; land
other; stage
start; commit; other; report; say working; say working; rebase; commit; report; land
'

owner_step() {  # <op>
  case "$1" in
    other)
      OTHERS=$((OTHERS + 1))
      printf 'another task %s\n' "$OTHERS" > "$PROJ/other-$OTHERS.txt"
      git -C "$PROJ" add "other-$OTHERS.txt"
      git -C "$PROJ" commit -q -m "another task $OTHERS"
      BASE=$(main_head) ;;
    start|rebase) git -C "$WT" rebase -q main || fail "owner day: $1 failed" ;;
    commit)
      STAGES=$((STAGES + 1))
      commit "stage-$STAGES.txt" >/dev/null ;;
    rework)
      git -C "$WT" rebase -q main || fail 'owner day: rework rebase failed'
      printf 'reworked\n' >> "$WT/stage-$STAGES.txt"
      git -C "$WT" commit -q -a --amend --no-edit ;;
    report)
      REPORTS=$((REPORTS + 1))
      report "; stage report $REPORTS" ;;
    'say needs-decision')
      QUESTIONS=$((QUESTIONS + 1))
      say "needs-decision [key=q$QUESTIONS]: a made-up question" ;;
    'say '*) say "${1#say }: a made-up line" ;;
    land)
      LANDINGS=$((LANDINGS + 1))
      assert_landed "$(git -C "$WT" rev-parse HEAD)" "owner day, landing $LANDINGS"
      assert_not_contains "$LANDING" 'later commit(s)' "owner day, landing $LANDINGS left reported work behind" ;;
    stage) owner_step start; owner_step commit; owner_step report; owner_step land ;;
    *) fail "owner day: unknown step '$1'" ;;
  esac
}

test_a_long_lived_owner_lands_every_stage() {
  local row op rest
  make_case owner-day
  OTHERS=0 STAGES=0 REPORTS=0 QUESTIONS=0 LANDINGS=0
  report
  assert_landed "$X" 'owner day, the first commit'
  while IFS= read -r row <&3; do
    rest=$row
    while [ -n "$rest" ]; do
      op=${rest%%;*}
      case "$rest" in *';'*) rest=${rest#*;} ;; *) rest='' ;; esac
      op=${op#"${op%%[![:space:]]*}"}
      op=${op%"${op##*[![:space:]]}"}
      [ -z "$op" ] || owner_step "$op"
    done
  done 3<<EOF
$OWNER_DAY
EOF
  assert_equals '24 29 12' "$LANDINGS $REPORTS $OTHERS" 'the fixture lost the shape of the day it stands for'
  [ "$(git -C "$PROJ" rev-list --count main..fm/local-task)" = 0 ] || fail 'owner day ended with unlanded commits'
  pass 'a long-lived owner lands all 24 stages of a day unaided, each exactly as reported'
}

test_help_and_bad_requests() {
  local out rc bad
  make_case help
  out=$(bash "$ROOT/bin/fm-merge-local.sh" --help 2>&1) || fail "--help failed: $out"
  assert_contains "$out" '--expected-head' '--help did not describe the approved-commit flag'
  assert_not_contains "$out" 'no meta for task' '--help was read as a task id'
  for bad in '' 'local-task extra' 'local-task --expected-head' 'local-task --land-anything x'; do
    rc=0
    # shellcheck disable=SC2086 # The bad request is deliberately split into its words.
    FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      bash "$ROOT/bin/fm-merge-local.sh" $bad >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "request '$bad' exited $rc, not 2"
  done
  pass '--help prints the usage and a malformed request is refused before any task is read'
}

# A Git shim moves the branch inside the final ref-changing Git invocation.
# It is a scheduling seam only: every Git operation still uses the real binary.
test_change_after_hold_check_refuses() {
  local real_git out rc
  real_git=$(command -v git)
  make_case race-branch
  report
  git -C "$WT" commit -q --allow-empty -m Y
  Y=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" reset -q --hard "$X"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *' merge --ff-only '*|*' update-ref '*' --stdin')
    "$REAL_GIT" -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y" || exit $?
    printf 'moved\n' > "$RACE_MARKER"
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$CASE/fakebin/git"
  rc=0
  out=$(PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" RACE_MARKER="$CASE/moved" \
    RACE_PROJ="$PROJ" RACE_Y="$Y" land 2>&1) || rc=$?
  [ -f "$CASE/moved" ] || fail 'branch race was not exercised'
  [ "$(git -C "$PROJ" rev-parse refs/heads/fm/local-task)" = "$Y" ] || fail 'worker branch did not move'
  [ "$rc" -ne 0 ] || fail "branch race unexpectedly landed: $out"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'branch race moved main'
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'branch race left a dirty checkout'
  [ ! -e "$PROJ/approved.txt" ] || fail 'branch race left approved files behind'
  pass 'a branch move inside the final Git invocation refuses without changing main or its checkout'
}

test_diverged_default_refuses() {
  make_case diverged
  report
  git -C "$PROJ" commit -q --allow-empty -m diverged
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  assert_refused
  assert_contains "$REFUSAL" 'report ready again' 'the refusal did not ask for a rebase and a fresh report'
  [ ! -e "$PROJ/approved.txt" ] || fail 'refusal left approved files behind'
  pass 'a diverged default branch refuses without changing main or its checkout'
}

# The branch moves, or a newer ready report arrives, while the landing reads
# whether the task is still held for the captain.
test_change_during_approval_check_refuses() {
  local mode out rc
  for mode in branch report; do
    make_case "approval-$mode"
    report
    git -C "$WT" commit -q --allow-empty -m Y
    Y=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" reset -q --hard "$X"
    cp -R "$ROOT/bin" "$CASE/toolbin"
    cat > "$CASE/toolbin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_MODE" = branch ]; then
  git -C "$RACE_PROJ" update-ref refs/heads/fm/local-task "$RACE_Y"
else
  printf 'done [at=1790009999]: ready in branch fm/local-task at %s; reported again\n' "$RACE_X" >> "$RACE_STATUS"
fi
exit 3
SH
    rc=0
    out=$(MERGE_SCRIPT="$CASE/toolbin/fm-merge-local.sh" RACE_MODE="$mode" \
      RACE_PROJ="$PROJ" RACE_Y="$Y" RACE_X="$X" RACE_STATUS="$STATUS" land 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "approval race ($mode) succeeded: $out"
    assert_contains "$out" 'changed during approval check' "approval race ($mode) refused for another reason"
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail "approval race ($mode) moved main"
  done
  pass 'a branch move or a newer report during the hold read refuses without moving main'
}

test_two_tasks_cannot_undo_a_same_tree_landing() {
  local real_git real_sleep other first_pid second_pid first_rc=0 second_rc=0 i project_lock
  make_case same-tree
  report
  other=$(printf 'second task\n' | git -C "$PROJ" commit-tree "$X^{tree}" -p "$BASE")
  git -C "$PROJ" update-ref refs/heads/fm/other-task "$other"
  printf 'kind=ship\nmode=local-only\nyolo=on\nbranch=fm/other-task\nproject=%s\nspawn_gen=fixture-2\n' \
    "$PROJ" > "$HOME_DIR/state/other-task.meta"
  printf 'done [at=1790000001]: ready in branch fm/other-task at %s\n' "$other" > "$HOME_DIR/state/other-task.status"
  [ "$other" != "$X" ] || fail 'same-tree commits were not distinct'
  [ "$(git -C "$PROJ" rev-parse "$other^{tree}")" = "$(git -C "$PROJ" rev-parse "$X^{tree}")" ] \
    || fail 'the two reported commits have different trees'
  real_git=$(command -v git)
  real_sleep=$(command -v sleep)
  project_lock="$(git -C "$PROJ" rev-parse --absolute-git-dir)/fm-local-landing.lock"
  mkdir -p "$CASE/fakebin"
  cat > "$CASE/fakebin/git" <<'SH'
#!/usr/bin/env bash
wait_for() {
  local i=0
  while [ ! -f "$RACE_DIR/$1" ] && [ "$i" -lt 600 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$RACE_DIR/$1" ]
}
case "$*" in
  *' read-tree -m -u '*)
    if [ ! -f "$RACE_DIR/$RACE_ROLE.staged" ]; then
      : > "$RACE_DIR/$RACE_ROLE.ready"
      if [ "$RACE_ROLE" = first ]; then
        wait_for release-first || exit 90
      else
        wait_for first.staged || exit 91
      fi
      "$REAL_GIT" "$@" || exit $?
      : > "$RACE_DIR/$RACE_ROLE.staged"
      exit 0
    fi
    ;;
  *' update-ref '*' --stdin')
    if [ "$RACE_ROLE" = first ]; then
      if [ -f "$RACE_DIR/second.ready" ]; then
        wait_for second.staged || exit 92
      fi
    else
      wait_for first.updated || exit 93
    fi
    "$REAL_GIT" "$@" || exit $?
    : > "$RACE_DIR/$RACE_ROLE.updated"
    exit 0
    ;;
esac
exec "$REAL_GIT" "$@"
SH
  cat > "$CASE/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$RACE_ROLE" = second ] && [ -d "$RACE_PROJECT_LOCK" ] \
  && [ -d "$RACE_CONTROL_LOCK" ] && [ ! -f "$RACE_DIR/second.ready" ]; then
  : > "$RACE_DIR/second.waiting"
fi
exec "$REAL_SLEEP" "$@"
SH
  chmod +x "$CASE/fakebin/git" "$CASE/fakebin/sleep"
  (
    first_pid='' second_pid=''
    trap ': > "$CASE/release-first"; [ -z "$first_pid" ] || { kill "$first_pid" 2>/dev/null || true; wait "$first_pid" 2>/dev/null || true; }; [ -z "$second_pid" ] || { kill "$second_pid" 2>/dev/null || true; wait "$second_pid" 2>/dev/null || true; }' EXIT
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=first \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land > "$CASE/first.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    first_pid=$!
    i=0
    while [ ! -f "$CASE/first.ready" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    [ -f "$CASE/first.ready" ] || fail 'first landing never reached its checkout update'
    PATH="$CASE/fakebin:$PATH" REAL_GIT="$real_git" REAL_SLEEP="$real_sleep" RACE_DIR="$CASE" RACE_ROLE=second \
      RACE_PROJECT_LOCK="$project_lock" RACE_CONTROL_LOCK="$HOME_DIR/state/.control-other-task.lock" \
      land other-task > "$CASE/second.out" 2>&1 &
    # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
    second_pid=$!
    i=0
    while [ "$i" -lt 300 ]; do
      [ ! -f "$CASE/second.ready" ] || break
      if [ -f "$CASE/second.waiting" ]; then
        [ -d "$project_lock" ] || fail 'the contended project lock disappeared'
        kill -0 "$second_pid" 2>/dev/null || fail 'second landing exited before contending'
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    [ "$i" -lt 300 ] || fail 'second landing neither prepared nor contended for the checkout'
    : > "$CASE/release-first"
    wait "$first_pid" || first_rc=$?
    wait "$second_pid" || second_rc=$?
    first_pid='' second_pid=''
    [ "$first_rc" -eq 0 ] || fail "first landing failed: $(cat "$CASE/first.out")"
    [ "$second_rc" -ne 0 ] || fail "second landing unexpectedly succeeded: $(cat "$CASE/second.out")"
    [ -f "$CASE/first.updated" ] || fail 'the first ref transaction did not run'
    if [ -f "$CASE/second.ready" ]; then
      [ -f "$CASE/second.staged" ] || fail 'the competing checkout was never staged'
    fi
    [ "$(git -C "$PROJ" rev-parse HEAD)" = "$X" ] || fail 'the competing task moved the landed head'
    [ "$(cat "$PROJ/approved.txt")" = 'approved X' ] || fail 'the competing task reverted the landed files'
    [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail 'the competing task dirtied the landed checkout'
  ) || fail 'two-task same-tree landing corrupted the first result'
  pass 'two reported tasks with the same tree cannot roll back a successful landing'
}

fm_test_run test_two_tasks_cannot_undo_a_same_tree_landing \
  test_unreported_commits_after_a_landing_do_not_land \
  test_a_caller_built_done_line_cannot_attach_unreported_commits \
  test_next_stage_lands_on_its_own_report \
  test_only_the_reported_commit_lands_when_the_worker_moved_on \
  test_revised_work_lands_on_the_new_report \
  test_promoted_scout_lands_on_its_ship_report test_landing_on_a_scout_done_line_refuses \
  test_report_with_an_open_question_lands test_reports_that_name_no_commit_refuse \
  test_report_naming_a_commit_off_the_branch_refuses test_a_landed_report_does_not_land_again \
  test_an_approval_names_one_commit test_approved_work_lands_after_an_identical_rebase \
  test_approved_work_changed_by_a_rebase_refuses test_accepting_a_report_writes_nothing \
  test_a_long_lived_owner_lands_every_stage test_help_and_bad_requests \
  test_change_after_hold_check_refuses test_diverged_default_refuses \
  test_change_during_approval_check_refuses
