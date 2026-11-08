#!/usr/bin/env bash
# Behavior tests for the live steer of a worker-owned Lavish board
# (docs/configuration.md "Crew-hosted Lavish review boards"): the board keeps
# listening after a round reaches its worker, every later Send arrives as its
# own steering-inbox note, the worker can post an interim acknowledgement and
# a bounded re-arm, and nothing the captain wrote is lost when the round,
# board, or worker ends - the 8 Nov sequence where a note sent one minute
# after a decision sat unread in a torn-down worker's inbox.
#
# lavish-axi is a stub: each poll blocks until its numbered trigger exists and
# then prints the numbered response, and `reply` records what it was given. No
# live Lavish server is started.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-live-steer-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

STUB_BIN=$(fm_fakebin "$TMP_ROOT/stub")
cat > "$STUB_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# LS_ROOT/version is the version this stub reports; LS_ROOT/count numbers polls.
set -u
[ "${1-}" != --version ] || { cat "$LS_ROOT/version"; exit 0; }
case "${1-}" in
  reply)
    [ ! -e "$LS_ROOT/ended" ] || { printf 'error: session ended\n' >&2; exit 1; }
    case "${3-}" in
      --agent-reply) printf 'reply: %s\n' "$4" >> "$LS_ROOT/replies" ;;
      --agent-reply-file) printf 'reply: %s\n' "$(cat "$4")" >> "$LS_ROOT/replies" ;;
      *) exit 2 ;;
    esac
    exit 0
    ;;
  poll)
    n=$(cat "$LS_ROOT/count" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$LS_ROOT/count"
    if [ "${3-}" = --agent-reply ]; then printf 'poll reply: %s\n' "$4" >> "$LS_ROOT/replies"; fi
    while [ ! -e "$LS_ROOT/trigger$n" ]; do
      [ "$SECONDS" -lt 90 ] || exit 75
      sleep 0.02
    done
    cat "$LS_ROOT/response$n"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$STUB_BIN/lavish-axi"

lavish_session() {  # <artifact>
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open",
      url => "http://127.0.0.1:14387/session/0123456789abcdef",
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1"
}

# One board fixture: a home, a worker endpoint, an artifact, and a stub root.
# Sets HOME_DIR, LS_ROOT, ART, SRC.
new_board() {  # <name> <lavish-version> <task-id>
  HOME_DIR="$TMP_ROOT/$1/home"
  LS_ROOT="$TMP_ROOT/$1/lavish"
  ART="$TMP_ROOT/$1/board.html"
  mkdir -p "$HOME_DIR/state" "$LS_ROOT"
  export LS_ROOT
  printf '%s\n' "$2" > "$LS_ROOT/version"
  printf '<h1>%s</h1>\n' "$1" > "$ART"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$3" "$HOME_DIR" "$3" \
    > "$HOME_DIR/state/$3.meta"
  lavish_session "$ART"
  SRC=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
  fm_test_track_procevent_home "$HOME_DIR"
}

lv() { PATH="$STUB_BIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-lavish.sh" "$@"; }
pe() { PATH="$STUB_BIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" "$@"; }
polls() { cat "$LS_ROOT/count" 2>/dev/null || echo 0; }
wait_polls() {  # <count>
  local _
  for _ in $(seq 1 300); do [ "$(polls)" -ge "$1" ] && return 0; sleep 0.02; done
  return 1
}
wait_file() {  # <path>
  local _
  for _ in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.02; done
  return 1
}
feedback() {  # <round> <message>
  printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","%s","","message",""\n' "$2" \
    > "$LS_ROOT/response$1"
  touch "$LS_ROOT/trigger$1"
}
send_and_end() {  # <round> <message>
  printf 'session:\n  status: feedback\n  session_ended: true\n  ended_by: user\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","%s","","message",""\n' "$2" \
    > "$LS_ROOT/response$1"
  touch "$LS_ROOT/trigger$1"
  touch "$LS_ROOT/ended"
}
inbox() { printf '%s/state/%s.inbox\n' "$HOME_DIR" "$1"; }
handled_marker() { printf '%s/state/procevent-inbox/%s.%s.handled\n' "$HOME_DIR" "$SRC" "$1"; }
result_file() { printf '%s/state/procevent-inbox/%s.%s.result\n' "$HOME_DIR" "$SRC" "$1"; }
board_state() { pe list | awk -v id="$SRC" '$1 == id { print $3; exit }'; }

# --- the board keeps listening through a round and delivers each Send -------
new_board live 0.1.96 worker-a
arm_out=$(lv arm "$ART" --for worker-a) || fail "arming a worker-owned board failed: $arm_out"
assert_contains "$arm_out" "armed: $SRC" "arm did not report a confirmed listener"
wait_polls 1 || fail "the armed board never started listening"
feedback 1 "make the header bolder"
wait_file "$(inbox worker-a)/001.msg" || fail "round 1 did not reach the worker's steering inbox"
note1=$(cat "$(inbox worker-a)/001.msg")
assert_contains "$note1" "round 1" "the round note did not name its round"
assert_contains "$note1" "--through 1" "the round note did not give the bounded re-arm"
assert_contains "$note1" "fm-procevent-lavish.sh reply" "the round note did not ask for a prompt acknowledgement"
assert_contains "$note1" "arrives as its own note" "the round note did not say later messages arrive separately"
wait_polls 2 || fail "the board stopped listening after round 1 instead of waiting for the next Send"
[ ! -e "$(handled_marker 1)" ] || fail "listening again acknowledged round 1 before the worker did"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "worker-owned feedback woke firstmate"
pass "after a round reaches its worker the board listens for the next Send without a re-arm"

reply_out=$(lv reply "$ART" --for worker-a --agent-reply "Got it - working on the header.") \
  || fail "the worker's prompt acknowledgement was refused: $reply_out"
assert_contains "$(cat "$LS_ROOT/replies")" "reply: Got it - working on the header." \
  "the prompt acknowledgement did not reach the board"
[ ! -e "$(handled_marker 1)" ] || fail "an interim reply acknowledged the round"
if lv reply "$ART" --for worker-z --agent-reply "not mine" >/dev/null 2>"$LS_ROOT/foreign.err"; then
  fail "a task that does not hold the board posted a reply on it"
fi
assert_contains "$(cat "$LS_ROOT/foreign.err")" "not held by task worker-z" \
  "the foreign reply refusal did not name the holder mismatch"
pass "the worker posts a prompt acknowledgement on the board without closing the round"

feedback 2 "and use the GitHub style"
wait_file "$(inbox worker-a)/002.msg" || fail "a Send made mid-round did not reach the worker as its own note"
assert_contains "$(cat "$(inbox worker-a)/002.msg")" "round 2" "the mid-round note did not name its round"
wait_polls 3 || fail "the board stopped listening after the mid-round Send"
pass "a Send made while the worker is mid-round reaches it at once as its own note"

registration_inode() { perl -e 'print((stat shift)[1], "\n")' "$HOME_DIR/state/procevent/$SRC.source"; }
registration_before=$(registration_inode)
printf 'Header is bolder.\n' > "$LS_ROOT/full-reply"
rearm_out=$(lv arm "$ART" --for worker-a --through 1 --agent-reply-file "$LS_ROOT/full-reply") \
  || fail "the bounded re-arm failed: $rearm_out"
assert_contains "$rearm_out" "armed: $SRC" "the re-arm beside a live listener did not report it armed"
assert_not_contains "$rearm_out" "still-listening" "the re-arm made its own live listener a stale generation"
assert_contains "$(cat "$LS_ROOT/replies")" "reply: Header is bolder." "the round reply was not posted"
[ -e "$(handled_marker 1)" ] || fail "the re-arm did not acknowledge round 1"
[ ! -e "$(handled_marker 2)" ] || fail "the re-arm acknowledged round 2, which the worker had not answered"
[ "$(registration_inode)" = "$registration_before" ] \
  || fail "the re-arm republished a registration its live listener was serving"
sleep 0.3
[ "$(polls)" = 3 ] || fail "the re-arm started a second poll beside the live listener ($(polls) polls)"
if lv arm "$ART" --for worker-a --through 1 >/dev/null 2>"$LS_ROOT/rearm-again.err"; then
  fail "a re-arm with nothing left up to its bound was accepted"
fi
assert_contains "$(cat "$LS_ROOT/rearm-again.err")" "up to sequence 1" \
  "the empty bounded re-arm refusal did not name its bound"
pass "a bounded re-arm posts the reply and acknowledges only the rounds it answers"

# --- the 8 Nov sequence: a Send & End arrives after the worker's decision ----
send_and_end 3 "give GitHub a nod. So B is good. I like B."
wait_file "$(inbox worker-a)/003.msg" || fail "the Send & End did not reach the worker"
assert_contains "$(cat "$(inbox worker-a)/003.msg")" "do not re-arm" "the terminal note did not say to stop"
sleep 0.3
[ "$(polls)" = 3 ] || fail "the board kept polling after the session ended ($(polls) polls)"
board_out=$(pe task-board worker-a) || fail "task-board could not read worker-a's board"
assert_contains "$board_out" "$(printf 'round\tworker-a\t%s\t2\t' "$SRC")" "task-board missed open round 2"
assert_contains "$board_out" "$(printf 'round\tworker-a\t%s\t3\t' "$SRC")" "task-board missed the terminal round"
assert_contains "$board_out" "$(printf 'note\tworker-a\t%s/001.msg' "$(inbox worker-a)")" \
  "task-board missed the unread inbox note"
assert_not_contains "$board_out" "$(printf '\t1\t')" "task-board listed the acknowledged round"
if lv retire "$ART" >/dev/null 2>&1; then fail "retire removed a board whose rounds were unacknowledged"; fi
pass "a Send & End after the worker's decision stays open and is listed until acknowledged"

# Cleanup bypassed the guard (the worker record is gone): the drain's home-wide
# view still names every round, so the captain's words cannot vanish silently.
mv "$HOME_DIR/state/worker-a.meta" "$TMP_ROOT/worker-a.meta.gone"
all_out=$(pe task-board --all) || fail "task-board --all failed"
assert_contains "$all_out" "$(printf 'round\tworker-a\t%s\t3\t' "$SRC")" \
  "an open round whose worker record is gone was not surfaced home-wide"
assert_contains "$all_out" "$(printf 'note\tworker-a\t')" "an unread note was not surfaced home-wide"
mv "$TMP_ROOT/worker-a.meta.gone" "$HOME_DIR/state/worker-a.meta"
pe handled "$SRC" 2 >/dev/null || fail "acknowledging the open nonterminal round failed"
concl=$(pe handled "$SRC" 3) || fail "concluding the terminal round failed"
assert_contains "$concl" "retired: $SRC" "acknowledging the terminal round did not retire the board"
mkdir -p "$(inbox worker-a)/handled"
mv "$(inbox worker-a)"/*.msg "$(inbox worker-a)/handled/"
[ -z "$(pe task-board worker-a)" ] || fail "task-board still listed items after everything was read"
pass "acknowledged rounds and filed notes clear the board's unread list"

# --- a listener that dies mid-round is restarted by reconcile ----------------
new_board restart 0.1.96 worker-b
lv arm "$ART" --for worker-b >/dev/null || fail "arming the restart board failed"
wait_polls 1 || fail "the restart board never listened"
feedback 1 "first note"
wait_file "$(inbox worker-b)/001.msg" || fail "round 1 of the restart board was not delivered"
wait_polls 2 || fail "the restart board did not keep listening"
runner=$(cat "$HOME_DIR/state/procevent/$SRC.runner")
kill -TERM -- "-$runner" 2>/dev/null || fail "could not stop the restart board's runner"
for _ in $(seq 1 100); do kill -0 -- "-$runner" 2>/dev/null || break; sleep 0.05; done
[ "$(board_state)" = "task:worker-b/round-open" ] || fail "the stopped board did not read as an open round: $(board_state)"
pe reconcile >/dev/null 2>&1 || true
wait_polls 3 || fail "reconcile did not restart a live-steer board whose open round was already delivered"
[ ! -e "$(handled_marker 1)" ] || fail "restarting the listener acknowledged the open round"
pass "reconcile restarts a live-steer board whose open round already reached its worker"

# --- a round that cannot reach its worker stops the board listening ----------
new_board undelivered 0.1.96 worker-c
lv arm "$ART" --for worker-c >/dev/null || fail "arming the undelivered board failed"
wait_polls 1 || fail "the undelivered board never listened"
mkdir -p "$(inbox worker-c)"
chmod 0500 "$(inbox worker-c)"
feedback 1 "nobody can file this yet"
for _ in $(seq 1 100); do [ -e "$(result_file 1)" ] && break; sleep 0.02; done
sleep 0.5
[ "$(polls)" = 1 ] || fail "the board kept polling after a round failed to reach its worker ($(polls) polls)"
pe reconcile >/dev/null 2>&1 || true
sleep 0.3
[ "$(polls)" = 1 ] || fail "reconcile restarted a board whose open round never reached its worker"
chmod 0700 "$(inbox worker-c)"
pe reconcile >/dev/null 2>&1 || true
wait_file "$(inbox worker-c)/001.msg" || fail "reconcile did not deliver the held round once the inbox recovered"
pe reconcile >/dev/null 2>&1 || true
wait_polls 2 || fail "the board did not listen again once its open round was delivered"
pass "a round that cannot reach its worker keeps the board from consuming more feedback"

# --- an older Lavish keeps one round per listener ----------------------------
new_board legacy 0.1.79 worker-d
lv arm "$ART" --for worker-d >/dev/null || fail "arming the legacy board failed"
wait_polls 1 || fail "the legacy board never listened"
feedback 1 "legacy note"
wait_file "$(inbox worker-d)/001.msg" || fail "the legacy round was not delivered"
sleep 0.5
[ "$(polls)" = 1 ] || fail "a board on an older Lavish kept listening without synchronous replies"
if lv reply "$ART" --for worker-d --agent-reply "got it" >/dev/null 2>&1; then
  fail "an interim reply was posted through an older Lavish that cannot post one on its own"
fi
pass "a board on an older Lavish keeps the one-round-per-listener behavior"

printf '\nall live-steer tests passed\n'
