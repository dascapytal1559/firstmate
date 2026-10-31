# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server only through its Orchestrator V2 `/mcp` endpoint, signed in as an OAuth `mcp-client`, and nothing is typed into a terminal.
[`bin/fm-t3-mcp.mjs`](../bin/fm-t3-mcp.mjs) owns that transport, the credential, and the capability gate; [`bin/backends/t3code.sh`](../bin/backends/t3code.sh) owns the backend primitives built on it.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree, and each secondmate a visible T3 thread working in its own home.
T3 Code runs the harnesses that have a T3 driver: `claude`, `codex`, `grok`, `pi`, `muse`, `opencode`, `agy`, and the ACP-registry `cursor`, `gemini`, `kimi`, and `devin`; every other harness, and a raw launch command, is refused at spawn.
Every harness needs a T3 server whose provider instance advertises per-thread environment and instructions ([thread channels required](#thread-channels-required)).

Prerequisites:

- A running T3 Code server that passes the [capability gate](#capability-gate).
  T3 stable 0.0.45 lacks the Orchestrator V2 thread tools, so it is refused; the verified version is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code).
- `node`, which the adapter uses to speak MCP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Run the server that hosts Firstmate workers with T3's product telemetry off, so worker turns are not counted:

```sh
T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port <port> --no-browser
```

Every spawn and control action checks the server's telemetry state and warns unless the listening loopback server's own process proves it off.

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
T3 Code is explicit-only for task dispatch; a configured server does not select this backend automatically.
An explicitly configured T3 home can identify its active supervisor by its home thread.
The shared selection rules and precedence are in [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).
The [capability gate](#capability-gate) applies before spawn, control, or teardown mutations.

### Sign-in

Issuing a full-access agent credential is the captain's decision, so the captain runs the sign-in and Firstmate never does:

```sh
bin/fm-t3-mcp.mjs login --access full-access
```

The server origin defaults to `FM_T3CODE_ORIGIN`, else the `origin` in `~/.t3/userdata/server-runtime.json`; `--url <origin>` names it explicitly.
Add `--t3 <path>` when `t3` is not on `PATH`, and `--base-dir <dir>` when the server runs with a non-default T3 base directory.
The sign-in mints a two-minute one-time pairing code with the operator's own `t3 auth pairing create`, scoped to `orchestration:read`, `orchestration:operate`, `settings:write`, and `source-control:write`, and spends it to approve Firstmate as an OAuth `mcp-client` at the full-access ceiling.
T3 0.1.0 grants a full-access `mcp-client` all four scopes and refuses a pairing code that lacks one.
No browser is involved, and the token and pairing code are never printed.

Full access is required because a worker writes its status lines outside its worktree.
Under T3's narrower modes Codex's sandbox blocks that write and Claude parks on an approval for every guarded action.
The credential is much narrower than T3's administrative bearer from `t3 auth session issue`, which this backend no longer uses; T3 accepts an `mcp-client` session only on `/mcp`.

The credential, the server's origin, its environment id, and its version are written to the local, gitignored `config/t3code-token`, mode 0600.
A missing credential refuses with an error that names the sign-in command; an expired, revoked, or incomplete one asks the captain to sign in again, an over-readable one asks for `chmod 600` or a fresh sign-in, and one that is not valid JSON names the parse error.
A secondmate spawned on this backend gets `config/t3code-token` as a symlink to the primary's credential file, so its own daemon and crew use the same credential without a copy of the secret, and a fresh sign-in reaches them.
Teardown removes that link, with the rest of the T3 environment the spawn wrote into the home, before a pooled home returns to the pool.

### Expiry and revocation

T3 issues the credential for 30 days with no refresh token.
Every call warns within five days of expiry and refuses once it has expired; the captain then signs in again.
The credential appears in `t3 auth session list` as subject `mcp-client` with label `firstmate`.
Revoke it with `t3 auth session revoke <id>` and delete `config/t3code-token` when retiring the backend.

### Provider instances and models

The `HARNESSES` table in `bin/fm-t3-mcp.mjs` is the one harness adapter table: for each harness it names the T3 driver, the model option that carries effort, and either the default provider instance or, for the ACP registry driver, the registry agent.

| Harness | T3 driver | Instance | Effort option |
|---|---|---|---|
| `claude` | `claudeAgent` | `claudeAgent` | `effort` |
| `codex` | `codex` | `codex` | `reasoningEffort` |
| `grok` | `grok` | `grok` | `reasoningEffort` |
| `pi` | `pi` | `pi` | `thinking` |
| `muse` | `muse` | `muse` | `reasoningEffort` |
| `opencode` | `opencode` | `opencode` | `variant` |
| `agy` | `antigravity` | `antigravity` | the model's one effort option in the catalog |
| `cursor`, `gemini`, `kimi`, `devin` | `acpRegistry` | the one instance whose `agentId` is the harness name | the model's one effort option in the catalog |

An ACP registry harness runs on whichever instance reports its registry agent, whatever T3 named it (T3 names a new one after the agent's label, such as `acpRegistry_gemini_cli`); spawn refuses when no instance runs that agent, and when several do.
`cursor` runs as the registry's `cursor` agent (`cursor-agent acp`), one process per thread, because T3's own `cursor` driver hosts Cursor's SDK inside the T3 server, which gives a thread no environment of its own.
A `gemini` thread's environment also carries `GEMINI_CLI_TRUST_WORKSPACE=true`, as the pane launch does.
`config/t3code-instances` names the instance a harness runs on instead, one `harness=instanceId` line each, which also settles a registry agent with several instances.
Spawn resolves the selection against T3's own catalog (`orchestrator_capabilities`) before anything is leased: the instance must exist, be usable, run the harness's driver, report the expected registry `agentId` for an ACP registry harness, and list `full-access` among its `runtimeModes` when it lists any, so a mapping onto another driver's or agent's instance, or onto an instance T3 would silently run below full access, is refused.
The file is part of the primary's inherited local material, so every secondmate home receives the primary's mapping and its own T3 workers launch on the same provider instances; a home without the file falls back to the table, which need not name a configured account.
A task's `--model` must be a model that instance has in T3's catalog.
T3 lists a short set of models per instance and counts the rest as omitted, so a slug outside that set is looked up with the catalog's search and must match a model id exactly.
`--model default` uses the default model of the T3 project already rooted at the task's project, read without creating it, only when its instance matches the selected one; otherwise it refuses and asks for an explicit `--model`.
`--effort` rides as the row's effort option, and its word (`low`, `medium`, `high`, `xhigh`, `max`, or `ultra`) must be a value the catalog lists for that model under the same name: Firstmate never maps it onto a neighbouring level, so for example Grok refuses `max`.
A model that offers several candidate effort options is refused rather than guessed.
An effort replaces only that option: `--model default` keeps every other project default option, such as Codex's service tier or Claude's fast mode, while an explicit model sends only the effort.
Every selected option is checked against the model's catalog descriptors.

### Capability gate

Every call first runs `tools/list` and refuses unless T3 offers every tool in `REQUIRED_TOOLS` in `bin/fm-t3-mcp.mjs` (the thread, project, and catalog tools), `t3_environment_read`, and one complete family for each `TOOL_FAMILIES` capability.
T3 stable 0.1.3 merged two tool families, and the gate accepts either generation based on the listed tools, without comparing server versions.
When T3 lists both, pending questions use the merged `t3_pending_request`, but the binding read keeps `t3_thread_configuration`, because earlier T3 also lists `t3_thread_configure` as a write that requires `modelSelection`:

| Capability | Current tool family | Earlier tool family |
|---|---|---|
| Read a thread's binding | `t3_thread_configure` with only `threadId` (a read; the helper never sends `modelSelection`) | `t3_thread_configuration` |
| Pending questions (and approvals where `approvalResponses` is advertised) | `t3_pending_request` with `action` `list`, `read`, or `respond` | `t3_pending_request_list`, `t3_pending_request_read`, `t3_pending_request_respond` |

It then refuses unless `t3_environment_read` reports the environment id recorded at sign-in, so a different T3 server behind the same address is never driven with this credential.
A refusal names the missing tool or both environment ids, and spawn, control, and teardown stop before their first mutation.
This gate replaces the HTTP dispatch probe and version floor of the pre-V2 transport, which T3 0.0.46 removed.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread launched with the `existing_worktree` workspace strategy on that worktree.
A secondmate's T3 project is its home and its thread is launched with the `root` workspace strategy, so the agent runs in the home on whatever branch the home is on.
T3 assigns the thread id at launch (`mcp:<uuid>`), and the task records it as `t3_thread_id`.
The normal isolation and unlanded-work refusal rules still apply.

Each launched thread also names the T3 thread running the firstmate that spawned it as its parent, so T3 lists it as that thread's crew: a worker under the main or under the secondmate that spawned it, and a secondmate under the main.
The parent is an explicit `FM_SUPERVISOR_TARGET` that pairs with t3code, else the one live worktree-less thread in the spawning home, the same cwd match away mode uses.
It is sent as `parentThreadId` only where the `t3_thread_launch` schema declares it, and the launch read-back must then show `relationshipToParent` `crew` under exactly that parent, or the thread is archived and refused like any other mis-binding.
A T3 without crew lineage, a firstmate not running in T3, or a home with several live threads launches the thread with no parent, which changes only how T3 groups it; lineage grants nothing on the parent, and stopping or archiving either thread stays independent of the other.

[`configuration.md`](configuration.md#task-metadata) owns the task metadata fields, and its [task-selector contract](configuration.md#task-selectors) owns routing to the recorded thread.

## Worker environment and channel statement

T3 starts the agent itself, so nothing can be typed into a pane before launch.
Every kind receives `GOTMPDIR`, `COMPACT_ADVISER_DISABLE=1`, and `FM_TASK_INBOX`, plus `LAVISH_AXI_HOST` when `config/lavish-axi-host` is set, and Firstmate's `core.hooksPath` Git hook entry when one is installed; ship and scout workers also receive `FM_TASK_ID`; `TRACEPARENT` rides only when trace context is on, and is recorded as `traceparent=` in the task record before the thread runs.
A secondmate additionally receives the launch prefix every other backend types (`FM_ROOT_OVERRIDE`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` empty, `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME`, `FM_HOME`, `FM_TRACE_CONTEXT`, `FM_SUPERVISION_MODEL`) plus `FM_SUPERVISOR_BACKEND=t3code`.
A ship or scout worker also receives the task-worker channel statement that a Claude pane launch appends to the system prompt, saying the launch brief and steering inbox are first-party; a secondmate does not, as on every backend.
Without it a Claude worker can refuse the launch brief as prompt injection, which happened live.

The environment rides `t3_thread_launch`'s `environment` and the channel statement its `instructions`, for every harness.
The launch reads both back through the configuration read and archives and refuses a thread that did not bind them exactly.
A secondmate carries no `FM_SUPERVISOR_TARGET`, because its own thread id is not known before launch; its away daemon finds its thread by home, which `FM_SUPERVISOR_BACKEND=t3code` enables.

The statement's pull-request-tool workaround for Claude follows the [verified version boundary](verification/runtime-backends.md#claude-pull-request-tools); an older or unreadable server keeps the clause, while a server at or past the verified build gets none.
Firstmate records the PR from the worker's `done: PR <url>` status line either way.
The thread's `GIT_CONFIG_*` entries are Firstmate's own `core.hooksPath` hook entry only: inherited `GIT_CONFIG_*` values, or any other inherited environment value, are never forwarded, because they can carry credentials.
That entry sets `GIT_CONFIG_COUNT=1` and index 0, so numbered `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` entries in the T3 server's environment do not apply in the thread; with `config/keep-ai-trailers` no hook entry is written and they apply unchanged, except on a `forge=external` ship, whose push guard always installs the hook entry.
A T3 server whose agents need extra Git config, such as a `credential.helper`, supplies it through Git config files, which the hook entry leaves alone: for example the service user's global config, or `GIT_CONFIG_GLOBAL` in its service environment.
T3 sets only the environment a launch names; it never unsets what the T3 server itself inherited, so keep harness markers such as `CLAUDECODE` out of the server's own environment.

### Thread channels required

Spawn refuses, before anything is leased and for every harness, a T3 provider instance that does not advertise both `threadEnvironment` and `threadInstructions`, so this Firstmate runs only on the [T3 Code fork](https://github.com/dascapytal1559/t3code), which has them.

## Current lifecycle and safety

Spawn resolves the selection and channels against T3's catalog, matches the project (the home, for a secondmate) by real path against T3's live projects, creating one with `t3_project_create`, titled with the directory name, when absent (an existing project keeps its own title), and leases the worktree for a worker.
It installs the Claude busy hooks and the Git hook entry, then launches an idle thread with `t3_thread_launch` (the title, the workspace strategy and branch, `full-access` runtime mode, the model selection, and the thread channels) and reads the thread and its configuration back through the [capability gate](#capability-gate)'s configuration tool; a thread T3 bound to another workspace, runtime mode, effective runtime mode, instance, model, option value, environment, or instructions is archived and the spawn refuses.
It records metadata and sends the encoded brief (the charter, for a secondmate) as the thread's first message with `t3_thread_send`.
A worker's thread title, its crew card label in T3, is its backlog item's title cut to 96 characters, so keep item titles short; it falls back to `fm-<id>`, which a secondmate always uses, and nothing keys on it.
Exact call payloads are owned by `bin/fm-t3-mcp.mjs` and `bin/backends/t3code.sh`.

`fm-peek.sh` renders the newest items of the thread's activity view as `[type/status] text` lines followed by a `t3code: status=<status> run=<active run>` line.
T3 pages that view oldest first, so the helper starts from the thread's visible item count to read the tail.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `t3_thread_send` in `auto` mode, which starts an idle thread's next turn or steers the running one.
T3 derives the message id from the client request id within the auth session that sent it and commits a send before it replies, so retries must reuse that id, under the same sign-in, to reach the message T3 already committed.
For ordinary sends and doorbells, the adapter reuses the id stored in a record keyed by thread and text for up to 60 minutes from creation, ending that delivery earlier on confirmation or a typed send refusal.
After that window, identical text starts a new delivery, so verify an older unconfirmed send in T3 Code before resending it.
An accepted delivery's outcome (its request id, `messageId`, `runId`, and `delivery`) is kept for a day as `state/t3code-sends/<request-id>.accepted`, so it can be reconciled against T3's own message and run.
The submit primitive reports `empty` when T3 accepts the message, `unconfirmed` when its reply was lost or T3 answered with a JSON-RPC server error, its catch-all `orchestration_error`, or a tool error without a code, none of which proves the message was not taken, and `send-failed` only for proven non-delivery.
The direct-submit plane of `fm-send.sh` reports `unconfirmed` as exit 3 with any reply expectation kept armed; an inbox steer's exit status still follows the [durable-record contract](../bin/fm-send.sh).
After `unconfirmed`, an unmarked send can reuse its request id by resending identical text within that window; a marked secondmate request is not resent, because a rerun mints a new reply correlation and so a new message.
While the logical delivery still holds its id, a retry that fails for any reason other than T3 refusing the send, including an unreachable server, stays `unconfirmed` and keeps that id.
The away daemon mints a request id for each T3 digest.
It freezes an unconfirmed digest and retries its exact text under that id, with no expiry, until T3 accepts or refuses it, while events that arrive meanwhile wait for the next digest.
Task completion remains a separate worker status event.
Escape and Ctrl-C are both a `t3_thread_interrupt`; Enter is a no-op and Ctrl-U is unsupported.

The control plane ([`agent-control.md`](agent-control.md)) reads the same status table.
`interrupt` is a `t3_thread_interrupt` proven by the thread still reading alive afterwards.
T3 stops its latest active run asynchronously and names it, so the `cancel=` verdict waits on exactly that run: `confirmed` when it reached a terminal status, `not-running` when there was no active run, else `unconfirmed`, even when a later queued run is already terminal or has started meanwhile.
`exit` is refused before anything is sent: the V2 `/mcp` tools have no session stop, and an interrupt leaves the thread idle and alive, so no stop could be proven.
`relaunch` is refused before anything is stopped: a T3 thread keeps its conversation, so a new turn continues the same agent, and a provider or model change through `t3_thread_configure` is a context handoff on that same thread rather than the fresh agent a relaunch promises.

The watcher and `fm-crew-state.sh` use the adapter's [thread status table](#restart-and-liveness-behavior) ahead of harness gates and hook records (source `t3code-native`), so every T3 worker settles from T3's status whatever hooks its harness has.
Spawn therefore arms no pane-shaped busy or turn-end wiring on this backend, and installs no per-user hook file such as Grok's or Kimi's global hooks; only `claude`'s worktree hooks stay, because T3 launches Claude with the `user,project,local` setting sources and they fire as on every other backend.
Native uncertainty stays unknown instead of falling through to a hook record or rendered fallback.
Watcher re-rings for ordinary records treat that uncertainty like busy, so a due doorbell waits and spends the same busy-deferral budget [`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh) owns before a stuck-busy escalation.
The initial `fm-send.sh` doorbell follows that library's best-effort ring contract instead.
A thread's capture stays byte-identical through a long tool call, so before reporting a possible wedge the watcher rechecks the [thread status table](#restart-and-liveness-behavior) and resets its stale timer only for the `running` word.
That deferral is itself bounded by `FM_BUSY_TURN_MAX_SECS`, measured from the latest run boundary T3 records (completion, or start while the run is still active), so a hung run still reaches the possible-wedge alert, and a missing run timestamp never defers.
`wedge_defer_t3code_running` in `bin/fm-watch.sh` owns that consult; all other classified words keep the ordinary escalation ladder, including its declared-wait, worktree-write, and dead-record checks.
T3 starts every agent with the T3 server's own environment, not a login shell's.
Codex runs each command through `/bin/zsh -lc` in that environment, so the Firstmate toolchain must survive the login shell's startup files, and a startup file that rebuilds `PATH` when a marker variable is missing hides it from every Codex worker; Claude's shell tool restores its own login-shell snapshot and is unaffected.
A remote secondmate is unaffected by this backend: it always runs on the remote host's Herdr, and `--backend t3code` on one is refused.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, or before a secondmate home is removed, teardown stops any active run, archives the thread with `t3_thread_organize`, and requires T3 to read back `archived:true` with no active run and no active delegated thread below it, so no live thread can act in a slot another task may lease.
A worker can start delegated T3 tasks of its own, which neither a plain interrupt nor an archive stops, so teardown sends `t3_thread_interrupt` with `stop: true` (T3's Stop: the running turn, the queued messages, and every delegated task) whenever the server's tool schema declares `stop`; on an older server it interrupts the thread's own run, and a delegated thread that still runs leaves the close unproven, naming it, until it is stopped in T3 Code.
Because the watcher surfaces a worker's `done` while the turn that wrote it may still be running, a ship or scout teardown first waits up to `FM_TEARDOWN_TURN_WAIT_SECS` (default 30) for an active run to end on its own and refuses, before any record changes, when it has not; `--force` keeps the interrupt, since it already authorizes discarding what the turn holds.
T3 detaches the provider session as a separate effect after that read-back, so its agent process can briefly outlive it: a worker's slot is cleared by teardown's worktree-process reaper, and a secondmate home, pooled or standalone, goes through the same reaper before it is returned or removed, keeping the home and its records when the process scan cannot complete.
Secondmate retirement requires `lsof` to prove the home is quiet; without it, teardown refuses before it archives anything, preserving the thread, home, and records for retry.
If spawn aborts after launching the thread and before T3 accepts its launch brief, including when T3 refuses the brief or a thread binding is refused, cleanup uses the same proven close and keeps the lease when it fails, then prints the manual archive, environment-removal, and `treehouse return --force` steps.
After a proven close it removes the environment files the spawn wrote into the slot or secondmate home, as teardown does, and keeps a worker's lease when that fails.
Spawn freshens a leased slot before launching its thread, so a slot it cannot bring current never gets a thread: a slot that is not clean (uncommitted work or a stale submodule checkout) keeps its lease, and spawn prints the manual `treehouse return --force` step; after any other refresh failure, including an uninspectable worktree or an unreachable origin, the slot is returned.
`t3_thread_launch` has no idempotency key, so a lost launch reply, T3's catch-all `orchestration_error` or a tool error without a code, or a failed binding read-back leaves ownership uncertain: spawn keeps the lease and never retries.
A gate failure before `t3_thread_launch` is requested launched nothing, so spawn returns the lease.
A leased path that fails the worktree isolation check may be the spawning checkout itself, so spawn neither cleans nor returns it and prints the manual `treehouse return --force` step to run once it is inspected.
When the thread id is known, the helper archives it and reports its id and whether it then read back archived with no active run, but the lease stays held either way until it is released by hand.
An unproven launch-brief outcome (a lost reply or a T3 error that can follow a commit) means the brief may already be running, so spawn keeps the task record, lease, and thread, never resends the brief itself, and exits nonzero with the thread to inspect.
An identical brief resend follows the [ordinary-send retention window above](#current-lifecycle-and-safety); verify delivery in T3 Code before resending after that window.
Before returning a retained slot by hand, prove both the archive with no active run and the end of its provider and worktree-owned processes, as teardown does above.
The kill is idempotent, so an already archived thread, or one the verified server no longer has, is the end state, and an unreachable or gate-refused server refuses the teardown rather than returning a slot a live thread still points at.
Archiving keeps the transcript visible in T3 Code; this backend never deletes a thread.
The T3 project of a torn-down secondmate home stays in T3 Code pointing at the removed directory until the operator deletes it there, because deleting a nonempty project takes the archived thread's transcript with it.

## Restart and liveness behavior

The T3 thread id, transcript, provider binding, and Treehouse worktree outlive a server connection.
A server restart cancels in-flight runs even though the thread still exists, so a worker whose turn ended without a terminal status line needs a steer, which the [server restart](#server-restart) recovery sends.
Thread persistence alone does not prove a live agent.

`bin/backends/t3code.sh` owns one status table over the thread's V2 status, read with `t3_thread_read`:

- A thread with a pending runtime request (`pendingRequestCount`, a question or a permission approval) reads `blocked`, idle/alive, so a wait on a human is never taken for progress.
- `preparing`, `queued`, `starting`, `running`, and `waiting` (the run's post-turn drain) read busy/alive.
- `idle`, `completed`, `interrupted`, `cancelled`, and `rolled_back` read idle/alive.
- `failed` reads unknown/dead.
- An archived thread with no active run, or one the verified server does not have, reads missing.
- An archived thread whose run is still draining is not proven closed, so it reads `unknown unreadable` until the run ends.
- An unreachable server, a refused gate, or a failed read reads `unknown unreadable`, which is never treated as proof that a replacement agent is safe.

<a id="server-restart"></a>

### Server restart

A T3 server restart ends every provider session it hosts at once, a Firstmate main's running as a T3 thread and every worker's.
T3's restart continuation, on by default (`continueThreadsAfterServerUpdate`), may resume a run the restart cut mid-turn with "Continue where you left off." when its provider session, native thread, and turn still match, at most three times in five minutes; every other thread reads idle.
Either way its background commands and waits are gone, and its last `working:` or `paused:` line still looks current; a send to an idle thread reopens its session with the same conversation.
Claude's `SessionStart` hook does not reliably fire on such a reopen, so nothing below depends on it.

- **Detection.** `bin/fm-t3-mcp.mjs status` reports the loopback server's own process identity as `serverStart` (its pid and kernel start time), which changes on every restart; a remote origin has none, so a restart there is not detected.
- **Recovery.** In a home with `config/t3code-token`, the locked session start runs [`bin/fm-t3-restart.sh`](../bin/fm-t3-restart.sh) `recover`: when `serverStart` differs from the one the home last recorded, every ship or scout whose current claim is `working:`, `paused:`, or nothing yet gets one recovery steer through `fm-send.sh`, whose doorbell reopens its session, and the digest lists them under `T3 RESTART`.
  Firstmate does not detect T3's own continuation: on a resumed run the doorbell steers that run instead, which is harmless, because the steer only asks the worker to re-check what is still running and append a fresh status line, which a resumed worker still owes.
  Workers with an open decision, a captain-held wait, or a terminal line are left alone, and an archived thread is reported rather than rung.
- **Untrusted claims.** Until such a worker appends a new status line, its earlier pause is no longer a declared wait for the watcher or the away daemon, and `fm-crew-state.sh` reports its earlier `working:` or `paused:` claim as unknown, so the ordinary stale handling applies instead of the four-hour pause cadence.
- **The main's first tool call.** When `state/.lock` names a process that is no longer running, the main's first tool call is denied once with an instruction to run `bin/fm-session-start.sh` ([`bin/fm-t3-main-pretool-check.sh`](../bin/fm-t3-main-pretool-check.sh), registered for Claude only).
- **Waking the main.** Nothing inside a dead session can reopen the main, so the [T3 Code fork](../FORK.md) does it: on each server start it sends every idle, unarchived, unsnoozed thread that has unarchived crew threads one note attributed to T3 Code, saying when the server restarted, which crew threads had a run cut, and to run `bin/fm-session-start.sh`.
  Where the server advertises `coordinatorRestartNote`, every `recover` also pins the home's own thread (the one the away daemon would find) as its project's coordinator, so the note reaches it after every server start, even one that cut no crew run.
  The note is an ordinary user turn, not Firstmate operational input, and the main follows it like any other instruction: it runs session start once, which retakes the lock and runs `recover` above.
  The project's `continueThreadsAfterServerUpdate` setting switches the note off, and upstream T3 Code sends none.
  A main whose own run the restart cut gets T3's restart continuation instead of the note, and that continuation does not mention session start, so the first-tool-call reminder above is what brings it back.

The main's credential guard in the same PreToolUse hook denies a Read or Grep of `config/t3code-token`, a Grep over `config/`, and a shell command that would print the file or a glob over `config/`, so the full-access credential stays out of the main thread's transcript; it guards against a mistake, not a determined reader.

Inspect a failed worker's thread error before sending a new turn through its normal steer path.
A new turn continues the same driver and transcript; `fm-control.sh relaunch` remains refused.
Automatic secondmate recovery treats a failed run the same way: the thread is still readable, so recovery resumes it in place with one recovery turn instead of archiving it and launching a second thread, and the relaunch ledger bounds repeats.
That turn tells the secondmate to re-read its `AGENTS.md` and config first, and startup still delivers its queued config re-read retries, because a resumed conversation does not re-read on its own the way a fresh launch does.
A secondmate thread that reads missing is closed again through the idempotent archive before a replacement thread is launched, and when that close cannot be proven the thread and its record stay as recorded and nothing is spawned; other backends keep their existing best-effort close ([`bin/fm-secondmate-liveness-lib.sh`](../bin/fm-secondmate-liveness-lib.sh)).
Teardown still requires a proven archive before returning the worktree.

## Push events and polling fallback

T3 accepts an `mcp-client` session only on `/mcp`, so its WebSocket event stream is not available to this credential.
`t3_thread_wait` is itself event-driven on T3's stored run updates, so the watcher's push splice uses it instead: each cycle makes one bounded `fm-t3-mcp.mjs watch` call across the recorded T3 workers.
A new or changed set of pending requests is escalated at once, once per set, as a `blocked` wake that names the question ids and any permission approvals.
On a T3 whose `orchestrator_capabilities` advertises the `approvalResponses` feature, the pending-request list names each approval by request id, and the wake carries its kind, command or file, the provider's reason, and its `override` (`provider_check` or `ask_rule`).
On an earlier T3 each approval is identified by its `approval_request` activity item, which T3 holds at status `waiting` until it is answered, among the thread's last 100 items, so an approval answered and replaced by another before the next cycle is a new set ([source evidence](verification/runtime-backends.md#permission-approvals-in-the-activity-view)).
Otherwise the call waits on each thread's exact active run and returns as soon as one turns terminal, so the poll loop reconciles that turn without waiting out its interval.
The same call races a change to a status or turn-end file in the home's state directory (`watch --state-dir`, filter and debounce owned by `bin/fm-state-watch.mjs`), so a worker's own append ends the wait within milliseconds, before T3 records the run's end; with no active run the call holds on that directory for the interval instead of re-arming.
A run's terminal status is kept in the thread's run-ended record rather than discarded, and the watcher uses it, or one `state` read, to report a run that ends `failed`, `interrupted`, `cancelled`, or `rolled_back` after the worker's surfaced `done`, `failed`, or decision, carrying the error message T3 exposes on this credential ([`watcher-continuity.md`](watcher-continuity.md#signal-coalescing-and-the-terminal-fast-path) owns the rule).
The poll loop, its wedge timer, and the `FM_BUSY_TURN_MAX_SECS` bound on a running thread remain the backstop, and a server the call cannot read drops the cycle to plain polling.
Secondmate threads stay off the splice, as on Herdr.
In a home that also records Herdr or Rex workers, that backend keeps the push wait, so adding a T3 task never slows Herdr or Rex escalation.
Each such cycle first reads the T3 workers' pending requests once without waiting (`watch --timeout-ms 0`), so a T3 question or approval still wakes firstmate within the poll interval with the same detail, escalated once per set; only a T3 run's end then waits for the poll loop.

Read and answer a worker's pending questions with [`bin/fm-t3-answer.sh`](../bin/fm-t3-answer.sh), which uses T3's pending-request tools (see the [capability gate](#capability-gate) for the two generations).
Its listing also shows each answerable approval, and [`bin/fm-t3-approve.sh`](../bin/fm-t3-approve.sh) allows or denies one through the same tool, as T3 Code's own buttons do, recording the decision in the task's durable record.
Firstmate decides every approval itself under the `stuck-crewmate-recovery` skill's T3 permission approvals policy, so the captain never answers one in a worker's thread.
A T3 without `approvalResponses` lists and answers questions only: the approval is surfaced as a count, the helper refuses, and firstmate interrupts and steers the worker instead.

<a id="away-mode"></a>

## Away-mode supervisor support

The away daemon can supervise a captain that runs inside a T3 thread.
[`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns discovery precedence and the explicit-selection and credential prerequisites.
T3 puts nothing about the thread into the agent's environment, so eligible discovery matches this home's real path to a live project's `workspaceRoot`, lists its threads with an active run through every `t3_thread_list` page, and selects the one unarchived thread with no worktree of its own.
A forked conversation counts; a delegated subagent does not.
Multiple matching threads print an ambiguity diagnostic naming their ids and fall through to the legacy tmux fallback, as do no matches or an unreachable server.
Resolve ambiguity by explicitly setting both `FM_SUPERVISOR_BACKEND=t3code` and `FM_SUPERVISOR_TARGET` to the intended thread id.
Injection is a `t3_thread_send` only into a settled supervisor thread, one the [thread status table](#restart-and-liveness-behavior) reads idle/alive with no pending request; any other row, including `blocked` and an unreadable thread, defers the digest exactly as a busy pane does on every other backend.
An unknown native busy verdict defers new-turn delivery but does not prove that work resumed.
Away housekeeping keeps an overdue stale alert pending and buffers one possible-wedge report while the verdict remains unknown, including a failed run or a transient thread-read failure.
Delivered warnings stay suppressed while the same unknown condition persists.
If a fresh daemon entry discards a queued, undelivered warning, it clears that warning's reported marker and preserves its stale timer, so the next housekeeping pass queues exactly one replacement.
Refreshing a live daemon preserves the queue; a failed start restores the previous queue and reported markers.
Confirmed busy activity, a missing thread, or an idle verdict after the unknown condition was reported clears the stale and reported markers without another report, so a later unknown condition can report again.
Declared external-wait rechecks also survive native uncertainty; the worker's declaration still controls their cadence.
`stale_window_is_busy` and `housekeeping` in `bin/fm-supervise-daemon.sh` own stale tracking; `fm_afk_clear_stale_artifacts` in `bin/fm-afk-start.sh` and the launcher in `bin/fm-afk-launch.sh` own queue discard and startup rollback.
`tests/fm-backend-t3code.test.sh` covers retention, deduplication, and re-arming across native restart.
Only `bin/fm-afk-launch.sh start-native` launches the daemon here, as the captain's own tracked background job; `start` refuses because T3 hosts no terminal to create.
A secondmate spawned on this backend carries its supervisor backend in its environment, and its own daemon finds its thread by home.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.

## Moving a task from the pre-V2 transport

A home that used the earlier HTTP dispatch transport needs the `/mcp` credential first: run the [sign-in](#sign-in), which replaces the old bearer in `config/t3code-token`.
Keep each task's recorded thread id and use normal steering and teardown after sign-in; [`verification/runtime-backends.md`](verification/runtime-backends.md#adapter-wiring-on-linux) records the pre-V2 thread-read evidence.
If a task's thread no longer reads back, release the task by hand:

1. Archive the task's thread in T3 Code and satisfy the [cleanup proof above](#current-lifecycle-and-safety) before releasing its worktree or home.
2. For a worker, remove `.claude/settings.local.json` from the worktree.
   For a secondmate, release its own tasks in this same order, then remove the `config/t3code-token` symlink before releasing the home.
3. For a worker, return its slot with `treehouse return --force <worktree>` from its project.
   A secondmate has no separate task worktree, but its home may itself be leased: preserve its durable records and unlanded work, then return a pooled home with `treehouse return --force <home>` from the Firstmate code root, or remove a standalone home by hand.
   Remove its line from the parent's `data/secondmates.md`.
4. Remove the task record, `state/<id>.meta`, and its other `state/<id>.*` files.

## Active limits

- T3 Code remains experimental; its harnesses are the [adapter table](#provider-instances-and-models), and every harness but `claude` and `codex` needs a T3 with per-thread environment and instructions.
  `claude`, `codex`, `grok`, and `pi` have dated live evidence on this backend ([`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code)); the other rows are covered by the portable suites only.
- T3 starts every agent at `full-access` with its provider instance's account and environment, so a spawn refuses any posture setting that asks for less (`config/claude-permission-mode` other than `bypass`, `config/codex-approval-mode=approve-for-me`, or `config/codex-permission-mode=restricted`), `config/launch-env-allowlist`, `config/crew-exclude-tools`, a worker account pin, and a raw launch command; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
  Unless `config/keep-ai-trailers` is present, the per-worktree environment selects Firstmate's Git commit hook to strip known AI trailers, including on T3 workers.
- T3 also owns the Codex provider command, so Firstmate cannot apply the pane-backed worker's hook-disable or turn-end notify options.
  Firstmate's pane-backed hook-trust workaround therefore does not apply; supervision uses T3's [thread status table](#restart-and-liveness-behavior).
- `fm-control.sh exit` is refused because the V2 `/mcp` tools have no session stop, and `relaunch` is refused because a thread keeps its conversation, so no fresh agent can replace it.
- The WebSocket event stream is not available to an `mcp-client` credential; the [run wait](#push-events-and-polling-fallback) stands in for it.
- A permission approval can be answered through `/mcp` only on a T3 that advertises `approvalResponses`; elsewhere firstmate interrupts and steers the worker instead.
- Request-id deduplication holds within one T3 auth session only: every sign-in starts a new session, so resending an unconfirmed send, or retrying a frozen away-mode digest, after the captain signs in again can deliver it twice; verify such a message in T3 Code first.
- A tracked `.codex/config.toml` that already defines `[shell_environment_policy]` is refused by file and table name before a slot is leased.
- While a tracked Codex overlay is installed, do not edit that file or clear its `skip-worktree` flag; configuration changes require cleanup first.
- Shell typing and Ctrl-U are unsupported; runtime Escape and Ctrl-C still interrupt the turn.
- A Firstmate main session in a T3 thread is verified only for Claude; a Codex supervisor has no away mode on this backend because it has no tracked background tool for `start-native`, and T3 has no terminal for `start` to create.
- T3 checkpoints each turn as hidden refs under `refs/t3/orchestration-v2/checkpoints/` in the project clone; they are never pushed and do not affect the landed-work test.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-t3-mcp.test.sh tests/fm-backend-t3code.test.sh
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-daemon.test.sh tests/fm-control.test.sh
FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
FM_T3CODE_PR_TOOLS_LIVE=1 FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-pr-tools-live-e2e.test.sh
```

The portable entry points cover the T3 adapter against a [fake `/mcp` server](../tests/t3-fake-server.mjs) and fake Treehouse, plus the shared backend, daemon, and control behavior.
The live guard spends no model tokens and changes nothing on the server: it checks the gate, the project catalog, and a typed missing-thread read against the server the configured credential names, and skips cleanly without one.
Set `FM_T3CODE_LIVE_E2E=0` to disable it or `FM_T3CODE_LIVE_E2E=1` to require it; the shared `FM_LIVE` override also applies.
The pull-request-tool guard is opt-in because it spends model tokens: it launches one scratch Claude thread that links, lists, and unlinks an old merged PR, and archives that thread afterwards.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the dated live results.
