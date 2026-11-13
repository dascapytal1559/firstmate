#!/usr/bin/env bash
# tests/fm-t3-mcp.test.sh - bin/fm-t3-mcp.mjs, the t3code backend's `/mcp`
# transport, driven through its CLI against tests/t3-fake-server.mjs: the
# captain-run sign-in, the capability gate, the environment-identity check,
# credential expiry and permissions, and every verb's result shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node absent"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-t3-mcp-tests)
trap 't3_fake_stop; fm_test_cleanup' EXIT
HELPER="$ROOT/bin/fm-t3-mcp.mjs"
CRED="$TMP_ROOT/config/t3code-token"
WT="$TMP_ROOT/worktree"
SEL='{"instanceId":"claudeAgent","model":"claude-sonnet-5-5","options":[{"id":"effort","value":"low"}]}'
mkdir -p "$WT" "$TMP_ROOT/proj"

mcp() {  # <verb> [args...] -> stdout in OUT, stderr in ERR, exit in RC
  local errf="$TMP_ROOT/stderr"
  OUT=$(node "$HELPER" "$@" --token-file "$CRED" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
}

field() {  # <json> <key>
  node -e 'const d=JSON.parse(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k], d); process.stdout.write(v==null?"":typeof v==="object"?JSON.stringify(v):String(v))' "$1" "$2"
}

t3_fake_items() {  # <thread-id> <text> -> how many items of the thread carry <text>
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(w.threads[process.argv[2]].items.filter((i) => i.text === process.argv[3]).length))' "$T3_FAKE_WORLD" "$1" "$2"
}

fresh_case() {  # <name> [world-json]
  t3_fake_case "$TMP_ROOT/cases/$1" "${2:-}"
  t3_fake_credential "$CRED"
}

test_login_writes_private_credential_and_never_prints_token() {
  local cli
  t3_fake_case "$TMP_ROOT/cases/login"
  rm -f "$CRED"
  cli=$(t3_fake_t3_cli "$TMP_ROOT/cli")
  mcp login --url "$T3_FAKE_URL" --access full-access --t3 "$cli" --base-dir "$TMP_ROOT/t3home"
  expect_code 0 "$RC" "login should succeed against the fake server: $ERR"
  assert_equals true "$(field "$OUT" ok)" "login result should be ok"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "login should record the server's environment id"
  assert_not_contains "$OUT$ERR" "tok-" "login must never print the access token"
  assert_not_contains "$OUT$ERR" "PAIR-OK" "login must never print the pairing code"
  [ "$(stat -c %a "$CRED" 2>/dev/null || stat -f %Lp "$CRED")" = 600 ] || fail "credential file must be mode 0600"
  assert_grep '"environment_id":"env-fake-1"' "$CRED" "credential must record the environment id"
  assert_grep '"origin":"'"$T3_FAKE_URL"'"' "$CRED" "credential must record the origin"
  assert_grep "auth pairing create --base-dir $TMP_ROOT/t3home --scope orchestration:read --scope orchestration:operate --scope settings:write --scope source-control:write --ttl 2m" "$TMP_ROOT/cli/t3-cli.log" \
    "sign-in must mint a two-minute pairing code covering every scope T3 grants a full-access mcp-client"
  assert_grep '"access":"full-access"' "$T3_FAKE_LOG" "the OAuth decision must carry the full-access ceiling"
  assert_grep '"pkce":true' "$T3_FAKE_LOG" "the token exchange must prove the PKCE verifier"
  pass "fm-t3-mcp login: PKCE sign-in writes a 0600 credential with the environment id and prints no secret"
}

test_login_origin_defaults() {
  local cli home
  t3_fake_case "$TMP_ROOT/cases/login-origin"
  cli=$(t3_fake_t3_cli "$TMP_ROOT/cli")
  home="$TMP_ROOT/user-home"
  mkdir -p "$home/.t3/userdata"
  printf '{"origin":"%s/"}\n' "$T3_FAKE_URL" > "$home/.t3/userdata/server-runtime.json"
  rm -f "$CRED"
  OUT=$(HOME="$home" FM_T3CODE_ORIGIN='' node "$HELPER" login --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 0 "$RC" "login should take the origin from T3's runtime file: $(cat "$TMP_ROOT/stderr")"
  assert_equals "$T3_FAKE_URL" "$(field "$OUT" origin)" "the runtime file's origin is normalized"
  printf '{"origin":"http://127.0.0.1:9/"}\n' > "$home/.t3/userdata/server-runtime.json"
  rm -f "$CRED"
  OUT=$(HOME="$home" FM_T3CODE_ORIGIN="$T3_FAKE_URL/" node "$HELPER" login --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 0 "$RC" "FM_T3CODE_ORIGIN must win over T3's runtime file: $(cat "$TMP_ROOT/stderr")"
  assert_equals "$T3_FAKE_URL" "$(field "$OUT" origin)" "FM_T3CODE_ORIGIN, normalized, is the sign-in origin"
  rm -f "$CRED"
  OUT=$(HOME="$home" FM_T3CODE_ORIGIN=http://127.0.0.1:9 node "$HELPER" login --url "$T3_FAKE_URL" --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 0 "$RC" "--url must win over FM_T3CODE_ORIGIN: $(cat "$TMP_ROOT/stderr")"
  assert_equals "$T3_FAKE_URL" "$(field "$OUT" origin)" "--url is the sign-in origin"
  rm -f "$CRED"
  OUT=$(HOME="$TMP_ROOT/nowhere" FM_T3CODE_ORIGIN='' node "$HELPER" login --access full-access --t3 "$cli" --token-file "$CRED" 2>"$TMP_ROOT/stderr"); RC=$?
  expect_code 2 "$RC" "login without any origin is invalid use"
  assert_contains "$(cat "$TMP_ROOT/stderr")" "FM_T3CODE_ORIGIN" "the refusal names the override"
  assert_contains "$(cat "$TMP_ROOT/stderr")" "server-runtime.json" "the refusal names the runtime file"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp login: the origin defaults to FM_T3CODE_ORIGIN, then T3's runtime file, else refuses naming both"
}

test_login_refuses_other_ceilings() {
  local before after
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp login --url "$T3_FAKE_URL" --access auto-accept-edits --t3 /bin/false
  expect_code 2 "$RC" "a non-full-access ceiling is invalid use"
  assert_contains "$ERR" "only the full-access ceiling" "the refusal should explain the ceiling"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "a refused ceiling must not reach the server"
  pass "fm-t3-mcp login: refuses every ceiling but full-access before any request"
}

test_status_gate_and_protocol() {
  fresh_case status
  mcp status
  expect_code 0 "$RC" "status should pass the gate: $ERR"
  assert_equals env-fake-1 "$(field "$OUT" environmentId)" "status should report the environment id"
  assert_equals 0.0.46-nightly.fake "$(field "$OUT" serverVersion)" "status should report the server version"
  node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.path === "/mcp");
process.exit(lines.length && lines.every((e) => e.protocol === "2025-06-18") ? 0 : 1);
' "$T3_FAKE_LOG" || fail "every MCP request must carry protocol version 2025-06-18, got $(cat "$T3_FAKE_LOG")"
  t3_fake_set 'w.sse = true'
  mcp status
  expect_code 0 "$RC" "status should parse SSE replies too: $ERR"
  pass "fm-t3-mcp status: gate passes over JSON and SSE replies with the 2025-06-18 protocol header"
}

test_gate_refuses_missing_tools() {
  fresh_case gate
  t3_fake_set 'w.tools = ["t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_project_list","t3_project_create","t3_environment_read"]'
  mcp status
  expect_code 4 "$RC" "a server without t3_thread_launch must be refused"
  assert_equals capability_gate "$(field "$OUT" error.code)" "the refusal should be the capability gate"
  assert_contains "$ERR" "t3_thread_launch" "the refusal should name the missing tool"
  t3_fake_set 'w.tools = ["t3_thread_launch","t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_thread_list","t3_thread_configure","t3_project_list","t3_project_create","t3_pending_request","orchestrator_capabilities"]'
  mcp status
  expect_code 4 "$RC" "a server without t3_environment_read cannot prove its identity"
  assert_contains "$ERR" "lacks t3_environment_read" "the refusal should name the missing identity tool"
  pass "fm-t3-mcp gate: refuses a server missing a required tool or its identity tool"
}

test_environment_mismatch_refused() {
  fresh_case env-mismatch '{"environmentId":"env-other"}'
  mcp status
  expect_code 4 "$RC" "a different environment behind the same origin must be refused"
  assert_equals environment_mismatch "$(field "$OUT" error.code)" "the refusal should be an environment mismatch"
  mcp state --thread mcp:none
  expect_code 4 "$RC" "every verb runs the environment check"
  pass "fm-t3-mcp: refuses a server whose environment id differs from the credential's"
}

test_expiry_and_permissions() {
  local before after
  fresh_case expiry
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) - 60) * 1000 ))
  before=$(wc -l < "$T3_FAKE_LOG")
  mcp status
  expect_code 4 "$RC" "an expired credential must be refused"
  assert_equals credential_expired "$(field "$OUT" error.code)" "expired refusal code"
  after=$(wc -l < "$T3_FAKE_LOG")
  assert_equals "$before" "$after" "an expired credential must not reach the server"
  t3_fake_credential "$CRED" env-fake-1 $(( ($(date +%s) + 2 * 86400) * 1000 ))
  mcp status
  expect_code 0 "$RC" "a credential two days from expiry still works"
  assert_contains "$ERR" "warning: T3 credential expires in" "near expiry warns on stderr"
  assert_contains "$(field "$OUT" credentialWarning)" "expires in" "status reports the expiry warning"
  t3_fake_credential "$CRED" env-fake-1 "" 644
  mcp status
  expect_code 4 "$RC" "a credential readable by others must be refused"
  assert_equals credential_permissions "$(field "$OUT" error.code)" "permission refusal code"
  rm -f "$CRED"
  mcp status
  expect_code 4 "$RC" "a missing credential must be refused"
  assert_contains "$ERR" "fm-t3-mcp.mjs login --access full-access" "the missing-credential refusal names the captain's sign-in"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp credential: refuses expired, missing, and over-readable credentials, and warns before expiry"
}

test_revoked_credential_refused() {
  fresh_case revoked '{"revoked":true}'
  mcp status
  expect_code 4 "$RC" "a revoked credential must be refused"
  assert_equals unauthorized "$(field "$OUT" error.code)" "revoked refusal code"
  pass "fm-t3-mcp: a 401 from a revoked credential is a local refusal naming a fresh sign-in"
}

test_projects_by_real_path() {
  local project
  fresh_case projects
  mkdir -p "$TMP_ROOT/link-parent"
  ln -sfn "$TMP_ROOT/proj" "$TMP_ROOT/link-parent/proj-link"
  mcp project-ensure --root "$TMP_ROOT/link-parent/proj-link" --title fm-proj
  expect_code 0 "$RC" "project-ensure should create the project: $ERR"
  project=$(field "$OUT" projectId)
  assert_equals true "$(field "$OUT" created)" "first project-ensure creates"
  assert_equals "$(cd "$TMP_ROOT/proj" && pwd -P)" "$(field "$(t3_fake_calls t3_project_create)" workspaceRoot)" "the project is registered at its real path"
  mcp project-ensure --root "$TMP_ROOT/proj"
  assert_equals "$project" "$(field "$OUT" projectId)" "a second project-ensure finds the same project by real path"
  assert_equals false "$(field "$OUT" created)" "a second project-ensure does not create"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "claudeAgent", model: "claude-sonnet-5-5" }'
  mcp project-read --project "$project"
  expect_code 0 "$RC" "project-read: $ERR"
  assert_equals claude-sonnet-5-5 "$(field "$OUT" project.defaultModelSelection.model)" "project-read returns the default model selection"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).deletedAt = "2026-10-01T00:00:00Z"'
  mcp project-read --project "$project"
  expect_code 3 "$RC" "a deleted project reads as not found"
  assert_equals project_not_found "$(field "$OUT" error.code)" "project-read refusal code"
  mcp project-ensure --root "$TMP_ROOT/proj"
  assert_equals true "$(field "$OUT" created)" "a deleted project's root registers again"
  mkdir -p "$TMP_ROOT/proj-raced"
  t3_fake_set 'w.dropReplyTools = { t3_project_create: 1 }'
  mcp project-ensure --root "$TMP_ROOT/proj-raced"
  expect_code 0 "$RC" "a create that failed after the project was registered must resolve to it: $ERR"
  assert_equals false "$(field "$OUT" created)" "the resolved project was registered by the failed create, not this call"
  FM_T3_ROOT="$(cd "$TMP_ROOT/proj-raced" && pwd -P)" FM_T3_ID="$(field "$OUT" projectId)" node -e '
const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const live = w.projects.filter((p) => !p.deletedAt && p.workspaceRoot === process.env.FM_T3_ROOT);
process.exit(live.length === 1 && live[0].id === process.env.FM_T3_ID ? 0 : 1);
' "$T3_FAKE_WORLD" || fail "the root must hold exactly the one project project-ensure returned"
  pass "fm-t3-mcp projects: matched by real path, deleted ones skipped, a failed create resolves to a registered project, project-read returns the default model"
}

test_launch_binds_workspace() {
  local project call
  fresh_case launch
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title fm-a --model-selection "$SEL" --worktree "$WT" --branch fm/a
  expect_code 0 "$RC" "launch should create an idle thread: $ERR"
  case "$(field "$OUT" threadId)" in mcp:*) ;; *) fail "launch should print T3's thread id, got '$OUT'" ;; esac
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals full-access "$(field "$call" runtimeMode)" "launch must request full access"
  assert_equals existing_worktree "$(field "$call" workspaceStrategy.type)" "launch must bind an existing worktree"
  assert_equals "$WT" "$(field "$call" workspaceStrategy.worktreePath)" "launch must bind the given worktree"
  assert_equals fm/a "$(field "$call" workspaceStrategy.branch)" "launch carries the branch"
  assert_equals "$SEL" "$(field "$call" modelSelection)" "launch carries the model selection verbatim"
  assert_equals "" "$(field "$call" message)" "a launch without a message file creates an idle thread"
  mcp launch --project "$project" --title fm-home --model-selection "$SEL"
  expect_code 0 "$RC" "a worktree-less launch runs at the project root: $ERR"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals '{"type":"root"}' "$(field "$call" workspaceStrategy)" "a worktree-less launch uses the root strategy"
  pass "fm-t3-mcp launch: idle full-access thread on the existing worktree or the project root, with the given model selection"
}

test_launch_refusals() {
  local project
  fresh_case launch-refusals
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title x --model-selection '{"model":"m"}' --worktree "$WT"
  expect_code 2 "$RC" "a model selection without an instance is invalid use"
  t3_fake_set 'w.bindWorktree = "/somewhere/else"'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread bound to another worktree is refused"
  assert_equals binding_mismatch "$(field "$OUT" error.code)" "binding refusal code"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "a mis-bound thread is archived before refusing"
  t3_fake_set 'delete w.bindWorktree; w.bindInstance = "codex"'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread on another provider instance is refused"
  t3_fake_set 'delete w.bindInstance; w.bindRuntimeMode = "auto-accept-edits"'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread below full access is refused"
  t3_fake_set 'w.archiveKeepsRun = true'
  printf 'brief' > "$TMP_ROOT/launch-message"
  FM_T3CODE_ARCHIVE_TIMEOUT_MS=300 mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT" --message-file "$TMP_ROOT/launch-message"
  expect_code 1 "$RC" "a mis-bound thread whose accepted archive never reads back closed is an uncertain outcome"
  assert_contains "$ERR" "its archive is unproven" "the uncertain refusal says the archive is unproven"
  t3_fake_set 'delete w.archiveKeepsRun'
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "boom", message: "archive failed" } }'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a mis-bound thread whose archive failed is an uncertain outcome"
  assert_contains "$ERR" "archive it in T3 Code" "the uncertain refusal names the manual archive"
  t3_fake_set 'delete w.bindRuntimeMode; w.failTools = { t3_thread_read: { code: "thread_not_found", message: "not yet projected" } }'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launched thread whose binding read-back failed is an uncertain outcome"
  assert_equals binding_unconfirmed "$(field "$OUT" error.code)" "read-back failure refusal code"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "a thread with an unproven binding is archived before refusing"
  t3_fake_set 'w.failTools = { t3_thread_read: { code: "thread_not_found", message: "not yet projected" }, t3_thread_organize: { code: "thread_not_found", message: "not yet projected" } }'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launched thread T3 does not yet find is an uncertain outcome"
  assert_contains "$ERR" "its archive is unproven" "a not-found archive of the thread this launch created is not a proven close"
  t3_fake_set 'w.failTools = {}; w.dropTools = { t3_thread_launch: 1 }'
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launch whose reply was lost is an uncertain transport failure"
  t3_fake_set 'w.dropTools = { t3_environment_read: 1 }'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title x --model-selection "$SEL" --worktree "$WT"
  expect_code 8 "$RC" "a gate transport failure before the launch request launched nothing"
  assert_contains "$ERR" "no thread was launched" "the failure says no thread exists"
  [ -z "$(t3_fake_calls t3_thread_launch)" ] || fail "no launch may be requested after the gate failed"
  pass "fm-t3-mcp launch: refuses a binding T3 did not honor, reports a lost, unproven, or unarchived launch as uncertain, and a gate failure as no launch"
}

new_thread() {  # -> thread id
  local project
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title fm-t --model-selection "$SEL" --worktree "$WT"
  field "$OUT" threadId
}

test_send_state_capture_interrupt_archive() {
  local thread msg
  fresh_case thread-verbs
  thread=$(new_thread)
  msg="$TMP_ROOT/msg"
  printf 'hello worker' > "$msg"
  mcp state --thread "$thread"
  assert_equals idle "$(field "$OUT" status)" "a fresh thread is idle"
  assert_equals "" "$(field "$OUT" turnAt)" "a thread with no run has no turn time"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  expect_code 0 "$RC" "send should start the idle thread: $ERR"
  assert_equals started "$(field "$OUT" delivery)" "an idle thread starts a turn"
  assert_contains "$(t3_fake_calls t3_thread_send | tail -1)" '"mode":"auto","clientRequestId":"req-1"' "send uses mode auto with the request id"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-1
  expect_code 0 "$RC" "a retry under the same request id should succeed: $ERR"
  assert_equals 2 "$(t3_fake_calls t3_thread_send | grep -c '"clientRequestId":"req-1"')" "a retry sends the same client request id again"
  assert_equals 1 "$(t3_fake_items "$thread" "hello worker")" "the retry lands on the one committed message"
  mcp state --thread "$thread"
  assert_equals running "$(field "$OUT" status)" "a started thread runs"
  [ -n "$(field "$OUT" activeRunId)" ] || fail "a running thread has an active run"
  [ -n "$(field "$OUT" turnAt)" ] || fail "a running thread reports its turn time"
  mcp capture --thread "$thread" --lines 5
  expect_code 0 "$RC" "capture: $ERR"
  assert_contains "$OUT" "[user_message/completed] hello worker" "capture renders activity items"
  assert_equals "t3code: status=running run=$(field "$(node "$HELPER" state --thread "$thread" --token-file "$CRED")" activeRunId)" "$(printf '%s\n' "$OUT" | tail -1)" "capture ends with the thread's status line"
  mcp capture --thread "$thread" --lines 1
  case "$OUT" in 't3code: status=running run='*) ;; *) fail "the tightest capture bound still shows the status line, got '$OUT'" ;; esac
  mcp interrupt --thread "$thread"
  assert_equals confirmed "$(field "$OUT" cancel)" "interrupting a running turn is confirmed by the wait"
  mcp interrupt --thread "$thread"
  assert_equals not-running "$(field "$OUT" cancel)" "interrupting an idle thread reports not-running"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-2
  t3_fake_set 'w.waitTimesOut = true'
  mcp interrupt --thread "$thread" --timeout-ms 100
  assert_equals unconfirmed "$(field "$OUT" cancel)" "a wait that times out leaves the cancel unconfirmed"
  t3_fake_set 'w.archiveKeepsRun = true'
  mcp archive --thread "$thread" --timeout-ms 300
  expect_code 1 "$RC" "an archive that leaves an active run is not a proven close"
  assert_equals close_unproven "$(field "$OUT" error.code)" "unproven close code"
  t3_fake_set 'w.waitTimesOut = false; w.archiveKeepsRun = false'
  thread=$(new_thread)
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-3
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archive should prove the close: $ERR"
  assert_equals true "$(field "$OUT" closed)" "archive reports a proven close"
  assert_equals true "$(field "$OUT" archived)" "archive reads back archived"
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "archiving an archived thread is the same end state"
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "invalid_request", message: "Thread is already archived" } }'
  mcp archive --thread "$thread"
  expect_code 0 "$RC" "T3 refusing to re-archive an archived thread is the same end state: $ERR"
  assert_equals true "$(field "$OUT" closed)" "the read-back still proves the close"
  t3_fake_set 'w.failTools = { t3_thread_organize: { code: "boom", message: "archive failed" } }'
  mcp archive --thread "$thread"
  expect_code 3 "$RC" "any other organize failure is not an archive"
  assert_equals boom "$(field "$OUT" error.code)" "an organize failure is reported as T3's own error, not waited out"
  t3_fake_set 'w.failTools = {}'
  mcp state --thread "$thread"
  assert_equals true "$(field "$OUT" archived)" "state reports archived"
  mcp send --thread "$thread" --message-file "$msg" --client-request-id req-4
  expect_code 3 "$RC" "an archived thread refuses messages as a typed T3 failure"
  assert_equals thread_not_sendable "$(field "$OUT" error.code)" "T3's own error code is carried"
  mcp archive --thread mcp:gone
  expect_code 0 "$RC" "a thread the verified server does not have is already closed"
  assert_equals true "$(field "$OUT" missing)" "archive of a missing thread reports missing"
  mcp state --thread mcp:gone
  assert_equals false "$(field "$OUT" exists)" "state of a missing thread reads exists:false"
  pass "fm-t3-mcp thread verbs: idempotent send, state and turn time, bounded capture, interrupt claims, and proven archive"
}

test_thread_for_root() {
  local project captain other
  fresh_case thread-for-root
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "no live thread on the root is exit 5"
  mcp launch --project "$project" --title worker --model-selection "$SEL" --worktree "$WT"
  printf 'go' > "$TMP_ROOT/msg"
  mcp send --thread "$(field "$OUT" threadId)" --message-file "$TMP_ROOT/msg" --client-request-id w
  mcp launch --project "$project" --title captain --model-selection "$SEL"
  captain=$(field "$OUT" threadId)
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "an idle root thread and a running worktree thread are not the supervisor"
  mcp send --thread "$captain" --message-file "$TMP_ROOT/msg" --client-request-id c
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "one running root thread resolves: $ERR"
  assert_equals "$captain" "$(field "$OUT" threadId)" "the running root thread is the supervisor"
  mcp launch --project "$project" --title other --model-selection "$SEL"
  other=$(field "$OUT" threadId)
  mcp send --thread "$other" --message-file "$TMP_ROOT/msg" --client-request-id o
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 6 "$RC" "two running root threads are ambiguous"
  assert_contains "$ERR" "FM_SUPERVISOR_TARGET" "the ambiguity names the pin"
  assert_contains "$(field "$OUT" error.threadIds)" "$captain" "the ambiguity lists the ids"
  FM_T3_ID="$other" t3_fake_set 'w.threads[process.env.FM_T3_ID].archived = true'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "an archived root thread whose run is still ending no longer counts: $ERR"
  assert_equals "$captain" "$(field "$OUT" threadId)" "the unarchived running root thread is the supervisor"
  pass "fm-t3-mcp thread-for-root: only an unarchived, running, worktree-less thread on the root resolves"
}

# pin-coordinator pins exactly the thread thread-for-root finds, one per
# project, only where T3 advertises coordinatorRestartNote; elsewhere it looks
# nothing up and changes nothing.
test_pin_coordinator() {
  local project captain other pins
  fresh_case pin-coordinator '{"coordinatorRestartNote":true}'
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp pin-coordinator --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "with no live root thread there is nothing to pin"
  printf 'go' > "$TMP_ROOT/msg"
  mcp launch --project "$project" --title captain --model-selection "$SEL"
  captain=$(field "$OUT" threadId)
  mcp send --thread "$captain" --message-file "$TMP_ROOT/msg" --client-request-id c
  mcp launch --project "$project" --title earlier --model-selection "$SEL"
  other=$(field "$OUT" threadId)
  FM_T3_ID="$other" t3_fake_set 'w.threads[process.env.FM_T3_ID].coordinator = true'
  mcp pin-coordinator --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "the live root thread is pinned: $ERR"
  assert_equals true "$(field "$OUT" pinned)" "the result reports the pin"
  assert_equals "$captain" "$(field "$OUT" threadId)" "the pinned thread is the live root thread"
  mcp read --thread "$captain"
  assert_equals true "$(field "$OUT" thread.coordinator)" "the captain thread reads back pinned"
  mcp read --thread "$other"
  assert_equals false "$(field "$OUT" thread.coordinator)" "pinning unpins the project's earlier coordinator"
  mcp pin-coordinator --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "pinning again is harmless: $ERR"
  assert_equals true "$(field "$OUT" pinned)" "the repeat still reports the pin"
  pins=$(t3_fake_calls t3_thread_configure | grep -c '"coordinator":true' || true)
  assert_equals 2 "$pins" "each pin is one t3_thread_configure coordinator:true"

  fresh_case pin-coordinator-absent
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title captain --model-selection "$SEL"
  captain=$(field "$OUT" threadId)
  mcp send --thread "$captain" --message-file "$TMP_ROOT/msg" --client-request-id c
  : > "$T3_FAKE_LOG"
  mcp pin-coordinator --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "a T3 without the feature is no error: $ERR"
  assert_equals false "$(field "$OUT" pinned)" "a T3 without the feature pins nothing"
  [ -z "$(t3_fake_calls t3_thread_configure)$(t3_fake_calls t3_thread_list)" ] \
    || fail "a T3 without the feature gets no thread lookup or configure call"
  pass "fm-t3-mcp pin-coordinator: pins the live root thread as the one coordinator only where T3 offers it"
}

# crew-status brings every card in one session in line with the label it wants
# for its worker's turn: it updates only when that changes the card, proves
# T3's answer, leaves a card whose turn it cannot read, and reports a gone
# thread or an older T3 per card. A T3 without the label still passes the gate.
test_crew_status() {
  local project thread other
  fresh_case crew-status '{"statusLabels":true}'
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title 'Print view' --model-selection "$SEL"
  thread=$(field "$OUT" threadId)
  mcp launch --project "$project" --title 'Other' --model-selection "$SEL"
  other=$(field "$OUT" threadId)
  FM_T3_A=$thread FM_T3_B=$other t3_fake_set 'for (const id of [process.env.FM_T3_A, process.env.FM_T3_B]) { const t = w.threads[id]; t.status = "completed"; t.activeRunId = null; }'
  : > "$T3_FAKE_LOG"
  crew_cards() {  # <json-cards> -> runs the verb on {cards: <json-cards>}
    printf '{"cards":%s}\n' "$1" > "$TMP_ROOT/cards.json"
    mcp crew-status --file "$TMP_ROOT/cards.json"
  }
  crew_cards "[{\"thread\":\"$thread\",\"between\":\"Testing\",\"working\":\"Testing\"},{\"thread\":\"$other\",\"between\":\"Ready\",\"working\":\"\"}]"
  expect_code 0 "$RC" "labelling should succeed: $ERR"
  assert_equals 'set set' "$(field "$OUT" cards.0.outcome) $(field "$OUT" cards.1.outcome)" "both cards are set"
  assert_equals 'Testing Ready' "$(field "$OUT" cards.0.label) $(field "$OUT" cards.1.label)" "each to its own label"
  assert_equals 1 "$(t3_fake_calls t3_environment_read | wc -l | tr -d ' ')" "every card goes through one session"
  crew_cards "[{\"thread\":\"$thread\",\"between\":\"Testing\",\"working\":\"Testing\"}]"
  assert_equals unchanged "$(field "$OUT" cards.0.outcome)" "a repeat changes nothing"
  assert_equals 2 "$(t3_fake_calls t3_thread_update | wc -l | tr -d ' ')" "a repeat makes no update call"

  FM_T3_ID=$other t3_fake_set 'const t = w.threads[process.env.FM_T3_ID]; t.status = "running"; t.activeRunId = "run-x";'
  crew_cards "[{\"thread\":\"$other\",\"between\":\"Ready\",\"working\":\"\"}]"
  assert_equals cleared "$(field "$OUT" cards.0.outcome)" "a worker at work gets its working label, here none"
  FM_T3_ID=$other t3_fake_set 'w.threads[process.env.FM_T3_ID].pendingRequestCount = 1'
  crew_cards "[{\"thread\":\"$other\",\"between\":\"Waiting\",\"working\":\"\"}]"
  assert_equals 'set Waiting' "$(field "$OUT" cards.0.outcome) $(field "$OUT" cards.0.label)" "a pending request is between turns"
  FM_T3_ID=$other t3_fake_set 'const t = w.threads[process.env.FM_T3_ID]; t.pendingRequestCount = 0; t.status = "failed"; t.activeRunId = null;'
  crew_cards "[{\"thread\":\"$other\",\"between\":\"Ready\",\"working\":\"\"}]"
  assert_equals 'left Waiting' "$(field "$OUT" cards.0.outcome) $(field "$OUT" cards.0.label)" "a turn it cannot read leaves the card"
  crew_cards "[{\"thread\":\"$other\",\"between\":null,\"working\":null}]"
  assert_equals left "$(field "$OUT" cards.0.outcome)" "null leaves the card whatever the turn"
  assert_equals 0 "$(t3_fake_calls t3_thread_update | grep -c '"action":"rename"')" "a label never renames"

  t3_fake_set 'w.statusLabelAnswers = "something else"'
  crew_cards "[{\"thread\":\"$thread\",\"between\":\"\",\"working\":\"\"},{\"thread\":\"thread-missing\",\"between\":\"Testing\",\"working\":\"Testing\"}]"
  expect_code 0 "$RC" "a failed card is reported per card: $ERR"
  assert_equals failed "$(field "$OUT" cards.0.outcome)" "a label T3 does not answer with is unproven"
  assert_equals status_label_unproven "$(field "$OUT" cards.0.error.code)" "the failure names the unproven label"
  assert_equals gone "$(field "$OUT" cards.1.outcome)" "a thread T3 no longer has is gone, and the failure before it stops nothing"
  t3_fake_set 'delete w.statusLabelAnswers'

  FM_T3_ID="$thread" t3_fake_set 'w.threads[process.env.FM_T3_ID].statusLabel = "Testing"; w.threads[process.env.FM_T3_ID].archived = true'
  crew_cards "[{\"thread\":\"$thread\",\"between\":\"Testing\",\"working\":\"Testing\"}]"
  assert_equals 'cleared' "$(field "$OUT" cards.0.outcome)$(field "$OUT" cards.0.label)" "an archived thread has no card, so it always loses the label"

  t3_fake_set 'delete w.statusLabels'
  # An older T3 carries no labels at all.
  FM_T3_ID="$thread" t3_fake_set 'w.threads[process.env.FM_T3_ID].archived = false; for (const t of Object.values(w.threads)) delete t.statusLabel;'
  crew_cards "[{\"thread\":\"$thread\",\"between\":\"Testing\",\"working\":\"Testing\"},{\"thread\":\"$other\",\"between\":\"\",\"working\":\"\"}]"
  expect_code 0 "$RC" "a T3 without the label is no failure: $ERR"
  assert_equals 'unsupported unchanged' "$(field "$OUT" cards.0.outcome) $(field "$OUT" cards.1.outcome)" "only setting a label is unsupported there"
  crew_cards '[{"thread":"x","between":7,"working":""}]'
  expect_code 2 "$RC" "a malformed card is a usage error"
  mcp state --thread "$thread"
  expect_code 0 "$RC" "the label stays out of the capability gate: $ERR"
  pass "fm-t3-mcp crew-status: every card in one session, proven, and harmless on a repeat, a gone thread, or an older T3"
}

test_typed_failure_and_transport_errors() {
  local thread
  fresh_case failures
  thread=$(new_thread)
  printf 'x' > "$TMP_ROOT/msg"
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "invalid_request", message: "nope" } }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-x
  expect_code 3 "$RC" "a tool error is a typed T3 failure"
  assert_equals invalid_request "$(field "$OUT" error.code)" "typed failure code"
  t3_fake_credential "$CRED" env-fake-1 "" 600 http://127.0.0.1:9
  mcp status
  expect_code 1 "$RC" "an unreachable server is a transport failure"
  assert_equals transport "$(field "$OUT" error.code)" "transport failure code"
  t3_fake_credential "$CRED"
  pass "fm-t3-mcp: tool errors exit 3 with T3's code, an unreachable server exits 1"
}

test_telemetry_reported() {
  local tdir="$TMP_ROOT/telemetry"
  t3_fake_stop
  t3_fake_start "$tdir" T3CODE_TELEMETRY_ENABLED=false
  fresh_case telemetry-off
  mcp status
  expect_code 0 "$RC" "status against a telemetry-off server: $ERR"
  if command -v lsof >/dev/null 2>&1; then
    assert_equals off "$(field "$OUT" telemetry)" "a loopback server started with telemetry off reads off"
    assert_not_contains "$ERR" "telemetry" "telemetry off warns nothing"
  fi
  t3_fake_stop
  t3_fake_start "$tdir"
  fresh_case telemetry-default
  mcp status
  expect_code 0 "$RC" "status against a default server: $ERR"
  if command -v lsof >/dev/null 2>&1; then
    assert_equals off "$(field "$OUT" telemetry)" "a server without the setting reads off, the T3 fork's default"
    assert_not_contains "$ERR" "telemetry" "the default warns nothing"
  fi
  t3_fake_stop
  t3_fake_start "$tdir" T3CODE_TELEMETRY_ENABLED=true
  fresh_case telemetry-on
  mcp status
  expect_code 0 "$RC" "status against a telemetry-on server: $ERR"
  assert_not_equals off "$(field "$OUT" telemetry)" "a server explicitly enabling telemetry is not reported off"
  if command -v lsof >/dev/null 2>&1; then
    assert_equals on "$(field "$OUT" telemetry)" "a server explicitly enabling telemetry reads on"
  fi
  assert_contains "$ERR" "T3CODE_TELEMETRY_ENABLED=false" "telemetry on warns with the fix"
  pass "fm-t3-mcp status: reads an unset telemetry setting as off and warns only on an explicit enable"
}

test_status_reports_server_started_at() {
  local tdir="$TMP_ROOT/server-start" first second url
  t3_fake_stop
  t3_fake_start "$tdir"
  url=$T3_FAKE_URL
  fresh_case server-start
  mcp status
  expect_code 0 "$RC" "status against a T3 without the restart registry: $ERR"
  assert_equals "" "$(field "$OUT" serverStartedAt)" "a T3 without t3_restart_status has no restart identity"
  t3_fake_set 'w.restartStatus = true'
  mcp status
  expect_code 0 "$RC" "status against the T3 Code fork: $ERR"
  first=$(field "$OUT" serverStartedAt)
  case "$first" in 20[0-9][0-9]-*T*Z) ;; *) fail "serverStartedAt is T3's ISO start time, got '$first'" ;; esac
  mcp status
  assert_equals "$first" "$(field "$OUT" serverStartedAt)" "serverStartedAt is stable while the same server runs"
  t3_fake_restart "$tdir"
  assert_equals "$url" "http://127.0.0.1:$(cat "$tdir/port")" "the restarted fake keeps its origin"
  mcp status
  expect_code 0 "$RC" "status after a restart: $ERR"
  second=$(field "$OUT" serverStartedAt)
  case "$second" in 20[0-9][0-9]-*T*Z) ;; *) fail "serverStartedAt after a restart is an ISO time, got '$second'" ;; esac
  assert_not_equals "$first" "$second" "a restarted server behind the same origin reads a new serverStartedAt"
  t3_fake_set 'w.failTools = { t3_restart_status: { code: "unavailable", message: "down" } }'
  mcp status
  expect_code 0 "$RC" "a failed restart read never fails status: $ERR"
  assert_equals "" "$(field "$OUT" serverStartedAt)" "a failed restart read reports no identity"
  pass "fm-t3-mcp status: serverStartedAt is T3's restart identity, new on every restart and absent where T3 has none"
}

test_restart_registry_verbs() {
  fresh_case restart-registry '{"restartStatus":true}'
  mcp restart-request --reason "install build x"
  expect_code 4 "$RC" "a T3 with only the restart status cannot take a request"
  assert_contains "$OUT" restart_unsupported "the refusal names the missing registry"
  assert_equals "" "$(t3_fake_calls t3_restart_request)" "an unsupported request reaches nothing"
  mcp restart-status
  expect_code 0 "$RC" "the status alone needs only t3_restart_status: $ERR"
  assert_equals false "$(field "$OUT" pending)" "nothing is pending yet"

  t3_fake_set 'w.restartRegistry = true; w.activeTurns = 2'
  mcp restart-request --reason "  install build x  "
  expect_code 0 "$RC" "a request against the fork: $ERR"
  assert_equals '{"reason":"install build x"}' "$(t3_fake_calls t3_restart_request)" "the reason is sent trimmed"
  assert_equals "true install build x 2 false" \
    "$(field "$OUT" pending) $(field "$OUT" reason) $(field "$OUT" activeTurns) $(field "$OUT" drained)" \
    "the request answers T3's status: pending, not drained while turns run"
  t3_fake_set 'w.activeTurns = 0'
  mcp restart-status
  assert_equals "true true" "$(field "$OUT" pending) $(field "$OUT" drained)" "no turn in flight reads drained"
  mcp restart-cancel
  expect_code 0 "$RC" "cancel: $ERR"
  assert_equals "false false" "$(field "$OUT" pending) $(field "$OUT" drained)" "a cancelled request is gone"

  mcp restart-request --reason ""
  expect_code 2 "$RC" "an empty reason is invalid use"
  mcp restart-request --reason "$(printf 'x%.0s' $(seq 1 501))"
  expect_code 2 "$RC" "a reason past 500 characters is invalid use"

  t3_fake_set 'w.restartAnswer = { pending: false, reason: null, requestedAt: null, activeTurns: 0, drained: false, serverStartedAt: "2026-11-13T00:00:00.000Z" }'
  mcp restart-request --reason "install build y"
  expect_code 1 "$RC" "a request T3 answers as not pending is unproven"
  assert_contains "$OUT" restart_unproven "the request mismatch is named"
  t3_fake_set 'w.restartAnswer = { pending: true, reason: "install build y", requestedAt: "2026-11-13T00:00:00.000Z", activeTurns: 0, drained: true, serverStartedAt: "2026-11-13T00:00:00.000Z" }'
  mcp restart-cancel
  expect_code 1 "$RC" "a cancel T3 answers as still pending is unproven"
  assert_contains "$OUT" restart_unproven "the cancel mismatch is named"
  t3_fake_set 'w.restartAnswer = { pending: true, reason: "install build y", activeTurns: 0, serverStartedAt: "2026-11-13T00:00:00.000Z" }'
  mcp restart-request --reason "install build y"
  expect_code 1 "$RC" "an answer without drained is never read as not drained"
  assert_contains "$OUT" restart_malformed "the malformed answer is named"
  pass "fm-t3-mcp restart-*: request, status, and cancel speak the fork's registry, prove the answer, and refuse a T3 without it"
}

test_read_limit_matches_t3_cap() {
  local thread
  fresh_case read-limit
  thread=$(new_thread)
  mcp read --thread "$thread" --limit 100
  expect_code 0 "$RC" "a read at T3's cap of 100 succeeds: $ERR"
  : > "$T3_FAKE_LOG"
  mcp read --thread "$thread" --limit 101
  expect_code 2 "$RC" "a read above T3's cap of 100 is invalid use"
  assert_contains "$ERR" "up to 100" "the refusal names the cap"
  [ -z "$(t3_fake_calls t3_thread_read)" ] || fail "an over-cap read must not reach the server"
  pass "fm-t3-mcp read: --limit is capped at T3's own 100"
}

# Run A is still active while a later queued run B was already cancelled; T3
# interrupts A (its latest active run), so only A's end confirms the cancel.
test_interrupt_confirms_only_the_interrupted_run() {
  local call
  fresh_case interrupt-exact
  t3_fake_set 'w.threads = { "thread-a": { threadId: "thread-a", projectId: "p", status: "running", activeRunId: "run-a", archived: false, worktreePath: null, pendingRequestCount: 0, items: [],
    runs: [{ runId: "run-b", ordinal: 2, status: "cancelled" }, { runId: "run-a", ordinal: 1, status: "running" }] } }; w.interruptStuck = true'
  mcp interrupt --thread thread-a --timeout-ms 300
  expect_code 0 "$RC" "interrupt: $ERR"
  assert_equals run-a "$(field "$OUT" runId)" "the interrupt reports the run T3 stopped"
  assert_equals unconfirmed "$(field "$OUT" cancel)" "a still-active interrupted run is unconfirmed even though a later run is terminal"
  call=$(t3_fake_calls t3_thread_wait | tail -1)
  assert_equals run-a "$(field "$call" runId)" "the confirming wait names the interrupted run exactly"
  t3_fake_set 'w.interruptStuck = false; w.threads["thread-a"].runs = [{ runId: "run-a", ordinal: 1, status: "running" }]; w.queueAfterInterrupt = "queued next"'
  mcp interrupt --thread thread-a --timeout-ms 2000
  assert_equals confirmed "$(field "$OUT" cancel)" "the interrupted run's end confirms the cancel even after a queued run starts"
  mcp state --thread thread-a
  assert_equals running "$(field "$OUT" status)" "the queued run did start behind the interrupt"
  mcp wait --thread thread-a --run run-a --timeout-ms 100
  assert_equals interrupted "$(field "$OUT" status)" "wait --run reads that exact run"
  assert_equals run-a "$(field "$(t3_fake_calls t3_thread_wait | tail -1)" runId)" "wait --run passes the run id"
  pass "fm-t3-mcp interrupt: confirmation waits on exactly the run T3 interrupted, never a later run"
}

# T3 commits a send before it replies; a reply lost after the request went out
# is uncertain, and only the same client request id is a safe retry.
test_send_lost_reply_is_unconfirmed_and_retry_is_one_delivery() {
  local thread
  fresh_case send-lost-reply
  thread=$(new_thread)
  printf 'deliver once' > "$TMP_ROOT/msg"
  t3_fake_set 'w.dropReplyTools = { t3_thread_send: 1 }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-lost
  expect_code 7 "$RC" "a lost send reply is an unconfirmed delivery (exit 7)"
  assert_equals delivery_unconfirmed "$(field "$OUT" error.code)" "the lost reply is named as unconfirmed delivery"
  assert_contains "$ERR" "retry only with client request id req-lost" "the refusal names the only safe retry"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-lost
  expect_code 0 "$RC" "the retry with the same id succeeds: $ERR"
  [ -n "$(field "$OUT" messageId)" ] || fail "the accepted send reports T3's message id"
  [ "$(t3_fake_items "$thread" 'deliver once')" = 1 ] || fail "the committed send and its retry must be one delivery"
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "thread_busy", message: "no" } }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg" --client-request-id req-refused
  expect_code 3 "$RC" "T3's own refusal stays a proven typed failure"
  pass "fm-t3-mcp send: a reply lost after commit exits 7, and the same-id retry lands as one delivery"
}

# Away-mode discovery must read every page and treat a fork as an ordinary
# conversation while excluding a delegated subagent.
test_thread_for_root_pages_and_forks() {
  local project
  fresh_case thread-for-root-pages
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  FM_T3_P="$project" t3_fake_set '
const mk = (id, extra) => ({ threadId: id, projectId: process.env.FM_T3_P, status: "running", activeRunId: "r-" + id, archived: false, worktreePath: null, pendingRequestCount: 0, parentThreadId: null, relationshipToParent: null, items: [], runs: [], ...extra });
w.threads = { "root-a": mk("root-a") };
for (let i = 0; i < 99; i++) w.threads["wt-" + i] = mk("wt-" + i, { worktreePath: "/wt/" + i });
w.threads["root-b"] = mk("root-b");'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 6 "$RC" "a second supervisor candidate on page two is ambiguous, not a unique match: $OUT"
  assert_contains "$(field "$OUT" error.threadIds)" "root-b" "the page-two candidate is named"
  [ "$(t3_fake_calls t3_thread_list | wc -l)" -ge 2 ] || fail "discovery must follow nextCursor"
  t3_fake_set 'delete w.threads["root-a"]; w.threads["root-b"].parentThreadId = "root-x"; w.threads["root-b"].relationshipToParent = "fork"'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "a forked root conversation is a supervisor candidate: $ERR"
  assert_equals root-b "$(field "$OUT" threadId)" "the fork resolves"
  t3_fake_set 'w.threads["root-b"].relationshipToParent = "subagent"'
  mcp thread-for-root --root "$TMP_ROOT/proj"
  expect_code 5 "$RC" "a delegated subagent is never the supervisor"
  pass "fm-t3-mcp thread-for-root: every page is read, forks count, subagents do not"
}

test_resolve_selection_uses_t3_catalog() {
  local project
  fresh_case resolve-selection
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "codex", model: "gpt-5.6-sol", options: [{ id: "reasoningEffort", value: "low" }, { id: "serviceTier", value: "priority" }] }'
  mcp resolve-selection --harness codex --instance codex --model default --effort high --project "$project"
  expect_code 0 "$RC" "resolve-selection: $ERR"
  assert_equals '{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"},{"id":"serviceTier","value":"priority"}]}' \
    "$(field "$OUT" selection)" "an effort override replaces only the reasoning option and keeps the service tier"
  mcp resolve-selection --harness claude --instance codex --model gpt-5.6-sol --effort high --project "$project"
  expect_code 4 "$RC" "a claude harness mapped to a codex instance is refused"
  assert_equals driver_mismatch "$(field "$OUT" error.code)" "the refusal names the driver mismatch"
  mcp resolve-selection --harness codex --instance codex --model gpt-5.6-sol --effort max --project "$project"
  expect_code 4 "$RC" "an effort the model's catalog lacks is refused"
  assert_contains "$ERR" "low, medium, high, xhigh" "the refusal lists the catalog's values"
  mcp resolve-selection --harness codex --instance codex --model no-such-model --effort default --project "$project"
  expect_code 4 "$RC" "a model the instance does not list is refused"
  mcp resolve-selection --harness codex --instance codex --model default --effort default --project no-such-project
  expect_code 4 "$RC" "a default model on a project T3 does not list is refused"
  assert_equals project_not_found "$(field "$OUT" error.code)" "the refusal names the missing project"
  t3_fake_set 'w.providers = [{ providerInstanceId: "codex", driverKind: "codex", constraints: ["Provider instance is disabled."], models: [] }]'
  mcp resolve-selection --harness codex --instance codex --model gpt-5.6-sol --effort default --project "$project"
  expect_code 4 "$RC" "a disabled instance is refused"
  assert_contains "$ERR" "Provider instance is disabled." "the refusal carries T3's constraint"
  pass "fm-t3-mcp resolve-selection: driver, model, and options come from T3's catalog; an effort override keeps other options"
}

# T3 Code v0.1.3 stable lists a model option's allowed values as a plain `values`
# array with no `type`; a boolean option lists `[false, true]`. The default
# fake catalog keeps the older `options: [{id}]` form so both stay covered.
test_resolve_selection_accepts_current_catalog_values() {
  local project
  fresh_case resolve-selection-values
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  t3_fake_set 'w.providers = [
    { providerInstanceId: "codex", driverKind: "codex", constraints: [], models: [
      { id: "gpt-6-luna", options: [{ id: "reasoningEffort", values: ["low", "medium", "high", "xhigh"], default: "medium" }, { id: "serviceTier", values: ["default", "priority"], default: "default" }] }] },
    { providerInstanceId: "claudeAgent", driverKind: "claudeAgent", constraints: [], models: [
      { id: "claude-opus-5-5", label: "Claude Opus 5.5", options: [{ id: "effort", values: ["low", "medium", "high", "xhigh", "max"], default: "medium" }, { id: "fastMode", values: [false, true] }] }] }]'
  mcp resolve-selection --harness codex --instance codex --model gpt-6-luna --effort high --project "$project"
  expect_code 0 "$RC" "an effort listed in a values-array catalog is accepted: $ERR"
  assert_equals '{"instanceId":"codex","model":"gpt-6-luna","options":[{"id":"reasoningEffort","value":"high"}]}' \
    "$(field "$OUT" selection)" "the accepted effort is bound as the reasoning option"
  mcp resolve-selection --harness codex --instance codex --model gpt-6-luna --effort medium --project "$project"
  expect_code 0 "$RC" "the catalog's own default effort is accepted: $ERR"
  assert_equals '{"instanceId":"codex","model":"gpt-6-luna","options":[{"id":"reasoningEffort","value":"medium"}]}' \
    "$(field "$OUT" selection)" "the default effort is bound as the reasoning option"
  mcp resolve-selection --harness codex --instance codex --model gpt-6-luna --effort max --project "$project"
  expect_code 4 "$RC" "an effort missing from a values-array catalog is refused"
  assert_equals effort_unsupported "$(field "$OUT" error.code)" "the refusal names the unsupported effort"
  assert_contains "$ERR" "low, medium, high, xhigh" "the refusal lists the values array"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "claudeAgent", model: "claude-opus-5-5", options: [{ id: "fastMode", value: true }] }'
  mcp resolve-selection --harness claude --instance claudeAgent --model default --effort xhigh --project "$project"
  expect_code 0 "$RC" "a boolean option listed as values [false, true] is accepted: $ERR"
  assert_equals '{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"fastMode","value":true},{"id":"effort","value":"xhigh"}]}' \
    "$(field "$OUT" selection)" "the default's boolean option and the effort override are both kept"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection.options = [{ id: "fastMode", value: false }]'
  mcp resolve-selection --harness claude --instance claudeAgent --model default --effort high --project "$project"
  expect_code 0 "$RC" "a false boolean option listed as values [false, true] is accepted: $ERR"
  assert_equals '{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"fastMode","value":false},{"id":"effort","value":"high"}]}' \
    "$(field "$OUT" selection)" "the default's fastMode=false is kept and the effort is added"
  FM_T3_ID="$project" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection.options = [{ id: "fastMode", value: "yes" }]'
  mcp resolve-selection --harness claude --instance claudeAgent --model default --effort default --project "$project"
  expect_code 4 "$RC" "a boolean option value outside its values array is refused"
  assert_equals option_unsupported "$(field "$OUT" error.code)" "the refusal names the unsupported option"
  assert_contains "$ERR" "false, true" "the refusal lists the boolean values array"
  pass "fm-t3-mcp resolve-selection: a catalog that lists option values as a values array is read like the older options list"
}

test_launch_reads_back_full_configuration() {
  local project sel='{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"},{"id":"serviceTier","value":"priority"}]}'
  fresh_case launch-config
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title ok --model-selection "$sel" --worktree "$WT"
  expect_code 0 "$RC" "a launch whose configuration reads back exactly succeeds: $ERR"
  t3_fake_set 'w.bindOptions = [{ id: "reasoningEffort", value: "high" }]'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title dropped --model-selection "$sel" --worktree "$WT"
  expect_code 4 "$RC" "a launch that dropped a requested option is refused"
  assert_contains "$ERR" "option serviceTier=none" "the refusal names the missing option"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-configured thread is archived"
  t3_fake_set 'delete w.bindOptions; w.bindModel = "gpt-6-luna"'
  mcp launch --project "$project" --title model --model-selection "$sel" --worktree "$WT"
  expect_code 4 "$RC" "a launch on another model is refused"
  pass "fm-t3-mcp launch: the configuration read-back must show the instance, model, and every requested option"
}

test_requests_and_respond() {
  fresh_case requests
  t3_fake_set 'w.threads = { "thread-q": { threadId: "thread-q", projectId: "p", status: "running", activeRunId: "run-q", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-q", ordinal: 1, status: "running" }],
    runtimeRequests: [
      { id: "req-question", kind: "user_input", status: "pending", questions: [{ id: "q1", header: "Pick", question: "Which?", options: [{ label: "a", description: "A" }] }] },
      { id: "req-approval", kind: "approval", status: "pending" } ] } }'
  mcp state --thread thread-q
  assert_equals 2 "$(field "$OUT" pendingRequestCount)" "state counts every pending request"
  mcp requests --thread thread-q
  expect_code 0 "$RC" "requests: $ERR"
  assert_equals req-question "$(field "$OUT" questions.0.requestId)" "the question is listed by id"
  assert_equals Which? "$(field "$OUT" questions.0.questions.0.question)" "the question's content is read"
  assert_equals 1 "$(field "$OUT" approvals)" "the approval the question tools cannot see is counted"
  printf '{"q1":"a"}' > "$TMP_ROOT/answers"
  mcp respond --thread thread-q --request req-question --answers-file "$TMP_ROOT/answers"
  expect_code 0 "$RC" "respond: $ERR"
  assert_equals '{"q1":"a"}' "$(field "$(t3_fake_calls t3_pending_request | grep '"action":"respond"')" answers)" "the answers reach t3_pending_request action respond"
  mcp respond --thread thread-q --request req-approval --answers-file "$TMP_ROOT/answers"
  expect_code 3 "$RC" "a permission approval cannot be answered through the question tools"
  mcp requests --thread thread-q
  expect_code 0 "$RC" "requests after the answer: $ERR"
  assert_equals "" "$(field "$OUT" questions.0.requestId)" "the answered question is no longer pending"
  assert_equals 1 "$(field "$OUT" approvals)" "the unanswerable approval stays pending"
  pass "fm-t3-mcp requests/respond: questions are read and answered by id; approvals are counted, never answered"
}

# A T3 that advertises approvalResponses lists each pending permission
# approval with what it asks for, and the supervisor answers it by id; one
# that does not keeps approvals unanswerable.
test_approvals_with_approval_responses() {
  local sig
  fresh_case approvals '{"approvalResponses":true}'
  t3_fake_set 'w.threads = { "thread-a": { threadId: "thread-a", projectId: "p", status: "running", activeRunId: "run-a", archived: false, worktreePath: null,
    items: [{ itemId: "turn-item:runtime-request:req-appr-a", type: "approval_request", status: "waiting", text: "python3?" }],
    runs: [{ runId: "run-a", ordinal: 1, status: "running" }],
    runtimeRequests: [
      { id: "req-question", kind: "user_input", status: "pending", questions: [{ id: "q1", header: "Pick", question: "Which?", options: [] }] },
      { id: "req-appr-a", kind: "approval", status: "pending", requestKind: "command", command: "python3 - <<EOF", reason: "heredoc into an interpreter", override: "provider_check" } ] } }'
  mcp requests --thread thread-a
  expect_code 0 "$RC" "requests: $ERR"
  assert_equals true "$(field "$OUT" approvalResponses)" "the feature flag is reported"
  assert_equals req-question "$(field "$OUT" questions.0.requestId)" "the question stays a question"
  assert_equals req-appr-a "$(field "$OUT" approvalRequests.0.requestId)" "the approval is listed by request id"
  assert_equals command "$(field "$OUT" approvalRequests.0.kind)" "the approval names its kind"
  assert_equals "python3 - <<EOF" "$(field "$OUT" approvalRequests.0.detail)" "the approval names the command it asks for"
  assert_equals "heredoc into an interpreter" "$(field "$OUT" approvalRequests.0.reason)" "the approval carries the provider's reason"
  assert_equals provider_check "$(field "$OUT" approvalRequests.0.override)" "the approval names why full access did not cover it"
  assert_equals 0 "$(field "$OUT" approvals)" "an answerable approval is not counted as unanswerable"
  assert_equals 'q:req-question;a:0;r:req-appr-a' "$(field "$OUT" signature)" "the signature names the answerable approval by request id"
  t3_fake_set 'w.threads["thread-a"].runtimeRequests[0].status = "resolved"'
  mcp watch --thread thread-a --timeout-ms 200
  assert_equals blocked "$(field "$OUT" event)" "a pending approval is a blocked event"
  sig=$(field "$OUT" signature)
  assert_equals 'q:;a:0;r:req-appr-a' "$sig" "the blocked signature names the approval"
  assert_equals "python3 - <<EOF" "$(field "$OUT" approvalRequests.0.detail)" "the blocked event carries the approval's detail"
  mcp watch --thread thread-a --timeout-ms 200 --escalated "thread-a=$sig"
  assert_equals timeout "$(field "$OUT" event)" "the escalated approval does not block again"

  mcp approve --thread thread-a --request req-appr-a --decision allow --feedback-file /dev/null
  expect_code 2 "$RC" "feedback is refused on an allow"
  mcp approve --thread thread-a --request req-appr-a --decision maybe
  expect_code 2 "$RC" "a decision other than allow or deny is refused"
  : > "$T3_FAKE_LOG"
  mcp approve --thread thread-a --request req-appr-a --decision allow
  expect_code 0 "$RC" "approve allow: $ERR"
  assert_equals allow "$(field "$OUT" decision)" "the decision is reported"
  assert_equals "python3 - <<EOF" "$(field "$OUT" approval.detail)" "the answered approval is reported as read before the answer"
  assert_contains "$(t3_fake_calls t3_pending_request | grep '"action":"respond"')" '"decision":"allow"' "the allow reaches T3's pending-request respond"
  assert_not_contains "$(t3_fake_calls t3_pending_request | grep '"action":"respond"')" feedback "an allow sends no feedback"
  mcp watch --thread thread-a --timeout-ms 200 --escalated "thread-a=$sig"
  assert_equals thread-a "$(field "$OUT" cleared.0)" "the answered approval clears the escalation"

  t3_fake_set 'w.threads["thread-a"].runtimeRequests.push({ id: "req-appr-b", kind: "approval", status: "pending", requestKind: "command", command: "rm -rf /", reason: "ask rule", override: "ask_rule" })'
  printf 'Outside your task; work inside your own copy instead.' > "$TMP_ROOT/feedback"
  : > "$T3_FAKE_LOG"
  mcp approve --thread thread-a --request req-appr-b --decision deny --feedback-file "$TMP_ROOT/feedback"
  expect_code 0 "$RC" "approve deny: $ERR"
  assert_equals deny "$(field "$OUT" decision)" "the deny is reported"
  assert_equals "Outside your task; work inside your own copy instead." "$(field "$(t3_fake_calls t3_pending_request | grep '"action":"respond"')" feedback)" "the deny carries its feedback to T3"
  mcp requests --thread thread-a
  assert_equals 0 "$(field "$OUT" pendingRequestCount)" "nothing stays pending after both answers"
  mcp approve --thread thread-a --request req-appr-b --decision allow
  expect_code 3 "$RC" "an approval already answered is T3's own refusal"
  t3_fake_set 'w.threads["thread-a"].runtimeRequests.push({ id: "req-question-2", kind: "user_input", status: "pending", questions: [] })'
  mcp approve --thread thread-a --request req-question-2 --decision allow
  expect_code 4 "$RC" "a request that is not a pending approval is refused"
  assert_equals not_an_approval "$(field "$OUT" error.code)" "the refusal says it is not an approval"

  fresh_case approvals-off
  t3_fake_set 'w.threads = { "thread-a": { threadId: "thread-a", projectId: "p", status: "running", activeRunId: "run-a", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-a", ordinal: 1, status: "running" }],
    runtimeRequests: [{ id: "req-appr-a", kind: "approval", status: "pending", command: "python3 - <<EOF" }] } }'
  mcp requests --thread thread-a
  assert_equals false "$(field "$OUT" approvalResponses)" "a T3 without the flag reports it"
  assert_equals 1 "$(field "$OUT" approvals)" "its approval is counted as unanswerable"
  assert_equals "" "$(field "$OUT" approvalRequests.0.requestId)" "and never listed as answerable"
  : > "$T3_FAKE_LOG"
  mcp approve --thread thread-a --request req-appr-a --decision allow
  expect_code 4 "$RC" "approve refuses a T3 without approvalResponses"
  assert_equals approval_responses_unsupported "$(field "$OUT" error.code)" "the refusal names the missing feature"
  [ -z "$(t3_fake_calls t3_pending_request)" ] || fail "nothing is read or answered on a T3 without the feature"
  pass "fm-t3-mcp approve: approvals are listed with their detail, allowed or denied with feedback by id, and refused on a T3 without approvalResponses"
}

test_watch_is_event_driven_and_bounded() {
  local start elapsed sig ender
  fresh_case watch
  t3_fake_set 'w.threads = { "thread-w": { threadId: "thread-w", projectId: "p", status: "running", activeRunId: "run-w", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-w", ordinal: 1, status: "running" }] }, "thread-idle": { threadId: "thread-idle", projectId: "p", status: "completed", activeRunId: null, archived: false, worktreePath: null, items: [], runs: [] } }'
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runs[0].status = "completed"; w.threads["thread-w"].activeRunId = null; w.threads["thread-w"].status = "completed"' ) &
  ender=$!
  start=$(date +%s)
  mcp watch --thread thread-w --thread thread-idle --timeout-ms 20000
  elapsed=$(( $(date +%s) - start ))
  wait "$ender"
  expect_code 0 "$RC" "watch: $ERR"
  assert_equals run-ended "$(field "$OUT" event)" "a run reaching a terminal status ends the wait"
  assert_equals run-w "$(field "$OUT" runId)" "the ended run is named"
  assert_equals run-w "$(field "$OUT" runIds.0)" "the runs the wait found active are listed"
  assert_equals "" "$(field "$OUT" runIds.1)" "a thread with no active run lists none"
  [ "$elapsed" -lt 10 ] || fail "the run end must wake the wait promptly, took ${elapsed}s"
  assert_equals run-w "$(field "$(t3_fake_calls t3_thread_wait | tail -1)" runId)" "the wait names the exact active run"
  : > "$T3_FAKE_LOG"
  mcp watch --thread thread-w --thread thread-idle --timeout-ms 20000
  assert_equals none "$(field "$OUT" event)" "with no active run the watch returns none instead of waiting"
  [ -z "$(t3_fake_calls t3_thread_wait)" ] || fail "an idle watch must not call t3_thread_wait"
  t3_fake_set 'w.threads["thread-w"].runtimeRequests = [{ id: "req-1", kind: "user_input", status: "pending", questions: [] }]'
  mcp watch --thread thread-w --timeout-ms 200
  assert_equals blocked "$(field "$OUT" event)" "a pending question is a blocked event"
  sig=$(field "$OUT" signature)
  assert_equals 'q:req-1;a:0' "$sig" "the signature names the question ids and approval count"
  mcp watch --thread thread-w --timeout-ms 200 --escalated "thread-w=$sig"
  assert_equals none "$(field "$OUT" event)" "an already-escalated request does not block again"
  t3_fake_set 'w.threads["thread-w"].runtimeRequests[0].status = "resolved"'
  mcp watch --thread thread-w --timeout-ms 200 --escalated "thread-w=$sig"
  assert_equals thread-w "$(field "$OUT" cleared.0)" "an answered request clears the escalation"
  pass "fm-t3-mcp watch: exact-run waits end on a terminal run, idle threads never wait, and pending requests block once per signature"
}

# A request that gets no reply, as from a server that shuts down cleanly before
# answering, proves nothing: a send stays unconfirmed under its request id,
# and a read fails instead of reading as an empty thread.
test_empty_reply_is_never_success() {
  local thread
  fresh_case empty-reply
  thread=$(new_thread)
  printf 'hello once' > "$TMP_ROOT/msg-empty"
  t3_fake_set 'w.emptyReplyTools = { t3_thread_send: 1 }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-empty" --client-request-id req-empty
  expect_code 7 "$RC" "an empty reply to a send is unconfirmed, not a delivery, got '$OUT'"
  assert_equals delivery_unconfirmed "$(field "$OUT" error.code)" "the empty reply is reported as unconfirmed delivery"
  assert_equals 0 "$(t3_fake_items "$thread" "hello once")" "the server committed nothing"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-empty" --client-request-id req-empty
  expect_code 0 "$RC" "a retry under the same request id delivers: $ERR"
  assert_equals 1 "$(t3_fake_items "$thread" "hello once")" "the retried request lands once"
  t3_fake_set 'w.emptyReplyTools = { t3_thread_read: 1 }'
  mcp state --thread "$thread"
  [ "$RC" -ne 0 ] || fail "an empty reply to a thread read must fail, not read as an empty thread, got '$OUT'"
  pass "fm-t3-mcp: an empty reply is never success: a send stays unconfirmed and a read fails"
}

test_helper_runs_through_symlinked_path() {
  ln -sfn "$ROOT/bin" "$TMP_ROOT/bin-link"
  OUT=$(node "$TMP_ROOT/bin-link/fm-t3-mcp.mjs" status --token-file "$TMP_ROOT/no-such-token" 2>"$TMP_ROOT/stderr")
  RC=$?
  expect_code 4 "$RC" "the helper must run its verb when reached through a symlinked path, got '$OUT'"
  assert_equals no_credential "$(field "$OUT" error.code)" "the verb's own refusal must come back through the symlinked path"
  pass "fm-t3-mcp: a helper reached through a symlinked path runs its verb instead of exiting silently"
}

test_watch_reports_failed_waits_not_timeout() {
  fresh_case watch-wait-fails
  t3_fake_set 'w.threads = { "thread-a": { threadId: "thread-a", projectId: "p", status: "running", activeRunId: "run-a", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-a", ordinal: 1, status: "running" }] }, "thread-b": { threadId: "thread-b", projectId: "p", status: "running", activeRunId: "run-b", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-b", ordinal: 1, status: "running" }] } }; w.failTools = { t3_thread_wait: { code: "invalid_request", message: "timeoutMs rejected" } }'
  mcp watch --thread thread-a --thread thread-b --timeout-ms 200
  [ "$RC" -ne 0 ] || fail "every wait failing must fail the watch, got '$OUT'"
  [ "$(field "$OUT" event)" != timeout ] || fail "failed waits must not read as a full-budget timeout"
  assert_contains "$ERR" "timeoutMs rejected" "the watch reports the wait's own failure"
  t3_fake_set 'w.failTools = {}'
  mcp watch --thread thread-a --thread thread-b --timeout-ms 200
  expect_code 0 "$RC" "a wait that ran its budget is an ordinary timeout: $ERR"
  assert_equals timeout "$(field "$OUT" event)" "waits that ran their budget report a timeout"
  pass "fm-t3-mcp watch: waits that all fail are an error, not a timeout"
}

# Approval A is escalated, then answered in T3 Code, and approval B arrives
# before the next watch: the count is unchanged, but B is a new request.
test_watch_escalates_a_replaced_approval() {
  local sig
  fresh_case watch-approvals
  t3_fake_set 'w.threads = { "thread-p": { threadId: "thread-p", projectId: "p", status: "running", activeRunId: "run-p", archived: false, worktreePath: null,
    items: [{ itemId: "item-msg", type: "user_message", status: "completed", text: "go" }, { itemId: "item-appr-a", type: "approval_request", status: "waiting", text: "run rm?" }],
    runs: [{ runId: "run-p", ordinal: 1, status: "running" }],
    runtimeRequests: [{ id: "req-appr-a", kind: "approval", status: "pending" }] } }'
  mcp watch --thread thread-p --timeout-ms 200
  expect_code 0 "$RC" "watch: $ERR"
  assert_equals blocked "$(field "$OUT" event)" "a pending approval is a blocked event"
  sig=$(field "$OUT" signature)
  assert_equals 'q:;a:1:item-appr-a' "$sig" "the signature names the approval's own activity item"
  mcp watch --thread thread-p --timeout-ms 200 --escalated "thread-p=$sig"
  assert_equals timeout "$(field "$OUT" event)" "the escalated approval does not block again"
  t3_fake_set 'const t = w.threads["thread-p"]; t.items[1].status = "completed"; t.runtimeRequests[0].status = "resolved";
    t.items.push({ itemId: "item-appr-b", type: "approval_request", status: "waiting", text: "run curl?" }); t.runtimeRequests.push({ id: "req-appr-b", kind: "approval", status: "pending" })'
  mcp watch --thread thread-p --timeout-ms 200 --escalated "thread-p=$sig"
  expect_code 0 "$RC" "watch after the replacement: $ERR"
  assert_equals blocked "$(field "$OUT" event)" "a replacement approval with the same count is escalated"
  assert_equals 'q:;a:1:item-appr-b' "$(field "$OUT" signature)" "the new signature names the new approval"
  mcp requests --thread thread-p
  assert_equals 'q:;a:1:item-appr-b' "$(field "$OUT" signature)" "requests computes the same signature as watch"
  assert_equals 1 "$(field "$OUT" approvals)" "requests still counts the approval"
  pass "fm-t3-mcp watch: each pending approval is identified, so one answered and replaced between watches escalates again"
}

# A JSON-RPC server error can follow a committed mutation, so only a refusal of
# the request itself is proof that nothing was applied.
test_jsonrpc_server_error_is_not_proven_refusal() {
  local thread project
  fresh_case rpc-server-error
  thread=$(new_thread)
  printf 'committed once' > "$TMP_ROOT/msg-rpc"
  t3_fake_set 'w.rpcErrorTools = { t3_thread_send: -32603 }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-rpc" --client-request-id req-rpc
  expect_code 7 "$RC" "a server error after the send went out is unconfirmed, got '$OUT'"
  assert_equals 1 "$(t3_fake_items "$thread" "committed once")" "the fake committed the send before its error"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-rpc" --client-request-id req-rpc
  expect_code 0 "$RC" "the retry under the same request id: $ERR"
  assert_equals 1 "$(t3_fake_items "$thread" "committed once")" "the retry lands on the committed message"
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  t3_fake_set 'w.rpcErrorTools = { t3_thread_launch: -32603 }'
  mcp launch --project "$project" --title fm-rpc --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launch answered with a server error is uncertain, not refused, got '$OUT'"
  pass "fm-t3-mcp: a JSON-RPC server error after a send or launch is unconfirmed, never a proven refusal"
}

# T3's catch-all orchestration_error, or a tool error without a code, can
# follow a committed send or launch, so it is unconfirmed, while a specific
# typed refusal still proves non-delivery.
test_orchestration_error_is_not_proven_refusal() {
  local thread project
  fresh_case orchestration-error
  thread=$(new_thread)
  printf 'committed before the error' > "$TMP_ROOT/msg-orch"
  t3_fake_set 'w.committedErrorTools = { t3_thread_send: "orchestration_error" }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-orch" --client-request-id req-orch
  expect_code 7 "$RC" "an orchestration_error after the send went out is unconfirmed, got '$OUT'"
  assert_equals delivery_unconfirmed "$(field "$OUT" error.code)" "the send verdict is delivery_unconfirmed"
  assert_equals 1 "$(t3_fake_items "$thread" "committed before the error")" "the fake committed the send before its error"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-orch" --client-request-id req-orch
  expect_code 0 "$RC" "the retry under the same request id: $ERR"
  assert_equals 1 "$(t3_fake_items "$thread" "committed before the error")" "the retry lands on the committed message"
  t3_fake_set 'w.failTools = { t3_thread_send: { code: "thread_not_sendable", message: "Thread is archived and cannot receive messages." } }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-orch" --client-request-id req-refused
  expect_code 3 "$RC" "a specific typed refusal of the send is still proven non-delivery"
  t3_fake_set 'w.failTools = {}'
  printf 'committed before a codeless error' > "$TMP_ROOT/msg-codeless"
  t3_fake_set 'w.committedErrorTools = { t3_thread_send: null }'
  mcp send --thread "$thread" --message-file "$TMP_ROOT/msg-codeless" --client-request-id req-codeless
  expect_code 7 "$RC" "a tool error without a code after the send went out is unconfirmed, got '$OUT'"
  assert_equals 1 "$(t3_fake_items "$thread" "committed before a codeless error")" "the fake committed the send before its codeless error"
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  t3_fake_set 'w.committedErrorTools = { t3_thread_launch: "orchestration_error" }'
  mcp launch --project "$project" --title fm-orch --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launch answered with orchestration_error is uncertain, not refused, got '$OUT'"
  assert_equals launch_unconfirmed "$(field "$OUT" error.code)" "the launch verdict is launch_unconfirmed"
  t3_fake_set 'w.committedErrorTools = { t3_thread_launch: null }'
  mcp launch --project "$project" --title fm-codeless --model-selection "$SEL" --worktree "$WT"
  expect_code 1 "$RC" "a launch answered with a tool error without a code is uncertain, not refused, got '$OUT'"
  assert_equals launch_unconfirmed "$(field "$OUT" error.code)" "the codeless launch verdict is launch_unconfirmed"
  pass "fm-t3-mcp: T3's orchestration_error, or a tool error without a code, after a send or launch is unconfirmed; a specific typed refusal stays proven"
}

# One wait is re-armed in slices under the 300 s Node's fetch allows a reply,
# until the run ends or the caller's own timeout passes.
test_long_wait_rearms_in_slices() {
  local ender first
  fresh_case wait-slices
  t3_fake_set 'w.waitCapMs = 200; w.threads = { "thread-s": { threadId: "thread-s", projectId: "p", status: "running", activeRunId: "run-s", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-s", ordinal: 1, status: "running" }] } }'
  # The fake logs a wait when it answers, so the run ends only after one slice
  # timed out; a fixed delay raced the helper's startup on a loaded runner.
  ( for _ in $(seq 1 250); do [ -z "$(t3_fake_calls t3_thread_wait)" ] || break; sleep 0.02; done
    t3_fake_set 'w.threads["thread-s"].runs[0].status = "completed"; w.threads["thread-s"].activeRunId = null; w.threads["thread-s"].status = "completed"' ) &
  ender=$!
  mcp wait --thread thread-s --run run-s --timeout-ms 600000
  wait "$ender"
  expect_code 0 "$RC" "wait: $ERR"
  assert_equals completed "$(field "$OUT" status)" "the wait outlasts each bounded slice until the run ends"
  assert_equals false "$(field "$OUT" timedOut)" "a run that ended inside the caller's timeout is not a timeout"
  first=$(t3_fake_calls t3_thread_wait | head -1)
  assert_equals 240000 "$(field "$first" timeoutMs)" "one wait asks T3 for at most 240 s"
  [ "$(t3_fake_calls t3_thread_wait | wc -l)" -ge 2 ] || fail "a slice that timed out before the deadline must re-arm"
  pass "fm-t3-mcp wait: a long wait re-arms in slices under Node's 300 s reply limit"
}

test_capture_clamps_lines_and_closes_session() {
  local thread
  fresh_case capture-clamp
  thread=$(new_thread)
  FM_T3_THREAD="$thread" t3_fake_set 'w.threads[process.env.FM_T3_THREAD].items = Array.from({ length: 600 }, (_, i) => ({ type: "assistant_message", status: "completed", text: "item " + i }));'
  : > "$T3_FAKE_LOG"
  mcp capture --thread "$thread" --lines 1000
  expect_code 0 "$RC" "a capture above 500 lines reads the last 500: $ERR"
  assert_equals 500 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "a capture above 500 lines prints exactly 500"
  assert_equals "[assistant_message/completed] item 101" "$(printf '%s\n' "$OUT" | head -1)" "the clamped capture shows the newest items up to the status line"
  case "$(printf '%s\n' "$OUT" | tail -1)" in 't3code: status='*) ;; *) fail "the clamped capture still ends with the status line, got '$OUT'" ;; esac
  assert_grep '"method":"DELETE","session":"sess-fake"' "$T3_FAKE_LOG" "the verb ends the MCP session it opened"
  pass "fm-t3-mcp capture: --lines above 500 reads the last 500, and the verb ends its MCP session"
}

test_gate_refuses_pre_0_1_3_tool_names() {
  fresh_case pre-0-1-3
  t3_fake_set 'w.tools = ["t3_thread_launch","t3_thread_send","t3_thread_read","t3_thread_wait","t3_thread_interrupt","t3_thread_organize","t3_thread_list","t3_thread_configuration","t3_project_list","t3_project_create","t3_pending_request_list","t3_pending_request_read","t3_pending_request_respond","orchestrator_capabilities","t3_environment_read"]'
  mcp status
  expect_code 4 "$RC" "a T3 offering only the tool names from before 0.1.3 must be refused"
  assert_equals capability_gate "$(field "$OUT" error.code)" "the refusal should be the capability gate"
  assert_contains "$ERR" "lacks t3_thread_configure, t3_pending_request" "the refusal names the merged tools it lacks"
  pass "fm-t3-mcp gate: refuses a T3 offering only the tool names from before 0.1.3"
}

test_launch_reads_binding_through_configure() {
  local project sel='{"instanceId":"codex","model":"gpt-5.6-sol","options":[{"id":"reasoningEffort","value":"high"}]}'
  fresh_case configure-read
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title read --model-selection "$sel" --worktree "$WT"
  expect_code 0 "$RC" "a launch reads its binding back through t3_thread_configure: $ERR"
  assert_equals 1 "$(t3_fake_calls t3_thread_configure | grep -c threadId)" "the binding is read once through t3_thread_configure"
  assert_not_contains "$(t3_fake_calls t3_thread_configure)" modelSelection "the configuration read never sends a modelSelection"
  pass "fm-t3-mcp launch: the binding read-back is t3_thread_configure without a modelSelection"
}

# A zero budget is the watcher's read beside another backend's wait: it
# reports a fresh pending request with its detail and otherwise answers at
# once, never waiting on the run.
test_watch_zero_budget_reads_pending_requests_only() {
  local started elapsed sig
  fresh_case watch-zero-budget
  t3_fake_set 'w.approvalResponses = true; w.threads = { "thread-w": { threadId: "thread-w", projectId: "p", status: "running", activeRunId: "run-w", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-w", ordinal: 1, status: "running" }] } }'
  started=$(date +%s)
  mcp watch --thread thread-w --timeout-ms 0
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$RC" "a zero-budget watch: $ERR"
  assert_equals none "$(field "$OUT" event)" "with nothing pending a zero budget answers none at once"
  [ "$elapsed" -lt 5 ] || fail "a zero budget must not wait on the running run, took ${elapsed}s"
  [ -z "$(t3_fake_calls t3_thread_wait)" ] || fail "a zero budget must not call t3_thread_wait"
  # shellcheck disable=SC2016  # $OUT is part of the approval's literal command.
  t3_fake_set 'w.threads["thread-w"].runtimeRequests = [{ id: "req-rm", kind: "approval", status: "pending", requestKind: "command", command: "rm -rf \"$OUT\"/frames", reason: "Dangerous rm operation on possibly-empty variable path", override: "provider_check" }]'
  mcp watch --thread thread-w --timeout-ms 0
  expect_code 0 "$RC" "a zero-budget watch with an approval pending: $ERR"
  assert_equals blocked "$(field "$OUT" event)" "a pending approval is a blocked event under a zero budget"
  assert_equals req-rm "$(field "$OUT" approvalRequests.0.requestId)" "the approval is named"
  assert_equals provider_check "$(field "$OUT" approvalRequests.0.override)" "the approval carries its override"
  sig=$(field "$OUT" signature)
  mcp watch --thread thread-w --timeout-ms 0 --escalated "thread-w=$sig"
  assert_equals none "$(field "$OUT" event)" "an already-escalated approval does not block again"
  [ -z "$(t3_fake_calls t3_thread_wait)" ] || fail "a zero budget never waits on the run"
  mcp watch --thread thread-w --timeout-ms -1
  expect_code 2 "$RC" "a negative budget is still a usage error: $OUT"
  pass "fm-t3-mcp watch --timeout-ms 0: reads pending requests with their detail and answers at once without waiting"
}

calls() {  # <tool> -> how many calls to <tool> the fake logged
  t3_fake_calls "$1" | wc -l | tr -d ' '
}

# On the T3 Code fork the run wait itself ends the moment a question or
# approval appears (settleOnPendingRequest) and carries the pending requests,
# so a mid-wait request is the same blocked event the first read reports, with
# no thread re-read and no pending-request list call; a known request never
# re-settles it, and a run end or the budget still does.
test_watch_pending_push_ends_the_wait() {
  local started elapsed bg_pid sig call
  fresh_case watch-pending-push
  t3_fake_set 'w.approvalResponses = true; w.pendingPush = true; w.threads = { "thread-w": { threadId: "thread-w", projectId: "p", status: "running", activeRunId: "run-w", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-w", ordinal: 1, status: "running" }], runtimeRequests: [] } }'
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runtimeRequests.push({ id: "req-touch", kind: "approval", status: "pending", requestKind: "command", command: "touch probe.txt", override: "provider_check" })' ) &
  bg_pid=$!
  started=$(date +%s)
  mcp watch --thread thread-w --timeout-ms 20000
  wait "$bg_pid"
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$RC" "watch with an approval arriving mid-wait: $ERR"
  assert_equals blocked "$(field "$OUT" event)" "an approval that appears while the run still runs ends the wait"
  assert_equals req-touch "$(field "$OUT" approvalRequests.0.requestId)" "the mid-wait approval is named by request id"
  assert_equals "touch probe.txt" "$(field "$OUT" approvalRequests.0.detail)" "the mid-wait approval carries its command"
  assert_equals "q:;a:0;r:req-touch" "$(field "$OUT" signature)" "the mid-wait signature is the one the first read computes"
  [ "$elapsed" -lt 5 ] || fail "the approval must end the wait through the push, took ${elapsed}s"
  call=$(t3_fake_calls t3_thread_wait | tail -1)
  assert_equals true "$(field "$call" settleOnPendingRequest)" "the run wait asks T3 to end on a new request"
  assert_equals '[]' "$(field "$call" knownRequestIds)" "with nothing pending at the start no request id is known"
  assert_equals 1 "$(calls t3_thread_read)" "only the opening read reads the thread; nothing re-reads it while it waits"
  assert_equals 0 "$(calls t3_pending_request)" "the push carries the pending requests, so no list call follows it"
  sig=$(field "$OUT" signature)
  : > "$T3_FAKE_LOG"
  mcp watch --thread thread-w --timeout-ms 2500 --escalated "thread-w=$sig"
  assert_equals timeout "$(field "$OUT" event)" "an approval already escalated never ends a later wait"
  assert_equals 1 "$(calls t3_thread_wait)" "a known request never settles the wait, so it is never re-armed"
  assert_equals '["req-touch"]' "$(field "$(t3_fake_calls t3_thread_wait)" knownRequestIds)" "the opening read's request ids ride as known"
  assert_equals 1 "$(calls t3_pending_request)" "only the opening read lists the pending requests"
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runtimeRequests.push({ id: "req-curl", kind: "approval", status: "pending", requestKind: "command", command: "curl example.com" })' ) &
  bg_pid=$!
  mcp watch --thread thread-w --timeout-ms 20000 --escalated "thread-w=$sig"
  wait "$bg_pid"
  assert_equals blocked "$(field "$OUT" event)" "a second approval beside an escalated one ends the wait"
  assert_equals "q:;a:0;r:req-curl,req-touch" "$(field "$OUT" signature)" "the new set names both approvals"
  sig=$(field "$OUT" signature)
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runs[0].status = "completed"; w.threads["thread-w"].activeRunId = null; w.threads["thread-w"].status = "completed"' ) &
  bg_pid=$!
  started=$(date +%s)
  mcp watch --thread thread-w --timeout-ms 20000 --escalated "thread-w=$sig"
  wait "$bg_pid"
  elapsed=$(( $(date +%s) - started ))
  assert_equals run-ended "$(field "$OUT" event)" "a run end still ends a push wait"
  assert_equals completed "$(field "$OUT" status)" "the run's terminal status is reported"
  [ "$elapsed" -lt 5 ] || fail "the run end must end the push wait promptly, took ${elapsed}s"
  t3_fake_set 'w.threads["thread-i"] = { threadId: "thread-i", projectId: "p", status: "completed", activeRunId: null, archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-i", ordinal: 1, status: "completed" }], runtimeRequests: [] }'
  : > "$T3_FAKE_LOG"
  ( sleep 0.5; t3_fake_set 'w.threads["thread-i"].runtimeRequests.push({ id: "req-q", kind: "user_input", status: "pending", questions: [] })' ) &
  bg_pid=$!
  mcp watch --thread thread-i --timeout-ms 2000
  wait "$bg_pid"
  assert_equals none "$(field "$OUT" event)" "a thread idle when the wait began answers none, so the caller sleeps the budget"
  assert_equals 1 "$(calls t3_thread_read)" "an idle thread is read once"
  mcp watch --thread thread-i --timeout-ms 0
  assert_equals blocked "$(field "$OUT" event)" "the next call's opening read reports the idle thread's question"
  assert_equals req-q "$(field "$OUT" questions.0)" "the question is named"
  pass "fm-t3-mcp watch: on the fork a mid-wait question or approval ends the run wait through T3's push, once per set, with no re-read"
}

# A T3 whose t3_thread_wait lacks settleOnPendingRequest gets no per-second
# re-read in its place: Firstmate requires the fork, so a mid-wait request
# waits for the next call's opening read, and status warns.
test_watch_without_pending_push_reads_at_the_next_call() {
  local bg_pid
  fresh_case watch-no-push
  t3_fake_set 'w.approvalResponses = true; w.threads = { "thread-w": { threadId: "thread-w", projectId: "p", status: "running", activeRunId: "run-w", archived: false, worktreePath: null, items: [],
    runs: [{ runId: "run-w", ordinal: 1, status: "running" }], runtimeRequests: [] } }'
  ( sleep 0.5; t3_fake_set 'w.threads["thread-w"].runtimeRequests.push({ id: "req-touch", kind: "approval", status: "pending", requestKind: "command", command: "touch probe.txt" })' ) &
  bg_pid=$!
  mcp watch --thread thread-w --timeout-ms 2000
  wait "$bg_pid"
  expect_code 0 "$RC" "watch on a T3 without the push: $ERR"
  assert_equals timeout "$(field "$OUT" event)" "without the push a mid-wait approval does not end the wait"
  assert_equals "" "$(field "$(t3_fake_calls t3_thread_wait)" settleOnPendingRequest)" "the flag is sent only where t3_thread_wait declares it"
  assert_equals 1 "$(calls t3_thread_read)" "no re-read loop runs in the push's place"
  assert_equals 0 "$(calls t3_pending_request)" "no pending-request list runs while it waits"
  mcp watch --thread thread-w --timeout-ms 0
  assert_equals blocked "$(field "$OUT" event)" "the next call's opening read reports the approval"
  assert_equals req-touch "$(field "$OUT" approvalRequests.0.requestId)" "the approval is named"
  mcp status
  assert_equals false "$(field "$OUT" pendingRequestPush)" "status reports the missing push"
  assert_contains "$ERR" "settleOnPendingRequest" "status warns, naming the missing argument"
  t3_fake_set 'w.pendingPush = true'
  mcp status
  assert_equals true "$(field "$OUT" pendingRequestPush)" "status reports the fork's push"
  assert_not_contains "$ERR" "settleOnPendingRequest" "the fork's push needs no warning"
  pass "fm-t3-mcp watch: without the fork's push no re-read loop runs; the next call's opening read reports the request, and status warns"
}

# The one adapter table: every row resolves through T3's catalog the same
# way, an ACP registry row finds its instance by agent whatever T3 named it
# and refuses none or several, a named instance must report the row's agent,
# an instance that cannot run full-access is refused, and an effort word maps
# only onto a catalog value of the same name.
test_resolve_selection_adapter_rows() {
  local project
  fresh_case resolve-rows
  mcp harness --harness grok
  expect_code 0 "$RC" "harness reads the table without a server call: $ERR"
  assert_equals grok "$(field "$OUT" driverKind)" "the grok row runs on the grok driver"
  assert_equals reasoningEffort "$(field "$OUT" effortOption)" "the grok row carries effort as reasoningEffort"
  mcp harness --harness cursor
  assert_equals acpRegistry "$(field "$OUT" driverKind)" "the cursor row runs on the ACP registry driver"
  assert_equals cursor "$(field "$OUT" agentId)" "the cursor row runs the registry's cursor agent"
  mcp harness --harness omp
  expect_code 4 "$RC" "a harness with no T3 driver is refused"
  assert_equals harness_unsupported "$(field "$OUT" error.code)" "the refusal code names the unsupported harness"
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp resolve-selection --harness grok --model grok-4.7-build-fast --effort low --project "$project"
  expect_code 0 "$RC" "grok resolves on its default instance: $ERR"
  assert_equals '{"instanceId":"grok","model":"grok-4.7-build-fast","options":[{"id":"reasoningEffort","value":"low"}]}' "$(field "$OUT" selection)" \
    "a grok effort rides reasoningEffort on the grok instance"
  assert_equals false "$(field "$OUT" threadEnvironment)" "an instance that does not advertise a per-thread environment reads false"
  mcp resolve-selection --harness grok --model grok-4.7 --effort max --project "$project"
  expect_code 4 "$RC" "an effort word the catalog lacks is refused, never mapped onto a neighbour"
  assert_contains "$ERR" "xhigh, high, medium, low" "the refusal lists the catalog's values"
  mcp resolve-selection --harness grok --model grok-4.7 --effort huge --project "$project"
  expect_code 2 "$RC" "a word that is not a Firstmate effort word is invalid use"
  t3_fake_set 'w.threadFacts = true'
  mcp resolve-selection --harness grok --model grok-4.7 --effort default --project "$project"
  assert_equals true "$(field "$OUT" threadEnvironment)" "an advertised per-thread environment reads true"
  assert_equals true "$(field "$OUT" threadInstructions)" "advertised per-thread instructions read true"
  t3_fake_set 'w.providers = [
    { providerInstanceId: "pi", driverKind: "pi", constraints: [], runtimeModes: ["approval-required", "auto"], models: [{ id: "default", options: [] }] },
    { providerInstanceId: "antigravity", driverKind: "antigravity", constraints: [], models: [{ id: "agy-1", options: [{ id: "thought_level", values: ["low", "high"] }] }] },
    { providerInstanceId: "cursor", driverKind: "cursor", constraints: [], models: [{ id: "c-1", options: [] }] },
    { providerInstanceId: "acpRegistry_cursor", driverKind: "acpRegistry", agentId: "cursor", constraints: [], models: [{ id: "c-1", options: [{ id: "effort", values: ["low"] }, { id: "reasoning", values: ["low"] }] }] },
    { providerInstanceId: "gemini", driverKind: "acpRegistry", constraints: [], models: [{ id: "g-1", options: [] }] },
    { providerInstanceId: "acpRegistry_kimi_cli", driverKind: "acpRegistry", agentId: "kimi", constraints: [], models: [{ id: "k-1", options: [] }] },
    { providerInstanceId: "acpRegistry_devin", driverKind: "acpRegistry", agentId: "devin", constraints: [], models: [{ id: "d-1", options: [] }] },
    { providerInstanceId: "devin-2", driverKind: "acpRegistry", agentId: "devin", constraints: [], models: [{ id: "d-1", options: [] }] }]'
  mcp resolve-selection --harness pi --model default --effort default --project "$project"
  expect_code 4 "$RC" "an instance whose runtimeModes lack full-access is refused"
  assert_equals full_access_unsupported "$(field "$OUT" error.code)" "the refusal names the missing full-access mode"
  mcp resolve-selection --harness agy --model agy-1 --effort high --project "$project"
  expect_code 0 "$RC" "a from-catalog row finds the model's one effort option: $ERR"
  assert_equals '{"instanceId":"antigravity","model":"agy-1","options":[{"id":"thought_level","value":"high"}]}' "$(field "$OUT" selection)" \
    "agy effort rides the catalog's thought_level option"
  mcp resolve-selection --harness cursor --model c-1 --effort low --project "$project"
  expect_code 4 "$RC" "a model offering several effort options is refused rather than guessed"
  assert_contains "$ERR" "several effort options (effort, reasoning)" "the refusal names the candidate options"
  mcp resolve-selection --harness cursor --model c-1 --effort default --project "$project"
  expect_code 0 "$RC" "the same model with no effort override resolves: $ERR"
  assert_equals acpRegistry_cursor "$(field "$OUT" selection.instanceId)" "cursor runs on the registry's cursor agent, never T3's in-process cursor driver"
  assert_equals acpRegistry "$(field "$OUT" driverKind)" "the cursor selection reports the ACP registry driver"
  mcp resolve-selection --harness cursor --instance cursor --model c-1 --effort default --project "$project"
  expect_code 4 "$RC" "a cursor harness mapped onto T3's in-process cursor driver is refused"
  assert_equals driver_mismatch "$(field "$OUT" error.code)" "the refusal names the driver mismatch"
  mcp resolve-selection --harness kimi --model k-1 --effort default --project "$project"
  expect_code 0 "$RC" "an ACP registry instance is found by its agent, whatever T3 named it: $ERR"
  assert_equals acpRegistry_kimi_cli "$(field "$OUT" selection.instanceId)" "the kimi row binds the instance that reports the kimi agent"
  mcp resolve-selection --harness gemini --model g-1 --effort default --project "$project"
  expect_code 4 "$RC" "an instance named after the harness that reports no agent is not taken as that agent's"
  assert_equals instance_unknown "$(field "$OUT" error.code)" "the refusal says no instance runs the agent"
  assert_contains "$ERR" "no ACP registry instance running the 'gemini' agent" "the refusal names the missing agent"
  assert_contains "$ERR" "config/t3code-instances" "the refusal names the explicit mapping"
  mcp resolve-selection --harness gemini --instance acpRegistry_kimi_cli --model k-1 --effort default --project "$project"
  expect_code 4 "$RC" "a named ACP registry instance running another agent is refused"
  assert_equals agent_mismatch "$(field "$OUT" error.code)" "the refusal names the agent mismatch"
  assert_contains "$ERR" "runs the ACP registry agent 'kimi', not 'gemini'" "the refusal names both agents"
  mcp resolve-selection --harness gemini --instance gemini --model g-1 --effort default --project "$project"
  expect_code 4 "$RC" "a named ACP registry instance that does not report its agent is refused"
  assert_contains "$ERR" "does not report which ACP registry agent it runs" "the refusal says the agent is unverifiable"
  mcp resolve-selection --harness devin --model d-1 --effort default --project "$project"
  expect_code 4 "$RC" "two instances running the row's agent are refused rather than guessed"
  assert_equals instance_ambiguous "$(field "$OUT" error.code)" "the refusal names the ambiguity"
  assert_contains "$ERR" "(acpRegistry_devin, devin-2)" "the refusal names every candidate"
  mcp resolve-selection --harness devin --instance devin-2 --model d-1 --effort default --project "$project"
  expect_code 0 "$RC" "config/t3code-instances settles which instance of an agent runs the harness: $ERR"
  assert_equals devin-2 "$(field "$OUT" selection.instanceId)" "the named instance is the one bound"
  pass "fm-t3-mcp resolve-selection: every adapter row resolves through T3's catalog; registry instances are found by agent; agent, ambiguity, full-access, and effort mapping refuse what they cannot prove"
}

# T3 lists a short set of models per instance and counts the rest in
# omittedModels; an exact slug outside that set is searched for before it is
# refused, and only an exact id from the search counts.
test_resolve_selection_searches_omitted_models() {
  local project searches
  fresh_case resolve-omitted
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  t3_fake_set 'w.providers = [
    { providerInstanceId: "codex", driverKind: "codex", constraints: [],
      models: [{ id: "gpt-6-luna", options: [{ id: "reasoningEffort", values: ["low", "medium"] }] }],
      omitted: ["gpt-5.6-luna", "gpt-5.6-luna-pro"].map((id) => ({ id, options: [{ id: "reasoningEffort", values: ["low", "medium", "high"] }] })) },
    { providerInstanceId: "opencode", driverKind: "opencode", constraints: [], runtimeModes: ["approval-required", "full-access"],
      models: [{ id: "opencode/big-pickle" }],
      omitted: [{ id: "kimi-code/k3", label: "Kimi K3", options: [{ id: "variant", values: ["low", "high"] }] }] }]'
  mcp resolve-selection --harness codex --model gpt-5.6-luna --effort high --project "$project"
  expect_code 0 "$RC" "a model outside the short list is found by searching the catalog: $ERR"
  assert_equals '{"instanceId":"codex","model":"gpt-5.6-luna","options":[{"id":"reasoningEffort","value":"high"}]}' "$(field "$OUT" selection)" \
    "the searched model's own option descriptors carry the effort"
  assert_contains "$(t3_fake_calls orchestrator_capabilities)" '{"search":"gpt-5.6-luna"}' "the catalog is searched for the exact slug"
  mcp resolve-selection --harness opencode --model kimi-code/k3 --effort high --project "$project"
  expect_code 0 "$RC" "an omitted OpenCode model is found the same way: $ERR"
  assert_equals kimi-code/k3 "$(field "$OUT" selection.model)" "the searched slug is the bound model"
  searches=$(t3_fake_calls orchestrator_capabilities | grep -c search)
  mcp resolve-selection --harness codex --model gpt-6-luna --effort low --project "$project"
  expect_code 0 "$RC" "a listed model resolves: $ERR"
  assert_equals "$searches" "$(t3_fake_calls orchestrator_capabilities | grep -c search)" "a model in the short list needs no search"
  mcp resolve-selection --harness codex --model gpt-5.6 --effort default --project "$project"
  expect_code 4 "$RC" "a slug the search matches only as a substring is refused"
  assert_equals model_unknown "$(field "$OUT" error.code)" "the refusal names the unknown model"
  t3_fake_set 'w.noSearch = true'
  mcp resolve-selection --harness codex --model gpt-5.6-luna --effort default --project "$project"
  expect_code 4 "$RC" "a T3 that does not declare search refuses an unlisted model"
  assert_equals model_unknown "$(field "$OUT" error.code)" "the refusal names the unknown model"
  pass "fm-t3-mcp resolve-selection: an exact slug among T3's omitted models is found by catalog search, a substring match or a T3 without search is refused"
}

# --model default reads the project rooted at --root without creating it.
test_resolve_selection_by_root_is_read_only() {
  fresh_case resolve-root
  mcp resolve-selection --harness claude --model default --effort default --root "$TMP_ROOT/proj"
  expect_code 4 "$RC" "a default model on a root T3 has no project for is refused"
  assert_equals project_not_found "$(field "$OUT" error.code)" "the refusal names the missing project"
  [ -z "$(t3_fake_mutations)" ] || fail "a resolve by root must not create the project, got '$(t3_fake_mutations)'"
  mcp project-ensure --root "$TMP_ROOT/proj"
  FM_T3_ID="$(field "$OUT" projectId)" t3_fake_set 'w.projects.find((p) => p.id === process.env.FM_T3_ID).defaultModelSelection = { instanceId: "claudeAgent", model: "claude-haiku-5-5" }'
  mcp resolve-selection --harness claude --model default --effort low --root "$TMP_ROOT/proj"
  expect_code 0 "$RC" "a default model resolves from the project rooted there: $ERR"
  assert_equals claude-haiku-5-5 "$(field "$OUT" selection.model)" "the project's default model is used"
  pass "fm-t3-mcp resolve-selection --root: the default model comes from the live project at that root, never a created one"
}

# On a server with per-thread facts the launch carries the environment and
# instructions and proves they bound; a server that drops them, rebinds them,
# or runs the driver below full access is refused with the thread archived.
test_launch_binds_thread_environment_and_instructions() {
  local project call envf="$TMP_ROOT/thread-env.json" instr="$TMP_ROOT/thread-instructions"
  fresh_case launch-thread-facts '{"threadFacts":true}'
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  printf '{"FM_TASK_ID":"t1","GOTMPDIR":"/tmp/fm-t1/gotmp"}' > "$envf"
  printf 'You are a task worker launched by Firstmate.' > "$instr"
  mcp launch --project "$project" --title env --model-selection "$SEL" --worktree "$WT" --environment-file "$envf" --instructions-file "$instr"
  expect_code 0 "$RC" "a launch whose environment and instructions read back succeeds: $ERR"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals '{"FM_TASK_ID":"t1","GOTMPDIR":"/tmp/fm-t1/gotmp"}' "$(field "$call" environment)" "the launch carries the environment"
  assert_equals 'You are a task worker launched by Firstmate.' "$(field "$call" instructions)" "the launch carries the instructions verbatim"
  mcp launch --project "$project" --title plain --model-selection "$SEL" --worktree "$WT"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals "" "$(field "$call" environment)" "a launch without an environment file sends none"
  t3_fake_set 'w.bindEnvironment = { FM_TASK_ID: "other" }'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title rebound --model-selection "$SEL" --worktree "$WT" --environment-file "$envf"
  expect_code 4 "$RC" "a thread whose environment reads back different is refused"
  assert_contains "$ERR" "environment differs" "the refusal names the environment"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-bound thread is archived"
  t3_fake_set 'delete w.bindEnvironment; w.bindEffectiveRuntimeMode = "approval-required"'
  mcp launch --project "$project" --title downgraded --model-selection "$SEL" --worktree "$WT"
  expect_code 4 "$RC" "a thread T3 runs below full access is refused even when its record says full-access"
  assert_contains "$ERR" "effectiveRuntimeMode approval-required" "the refusal names the effective mode"
  t3_fake_set 'delete w.bindEffectiveRuntimeMode; delete w.threadFacts'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title upstream --model-selection "$SEL" --worktree "$WT" --environment-file "$envf" --instructions-file "$instr"
  expect_code 4 "$RC" "a server that drops the per-thread fields is refused rather than trusted"
  assert_contains "$ERR" "environment not bound" "the refusal says the environment did not bind"
  assert_contains "$ERR" "instructions not bound" "the refusal says the instructions did not bind"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the unbound thread is archived"
  printf '{"BAD-NAME":"x"}' > "$envf"
  mcp launch --project "$project" --title bad --model-selection "$SEL" --worktree "$WT" --environment-file "$envf"
  expect_code 2 "$RC" "an environment name that is not a shell variable is invalid use"
  pass "fm-t3-mcp launch: per-thread environment and instructions are sent and proven bound, and an effective downgrade is refused"
}

test_launch_names_its_crew_parent() {
  local project main call
  fresh_case launch-crew '{"crewLineage":true}'
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title main --model-selection "$SEL"
  main=$(field "$OUT" threadId)
  assert_equals "" "$(field "$OUT" parentThreadId)" "a launch without --parent names no parent"
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --parent "$main"
  expect_code 0 "$RC" "a launch that reads back as crew of its parent succeeds: $ERR"
  assert_equals "$main" "$(field "$OUT" parentThreadId)" "the result names the parent T3 bound"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals "$main" "$(field "$call" parentThreadId)" "the launch carries the parent where the schema declares it"
  t3_fake_set 'w.bindRelationship = "fork"'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title forked --model-selection "$SEL" --worktree "$WT" --parent "$main"
  expect_code 4 "$RC" "a thread that reads back as anything but crew is refused"
  assert_contains "$ERR" "lineage fork" "the refusal names the lineage T3 recorded"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-bound thread is archived"
  t3_fake_set 'w.bindRelationship = "crew"; w.bindParent = "mcp:someone-else"'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title misparented --model-selection "$SEL" --worktree "$WT" --parent "$main"
  expect_code 4 "$RC" "a crew thread under another parent is refused"
  assert_contains "$ERR" "under mcp:someone-else" "the refusal names the parent T3 recorded"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-parented thread is archived"
  t3_fake_set 'delete w.bindRelationship; delete w.bindParent'
  mcp launch --project "$project" --title orphan --model-selection "$SEL" --worktree "$WT" --parent mcp:missing
  expect_code 3 "$RC" "T3's refusal of an unknown parent launches nothing"
  t3_fake_set 'delete w.crewLineage'
  : > "$T3_FAKE_LOG"
  mcp launch --project "$project" --title upstream --model-selection "$SEL" --worktree "$WT" --parent "$main"
  expect_code 0 "$RC" "a T3 without crew lineage launches without the parent: $ERR"
  assert_equals "" "$(field "$OUT" parentThreadId)" "the result says no parent bound"
  call=$(t3_fake_calls t3_thread_launch | tail -1)
  assert_equals "" "$(field "$call" parentThreadId)" "an undeclared parent is never sent"
  mcp launch --project "$project" --title empty --model-selection "$SEL" --worktree "$WT" --parent ""
  expect_code 2 "$RC" "an empty --parent is invalid use"
  pass "fm-t3-mcp launch: --parent rides only where the launch schema declares it and must read back as crew of exactly that parent"
}

# t3_family <worker-status> <child-status> <grandchild-status>: a worker
# thread with a delegated child and grandchild on the same project.
# shellcheck disable=SC2016  # ${...} belongs to the JavaScript snippet.
t3_family() {
  FM_W="$1" FM_C="$2" FM_G="$3" t3_fake_set '
const run = (id, status) => ({ runId: id, ordinal: 1, status, requestedAt: "2026-10-31T00:00:00Z", startedAt: "2026-10-31T00:00:00Z", completedAt: null });
const active = (s) => ["preparing", "queued", "starting", "running", "waiting"].includes(s);
const mk = (id, status, parent) => ({ threadId: id, projectId: "proj-fam", title: id, status, activeRunId: active(status) ? `run-${id}` : null,
  latestRunId: `run-${id}`, archived: false, worktreePath: null, pendingRequestCount: 0, providerInstanceId: "claudeAgent", runtimeMode: "full-access",
  parentThreadId: parent, relationshipToParent: parent ? "subagent" : null, items: [], runs: [run(`run-${id}`, status)] });
w.threads = { worker: mk("worker", process.env.FM_W, null), child: mk("child", process.env.FM_C, "worker"),
  grandchild: mk("grandchild", process.env.FM_G, "child"), stranger: mk("stranger", "running", null) };'
}

# close: Stop reaches a running worker's delegated threads at any depth where
# the server's schema declares stop, and the close proof refuses while any of
# them still runs (archive alone does not stop them).
test_close_stops_delegated_threads() {
  local call
  fresh_case close-family
  t3_family running running running
  mcp close --thread worker
  expect_code 0 "$RC" "close stops the worker and its delegated threads: $ERR"
  assert_equals true "$(field "$OUT" closed)" "the close is proven"
  call=$(t3_fake_calls t3_thread_interrupt | tail -1)
  assert_equals true "$(field "$call" stop)" "close sends Stop where the schema declares it"
  assert_equals worker "$(field "$call" threadId)" "Stop targets the worker thread itself"
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
for (const id of ["child", "grandchild"]) if (w.threads[id].activeRunId) { console.error(id + " still runs"); process.exit(1); }
if (!w.threads.stranger.activeRunId) { console.error("an unrelated thread was stopped"); process.exit(1); }' "$T3_FAKE_WORLD" \
    || fail "Stop must end every delegated thread below the worker and nothing else"
  fresh_case close-idle-parent
  t3_family completed completed running
  mcp close --thread worker
  expect_code 0 "$RC" "an idle worker with a running grandchild is still stopped: $ERR"
  assert_equals true "$(field "$(t3_fake_calls t3_thread_interrupt | tail -1)" stop)" "a running descendant alone triggers Stop"
  fresh_case close-no-stop '{"noStop":true}'
  t3_family completed running completed
  FM_T3CODE_ARCHIVE_TIMEOUT_MS=300 mcp close --thread worker
  expect_code 1 "$RC" "without Stop a running delegated thread leaves the close unproven"
  assert_equals close_unproven "$(field "$OUT" error.code)" "the refusal is the unproven close"
  assert_contains "$ERR" "delegated thread(s) child still run" "the refusal names the running child"
  [ -z "$(t3_fake_calls t3_thread_interrupt)" ] || fail "a server without Stop gets no interrupt for an idle worker"
  t3_fake_set 'w.threads.child.status = "completed"; w.threads.child.activeRunId = null; w.threads.child.runs[0].status = "completed"'
  mcp close --thread worker
  expect_code 0 "$RC" "once the child ends, the archived worker closes: $ERR"
  fresh_case close-plain
  t3_family completed completed completed
  mcp close --thread worker
  expect_code 0 "$RC" "an idle worker with nothing running below it closes: $ERR"
  [ "$(t3_fake_mutations)" = t3_thread_organize ] || fail "an idle worker with no running child is only archived, got '$(t3_fake_mutations)'"
  mcp close --thread worker
  expect_code 0 "$RC" "an archived worker with nothing running is already closed: $ERR"
  [ "$(t3_fake_mutations)" = t3_thread_organize ] || fail "an already-closed worker gets no further mutation, got '$(t3_fake_mutations)'"
  mcp close --thread gone
  assert_equals true "$(field "$OUT" missing)" "a thread the server lacks is closed"
  pass "fm-t3-mcp close: Stop ends a worker's delegated threads at any depth, and the close proof refuses while one still runs"
}

review_thread() {  # <id> <status> [archived] [worktree] -> one hand-written thread in the world
  FM_T3_ID=$1 FM_T3_STATUS=$2 FM_T3_ARCHIVED=${3:-false} FM_T3_WT=${4:-$WT} t3_fake_set '
const run = process.env.FM_T3_STATUS === "running" ? "run-1" : null;
w.threads = w.threads || {};
w.threads[process.env.FM_T3_ID] = { threadId: process.env.FM_T3_ID, projectId: "proj-1", status: process.env.FM_T3_STATUS, activeRunId: run,
  archived: process.env.FM_T3_ARCHIVED === "true", worktreePath: process.env.FM_T3_WT, pendingRequestCount: 0, items: [],
  runs: run ? [{ runId: run, ordinal: 1, status: "running" }] : [] };'
}

notes_on() {  # <thread-id> -> how many note items the thread holds
  node -e 'const w = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String((w.threads[process.argv[2]].items || []).filter((i) => i.note).length))' "$T3_FAKE_WORLD" "$1"
}

test_review_publish_keeps_the_thread_without_a_note() {
  fresh_case review-publish '{"reviews":true}'
  review_thread scout completed
  mcp review-support
  expect_code 0 "$RC" "review-support reads the gate: $ERR"
  assert_equals 'true' "$(field "$OUT" supported)" "the fork keeps threads for their reader"
  mcp review-publish --thread scout --tag 'waiting for captain'
  expect_code 0 "$RC" "publication succeeds on an idle thread: $ERR"
  assert_equals published "$(field "$OUT" outcome)" "the thread is kept"
  assert_equals '["waiting for captain"]' "$(field "$OUT" tags)" "the read-back carries the exact tag"
  assert_equals 0 "$(notes_on scout)" "nothing is posted into the thread"
  [ -z "$(t3_fake_calls t3_thread_note)" ] || fail "publication never calls the note tool"
  node -e 'const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).threads.scout;
if ((t.runs || []).length || t.activeRunId || t.status !== "completed") { console.error("publication started a run"); process.exit(1); }
if (t.autoSettleDisabled !== true) { console.error("automatic settling stayed on"); process.exit(1); }' "$T3_FAKE_WORLD" \
    || fail "publication must start no run and switch automatic settling off"
  assert_equals 'tag disable_auto_settle' "$(t3_fake_calls t3_thread_organize | while read -r c; do field "$c" action; printf ' '; done | sed 's/ $//')" \
    "publication tags the thread and protects it from automatic settling, nothing else"
  mcp review-publish --thread scout --tag 'waiting for captain'
  expect_code 0 "$RC" "a repeat is harmless: $ERR"
  assert_equals published "$(field "$OUT" outcome)" "a repeat is published again"
  assert_equals '["waiting for captain"]' "$(field "$OUT" tags)" "a repeat adds no second tag"
  pass "fm-t3-mcp review-publish: the exact tag and automatic settling off, proven by read-back, with no note, and harmless on a repeat"
}

test_review_publish_waits_yields_and_refuses() {
  fresh_case review-busy '{"reviews":true}'
  review_thread busy running
  review_thread shut completed true
  mcp review-publish --thread busy --tag 'waiting for captain'
  expect_code 0 "$RC" "a busy thread is no failure: $ERR"
  assert_equals busy "$(field "$OUT" outcome)" "a running thread waits for its turn to end"
  mcp review-publish --thread shut --tag 'waiting for captain'
  assert_equals 'closed true' "$(field "$OUT" outcome) $(field "$OUT" archived)" "an archived thread is closed"
  mcp review-publish --thread gone --tag 'waiting for captain'
  assert_equals 'closed true' "$(field "$OUT" outcome) $(field "$OUT" missing)" "a deleted thread is closed"
  assert_equals '' "$(t3_fake_mutations)" "nothing changes on a busy, archived, or deleted thread"

  fresh_case review-race '{"reviews":true,"archiveOnTag":true}'
  review_thread raced completed
  mcp review-publish --thread raced --tag 'waiting for captain'
  expect_code 0 "$RC" "a close racing publication is no failure: $ERR"
  assert_equals closed "$(field "$OUT" outcome)" "the captain's close wins over publication"

  fresh_case review-old
  review_thread old completed
  mcp review-support
  assert_equals false "$(field "$OUT" supported)" "an upstream T3 cannot keep threads"
  assert_contains "$(field "$OUT" missing)" t3_thread_note "the probe names what is missing"
  mcp review-publish --thread old --tag 'waiting for captain'
  expect_code 4 "$RC" "an upstream T3 is refused before anything is sent"
  assert_equals review_unsupported "$(field "$OUT" error.code)" "the refusal says the T3 is too old"
  assert_equals '' "$(t3_fake_mutations)" "an old T3 gets no call"

  fresh_case review-unread '{"reviews":true,"reviewsUnread":true}'
  review_thread unread completed
  mcp review-publish --thread unread --tag 'waiting for captain'
  expect_code 4 "$RC" "a read-back without the review fields is a T3 too old, not false"
  assert_equals review_unsupported "$(field "$OUT" error.code)" "missing fields read as unsupported"
  assert_equals '' "$(t3_fake_mutations)" "nothing changes when the read cannot prove it"
  pass "fm-t3-mcp review-publish: waits out a busy thread, yields to the captain's close, and refuses a T3 too old to prove it"
}

test_fence_retires_a_closed_thread() {
  local fenced_at msg="$TMP_ROOT/fence-msg"
  fresh_case fence '{"reviews":true}'
  review_thread stopped completed true
  review_thread busy running true
  review_thread elsewhere completed true "$TMP_ROOT/elsewhere"
  mcp fence --thread stopped --worktree "$WT" --label 'fm task scout'
  expect_code 0 "$RC" "a stopped thread is fenced: $ERR"
  assert_equals true "$(field "$OUT" fenced)" "the fence is proven"
  assert_equals "$WT" "$(field "$OUT" executionFence.worktreePath)" "the fence names the returned worktree"
  fenced_at=$(field "$OUT" executionFence.fencedAt)
  mcp fence --thread stopped --worktree "$WT" --label 'fm task scout'
  expect_code 0 "$RC" "a repeat is harmless: $ERR"
  assert_equals "$fenced_at" "$(field "$OUT" executionFence.fencedAt)" "a repeat keeps the original fence"
  assert_equals 1 "$(t3_fake_calls t3_thread_organize | grep -c '"fence"')" "an existing fence is not sent again"
  printf 'go\n' > "$msg"
  FM_T3_ID=stopped t3_fake_set 'w.threads[process.env.FM_T3_ID].archived = false'
  mcp send --thread stopped --message-file "$msg" --client-request-id after-fence
  [ "$RC" -ne 0 ] || fail "a fenced thread, even reopened, must not start a run"
  mcp fence --thread elsewhere --worktree "$WT" --label 'fm task scout'
  expect_code 4 "$RC" "a thread working elsewhere is not fenced on this worktree"
  assert_equals fence_mismatch "$(field "$OUT" error.code)" "the refusal names the mismatch"
  mcp fence --thread busy --worktree "$WT" --label 'fm task scout'
  expect_code 3 "$RC" "T3 refuses to fence a running thread"
  mcp fence --thread gone --worktree "$WT" --label 'fm task scout'
  expect_code 0 "$RC" "a deleted thread needs no fence: $ERR"
  assert_equals 'false true' "$(field "$OUT" fenced) $(field "$OUT" missing)" "a deleted thread reads missing"
  fresh_case fence-old
  review_thread old completed true
  mcp fence --thread old --worktree "$WT" --label 'fm task scout'
  expect_code 4 "$RC" "an upstream T3 cannot fence"
  assert_equals '' "$(t3_fake_mutations)" "an old T3 gets no fence call"
  pass "fm-t3-mcp fence: retires a stopped thread on exactly its worktree, proven, idempotent, and refused where T3 cannot"
}

iso_in() {  # <seconds from now, negative for the past> -> ISO timestamp
  FM_IN="$1" node -e 'process.stdout.write(new Date(Date.now() + Number(process.env.FM_IN) * 1000).toISOString())'
}

# t3_coordinator <turn-start-iso> [steers]: thread `coord`, whose finished
# turn run-old came from prompt msg-old and whose active turn run-c, started
# at <turn-start-iso>, came from prompt msg-c, followed by 250 activity items
# (so the prompt lies before the newest 200 positions) and <steers> more
# prompts steered into run-c.
# shellcheck disable=SC2016  # ${...} belongs to the JavaScript snippet.
t3_coordinator() {
  FM_AT="$1" FM_STEERS="${2:-0}" t3_fake_set '
const prompt = (id, run) => ({ type: "user_message", status: "completed", text: "private words", runId: run, messageId: id });
const items = [prompt("msg-old", "run-old"), { type: "assistant_message", status: "completed", text: "ok", runId: "run-old", messageId: "msg-old-reply" },
  prompt("msg-c", "run-c")];
for (let i = 0; i < 250; i++) items.push({ type: "command_execution", status: "completed", text: "ls", runId: "run-c" });
for (let i = 0; i < Number(process.env.FM_STEERS); i++) items.push(prompt(`msg-steer-${i}`, "run-c"));
const run = (runId, ordinal, status, at, done) => ({ runId, ordinal, status, requestedAt: at, startedAt: at, completedAt: done });
w.threads = { ...(w.threads || {}), coord: { threadId: "coord", projectId: "proj-c", title: "coord", status: "running", activeRunId: "run-c",
  latestRunId: "run-c", archived: false, worktreePath: null, pendingRequestCount: 0, providerInstanceId: "claudeAgent", runtimeMode: "full-access", items,
  runs: [run("run-old", 1, "completed", "2026-11-12T00:00:00.000Z", "2026-11-12T00:01:00.000Z"), run("run-c", 2, "running", process.env.FM_AT, null)] } };'
}

# in_agent <thread-id> <verb> [args...]: the helper run as a command that the
# agent of <thread-id> started: its parent bash stands for the agent, the one
# process here whose environment T3 gave T3CODE_THREAD_ID.
# shellcheck disable=SC2016  # $@ and $rc belong to the bash -c snippet.
in_agent() {
  local errf="$TMP_ROOT/stderr" thread=$1
  shift
  OUT=$(env T3CODE_THREAD_ID="$thread" bash -c 'node "$@"; rc=$?; exit "$rc"' _ "$HELPER" "$@" --token-file "$CRED" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
}

test_cause_names_the_one_prompt_of_the_callers_turn() {
  fresh_case cause '{"causedBy":true}'
  t3_coordinator "$(iso_in -60)"
  in_agent coord cause --thread coord
  expect_code 0 "$RC" "cause should answer: $ERR"
  assert_equals '{"threadId":"coord","runId":"run-c","messageId":"msg-c"}' "$(field "$OUT" causedBy)" \
    "the cause is the one prompt of the caller's active turn, found behind a turn longer than the first window"
  assert_equals "" "$(t3_fake_mutations)" "cause changes nothing"
  assert_equals "" "$(t3_fake_calls t3_thread_read | node -e '
for (const l of require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean)) {
  const a = JSON.parse(l);
  if (a.view === "messages" && a.maxCharsPerItem !== 1) console.log(l);
}')" "the message pages ask for no message text"
  fresh_case cause-upstream
  t3_coordinator "$(iso_in -60)"
  in_agent coord cause --thread coord
  assert_equals msg-c "$(field "$OUT" causedBy.messageId)" "a T3 that takes no cause still answers which prompt it was"
  pass "fm-t3-mcp cause: the caller's active turn's one prompt, read without its text"
}

# shellcheck disable=SC2016  # the stale job's positional parameters belong to its bash -c snippets.
test_cause_answers_null_rather_than_guess() {
  local bg
  fresh_case cause-null '{"causedBy":true}'
  t3_coordinator "$(iso_in -60)" 1
  in_agent coord cause --thread coord
  expect_code 0 "$RC" "an ambiguous turn is an answer, not a failure: $ERR"
  assert_equals "" "$(field "$OUT" causedBy)" "a turn that received a steer has no single cause"
  assert_contains "$(field "$OUT" reason)" "received 2 prompts" "the reason names the ambiguity"
  t3_coordinator "$(iso_in 60)"
  in_agent coord cause --thread coord
  assert_equals "" "$(field "$OUT" causedBy)" "a process older than the turn has no cause from it"
  assert_contains "$(field "$OUT" reason)" "started before the thread's current turn" "the reason says so"
  t3_coordinator "$(iso_in -60)"
  mcp cause --thread coord
  assert_equals "" "$(field "$OUT" causedBy)" "a process no agent of that thread started has no cause"
  assert_contains "$(field "$OUT" reason)" "does not run under thread coord's agent" "the reason says so"
  in_agent coord cause --thread missing
  assert_equals "" "$(field "$OUT" causedBy)" "a thread T3 lacks has no cause"
  assert_contains "$(field "$OUT" reason)" "no thread missing" "the reason names the thread"
  t3_fake_set 'w.threads.coord.activeRunId = null; w.threads.coord.status = "completed"'
  in_agent coord cause --thread coord
  assert_contains "$(field "$OUT" reason)" "no active turn" "an idle thread has no cause"
  # A job an earlier turn left running (the inner bash, started now) calls
  # later, inside a turn that began after it: that turn did not cause it.
  t3_coordinator "$(iso_in 2.5)"
  bg="$TMP_ROOT/stale-job"
  env T3CODE_THREAD_ID=coord bash -c 'bash -c "sleep 4; node \"\$0\" cause --thread coord --token-file \"\$1\"; exit \$?" "$1" "$2" > "$3"; rc=$?; exit "$rc"' \
    _ "$HELPER" "$CRED" "$bg"
  assert_equals "" "$(field "$(cat "$bg")" causedBy)" "a job older than the turn borrows nothing from it"
  assert_contains "$(field "$(cat "$bg")" reason)" "started before the thread's current turn" "the reason says so"
  pass "fm-t3-mcp cause: null with a reason for a steered turn, a stale or foreign process, an unknown thread, and an idle one"
}

test_launch_and_send_carry_the_cause() {
  local project cause thread before
  cause='{"threadId":"coord","runId":"run-c","messageId":"msg-c"}'
  printf brief > "$TMP_ROOT/brief.txt"
  printf refused > "$TMP_ROOT/refused.txt"
  fresh_case cause-carry '{"causedBy":true}'
  t3_coordinator "$(iso_in -60)"
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by "$cause"
  expect_code 0 "$RC" "a launch with a cause T3 takes succeeds: $ERR"
  thread=$(field "$OUT" threadId)
  assert_equals "$cause" "$(field "$OUT" causedBy)" "the result names the cause T3 bound"
  assert_equals "$cause" "$(field "$(t3_fake_calls t3_thread_launch | tail -1)" causedBy)" "the launch carries the cause"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/brief.txt" --client-request-id req-1 --caused-by "$cause"
  expect_code 0 "$RC" "a send with a cause succeeds: $ERR"
  assert_equals "$cause" "$(field "$(t3_fake_calls t3_thread_send | tail -1)" causedBy)" "the send carries the cause"
  before=$(node -e 'process.stdout.write(String(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).threads).length))' "$T3_FAKE_WORLD")
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by '{"threadId":"coord","messageId":"msg-old-reply"}'
  expect_code 3 "$RC" "a cause T3 refuses fails the launch"
  assert_equals cause_refused "$(field "$OUT" error.code)" "the refusal is typed as the cause's"
  assert_contains "$ERR" "is not a prompt in thread coord" "the refusal carries T3's reason"
  assert_contains "$ERR" "no thread was launched" "and says nothing was launched"
  assert_equals "$before" "$(node -e 'process.stdout.write(String(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).threads).length))' "$T3_FAKE_WORLD")" \
    "T3 created no thread"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/refused.txt" --client-request-id req-2 --caused-by '{"threadId":"coord","runId":"run-old","messageId":"msg-c"}'
  expect_code 3 "$RC" "a cause T3 refuses fails the send"
  assert_equals cause_refused "$(field "$OUT" error.code)" "the send refusal is typed as the cause's"
  assert_equals 0 "$(t3_fake_items "$thread" refused)" "the refused message was not taken"
  t3_fake_set "w.bindCause = {threadId: 'coord', messageId: 'msg-old'}"
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by "$cause"
  expect_code 4 "$RC" "a thread that reads back another cause is refused"
  assert_contains "$ERR" "causedBy differs" "the refusal names the cause"
  assert_contains "$(t3_fake_calls t3_thread_organize)" '"action":"archive"' "the mis-bound thread is archived"
  t3_fake_set "w.bindCause = {threadId: 'coord', runId: 'run-c', messageId: 'msg-c'}"
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by '{"threadId":"coord","messageId":"msg-c"}'
  expect_code 0 "$RC" "a cause sent without its run binds when T3 records the run it belongs to: $ERR"
  fresh_case cause-upstream-carry
  t3_coordinator "$(iso_in -60)"
  mcp project-ensure --root "$TMP_ROOT/proj"
  project=$(field "$OUT" projectId)
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by "$cause"
  expect_code 0 "$RC" "a T3 without causes launches without one: $ERR"
  thread=$(field "$OUT" threadId)
  assert_equals "" "$(field "$OUT" causedBy)" "and says none bound"
  assert_equals "" "$(field "$(t3_fake_calls t3_thread_launch | tail -1)" causedBy)" "an undeclared cause is never sent"
  mcp send --thread "$thread" --message-file "$TMP_ROOT/brief.txt" --client-request-id req-3 --caused-by "$cause"
  expect_code 0 "$RC" "a T3 without causes takes the send without one: $ERR"
  assert_equals "" "$(field "$(t3_fake_calls t3_thread_send | tail -1)" causedBy)" "an undeclared cause is never sent on a send"
  mcp launch --project "$project" --title crew --model-selection "$SEL" --worktree "$WT" --caused-by '{"threadId":"coord"}'
  expect_code 2 "$RC" "a cause without its message is invalid use"
  mcp cause-check --json '{"messageId":"m","runId":"r","threadId":"t"}'
  assert_equals '{"threadId":"t","runId":"r","messageId":"m"}' "$(field "$OUT" causedBy)" "cause-check puts the keys in order"
  mcp cause-check --json '{"threadId":"t","messageId":"m","device":"phone"}'
  expect_code 2 "$RC" "cause-check refuses any other key"
  pass "fm-t3-mcp launch/send: the cause rides only where declared, reads back, and a refused cause is a typed failure with nothing created"
}

t3_fake_start "$TMP_ROOT/server"
test_review_publish_keeps_the_thread_without_a_note
test_review_publish_waits_yields_and_refuses
test_fence_retires_a_closed_thread
test_cause_names_the_one_prompt_of_the_callers_turn
test_cause_answers_null_rather_than_guess
test_launch_and_send_carry_the_cause
test_login_writes_private_credential_and_never_prints_token
test_login_origin_defaults
test_login_refuses_other_ceilings
test_status_gate_and_protocol
test_gate_refuses_missing_tools
test_environment_mismatch_refused
test_expiry_and_permissions
test_revoked_credential_refused
test_projects_by_real_path
test_launch_binds_workspace
test_launch_refusals
test_send_state_capture_interrupt_archive
test_thread_for_root
test_pin_coordinator
test_crew_status
test_typed_failure_and_transport_errors
test_telemetry_reported
test_status_reports_server_started_at
test_restart_registry_verbs
test_read_limit_matches_t3_cap
test_interrupt_confirms_only_the_interrupted_run
test_send_lost_reply_is_unconfirmed_and_retry_is_one_delivery
test_thread_for_root_pages_and_forks
test_resolve_selection_uses_t3_catalog
test_resolve_selection_accepts_current_catalog_values
test_launch_reads_back_full_configuration
test_resolve_selection_adapter_rows
test_resolve_selection_searches_omitted_models
test_resolve_selection_by_root_is_read_only
test_launch_binds_thread_environment_and_instructions
test_launch_names_its_crew_parent
test_close_stops_delegated_threads
test_requests_and_respond
test_gate_refuses_pre_0_1_3_tool_names
test_launch_reads_binding_through_configure
test_watch_is_event_driven_and_bounded
test_watch_reports_failed_waits_not_timeout
test_helper_runs_through_symlinked_path
test_empty_reply_is_never_success
test_watch_escalates_a_replaced_approval
test_approvals_with_approval_responses
test_jsonrpc_server_error_is_not_proven_refusal
test_orchestration_error_is_not_proven_refusal
test_long_wait_rearms_in_slices
test_capture_clamps_lines_and_closes_session
test_watch_zero_budget_reads_pending_requests_only
test_watch_pending_push_ends_the_wait
test_watch_without_pending_push_reads_at_the_next_call
