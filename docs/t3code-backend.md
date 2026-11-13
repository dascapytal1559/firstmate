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

The T3 Code fork defaults telemetry off, so every spawn and control action warns only when the listening loopback server's own process explicitly enables it or its state cannot be read.

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

Every call first runs `tools/list` and refuses unless T3 offers every tool in `REQUIRED_TOOLS` in `bin/fm-t3-mcp.mjs` (the thread, project, configuration, pending-request, and catalog tools) and `t3_environment_read`.
Those are T3 0.1.3's tool names, which the T3 Code fork serves: the binding read is `t3_thread_configure` with only `threadId`, and pending questions and approvals go through `t3_pending_request` with `action` `list`, `read`, or `respond`.
A T3 offering only the earlier `t3_thread_configuration` and `t3_pending_request_list`, `_read`, and `_respond` names is refused, naming the merged tools it lacks.
It then refuses unless `t3_environment_read` reports the environment id recorded at sign-in, so a different T3 server behind the same address is never driven with this credential.
A refusal names the missing tool or both environment ids, and spawn, control, and teardown stop before their first mutation.
This gate replaces the HTTP dispatch probe and version floor of the pre-V2 transport, which T3 0.0.46 removed.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread launched with the `existing_worktree` workspace strategy on that worktree.
A secondmate's T3 project is its home and its thread is launched with the `root` workspace strategy, so the agent runs in the home on whatever branch the home is on.
T3 assigns the thread id at launch (`mcp:<uuid>`), and the task records it as `t3_thread_id`.
The normal isolation and unlanded-work refusal rules still apply.

Each launched thread also names the T3 thread running the firstmate that spawned it as its parent, so T3 lists it as that thread's crew: a worker under the main or under the secondmate that spawned it, and a secondmate under the main.
The parent is an explicit `FM_SUPERVISOR_TARGET` that pairs with t3code, else the spawning home's FirstMate thread whether or not it is running a turn: the project's one pinned coordinator, else the one live worktree-less thread, the same cwd match away mode uses.
A spawn made between the FirstMate thread's turns, such as from a Stop-hook continuation, therefore still finds a pinned coordinator.
It is sent as `parentThreadId` only where the `t3_thread_launch` schema declares it, and the launch read-back must then show `relationshipToParent` `crew` under exactly that parent, or the thread is archived and refused like any other mis-binding.
A T3 without crew lineage, a firstmate not running in T3, or a home with no pinned coordinator and either no live thread or several launches the thread with no parent, which changes only how T3 groups it; the spawn prints a note saying why, lineage grants nothing on the parent, and stopping or archiving either thread stays independent of the other.

### Work causes

T3 Code's Usage page counts a worker's tokens to the phone or computer prompt that started it by following `causedBy`, the prompt a launch or a message names as its cause.
Firstmate names that prompt at its durable boundaries, and [`bin/fm-t3-cause-lib.sh`](../bin/fm-t3-cause-lib.sh) is the one owner of how:

- A spawn records it in the task record as `caused_by=` and sends it on the worker's launch and its brief; a relaunch keeps the recorded one.
- A steer through `fm-send.sh` keeps it in the steer's inbox record, and every doorbell for that record carries it.
- A note written with `fm-inbox.sh note` from inside a T3 turn keeps the prompt that made the agent write it, and `drain` shows it.

The cause is the one prompt of the current T3 turn of the agent running the command, which T3 names in each agent's environment as `T3CODE_THREAD_ID`.
Firstmate records nothing rather than guess: when that turn received more than one prompt (a steer or queued input joined it), when the command did not start inside that turn (a background job left over from an earlier turn), or when T3 cannot be read.
`bin/fm-t3-mcp.mjs cause` owns the exact rule, and it never reads message text.
Set `FM_T3CODE_CAUSED_BY` to `off` for no cause, or to a cause JSON (`{"threadId", "runId"?, "messageId"}`) to name one explicitly, such as the prompt a note recorded or one of several prompts a turn received.

`causedBy` is sent only where T3's `tools/list` schema declares it, so an older T3 keeps working without it.
A launch reads the thread back and refuses one that did not bind the cause; a cause T3 refuses fails the launch with nothing created, while a message whose cause T3 refuses is reported and sent again without it, so a steer never waits on its accounting.

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
A worker's thread title, the name on its crew card in T3, is its backlog item's title cut to 96 characters, so keep item titles short; it falls back to `fm-<id>`, which a secondmate always uses, and nothing keys on it.
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
Remote secondmate backend support is defined in [`remote-secondmates.md`](remote-secondmates.md#refused-and-unsupported-launches); T3 Code remains unsupported there.

Cleanup keeps all shared Firstmate safety checks, and a finished scout kept for the captain is not cleaned up until he closes its thread ([Retained reviews](#retained-reviews)).
Before the slot returns to the pool, or before a secondmate home is removed, teardown stops any active run, archives the thread with `t3_thread_organize`, and requires T3 to read back `archived:true` with no active run and no active delegated thread below it, so no live thread can act in a slot another task may lease.
A worker can start delegated T3 tasks of its own, which neither a plain interrupt nor an archive stops, so teardown sends `t3_thread_interrupt` with `stop: true` (T3's Stop: the running turn, the queued messages, and every delegated task) whenever the server's tool schema declares `stop`; on an older server it interrupts the thread's own run, and a delegated thread that still runs leaves the close unproven, naming it, until it is stopped in T3 Code.
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

### Retained reviews

A finished T3 scout keeps its thread and its worker copy until the captain closes the thread, so he can read Firstmate's handoff where the exploration happened and keep asking there.
Ships, and scouts on every other backend, keep the cleanup above.
[`bin/fm-t3-review.sh`](../bin/fm-t3-review.sh) owns the record and its transitions, [`bin/fm-t3-review-lib.sh`](../bin/fm-t3-review-lib.sh) is its one reader, and `bin/fm-t3-mcp.mjs` (`review-support`, `review-publish`, `fence`) owns the T3 calls; exact commands are in their headers.

- **Handoff.** After reading the report and passing the captain-call completion gate, Firstmate runs `retain` with its summary and its fuller explanation.
  The script composes one note in a fixed order, the summary, then the full explanation, then a link to `data/<id>/report.md` by absolute path, and saves it as `data/<id>/handoff-r<n>.md` before anything is sent.
- **Publication.** The note is posted with `t3_thread_note`, which starts no worker turn, then the thread gets the exact tag `waiting for captain` and automatic settling switched off, and a read-back proves each.
  The note's request id is derived from the home, task, spawn generation, report, and note, so a retry or a restart posts nothing twice, and a revised report or handoff appends a new note instead of rewriting the old one.
  A busy thread waits for its turn to end, a failure stays kept for the watcher to retry, and nothing is archived as a fallback.
- **Old T3.** A T3 without these tools, or one whose reads lack `tags` or `autoSettleDisabled`, cannot keep threads; `retain` (or `publish`) then exits 4, dropping any handoff it had recorded, and the scout is cleaned up as usual. When the watcher's pass is the one to find this out, it drops the record and wakes firstmate with a `check: t3-review` cleanup notice.
  A missing read-back field always means "too old", never "not set".
- **Card.** A published review reads `Waiting for captain` (see [Crew card status](#crew-card-status)); a real decision still appears on the Bridge exactly as before, and answering it never closes the exploration.
- **Watcher and recovery.** An idle kept review never enters the stale alarms or the inactive-outcome sweep, and the session-start digest names it as kept, so nothing relaunches or steers it.
  The watcher's minute pass reads each kept thread; an archived or deleted one is recorded as closed and wakes Firstmate once with a `check: t3-review <id>` notice, even when the old endpoint is gone.
  A thread he reopens is kept again; Firstmate never unarchives, steers, or revives one.
- **Cleanup.** Teardown refuses a kept review, `--force` included, until T3 reads its thread archived or deleted, and an unreadable T3 refuses too.
  A close racing publication wins.
  Once closed, the review passes every ordinary gate; after the stop-and-archive proof above, the thread must also read back fenced on its recorded worktree, so a reopened thread can never run in a slot another task takes, and only then is the copy returned.
  A deleted thread needs no fence; a fence T3 cannot prove keeps the lease and the records.

The T3 Code fork's `fork/README.md` "Threads kept for a reader" owns the note, tag, auto-settle, and fence contract.
A kept review holds one Treehouse lease for as long as the captain keeps the thread open, so it counts against the pool's capacity.

### Crew card status

A live worker's card carries T3's status label where Working, Done, or the age would be, and the thread title stays plain.
T3 still shows Approval, Input, Request, Limited, Failed, and Woke over it.

The label says what only Firstmate knows about a live T3 ship or scout, first match winning:

| Label | When |
| --- | --- |
| `Waiting for captain` | A captain hold is open on the worker's own task or was raised for it with `--origin`, or the worker is a finished scout whose handoff was published into its kept thread ([Retained reviews](#retained-reviews)), and the worker is between turns. |
| `Testing` | A ship's no-mistakes run is active: [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) reads it working or parked at a gate. It also shows while the worker works. |
| `Waiting` | Between turns, the worker waits on something other than the captain: an open decision firstmate settles, a blocker, or a declared pause. |
| `Ready` | Between turns, the worker's work is done. |
| `Failed` | Between turns, the worker or its run failed. |
| none | Otherwise, and while the worker works, so T3 shows its own Working. |

The worker works while T3 reads its thread busy or while its steering inbox holds an unhandled message, as when the captain's reply has just arrived.
A worker's `needs-decision` line alone reads `Waiting`, not `Waiting for captain`, because firstmate settles most of those itself.
A hold on a task with no live T3 ship or scout has no card and changes nothing, and the hold itself stays open until firstmate records the captain's answer.
A run left only watching a PR with green checks reads as done, so the card reads `Ready` then.

The label is a projection with no record of its own: [`bin/fm-t3-crew-status.sh`](../bin/fm-t3-crew-status.sh) computes every live card's label afresh from the backlog's captain holds, each worker's current state, its steering inbox, and its live thread, then changes only the cards whose live label differs, in one T3 session.
It runs after every hold, answer, and reconcile close, at once when a message is delivered to a T3 worker's steering inbox or a T3 run ends, and from the watcher about once a minute as the backstop, so a label that failed, a T3 that was down, or a label T3 lost is repaired by the next pass.
The watcher sees a run end from its own wait on T3, at once where that wait holds the watcher's cycle and within one poll interval in a home that also has a Herdr or Rex worker; a no-mistakes run starting or ending is seen by the minute pass.
A hold, run, or turn that cannot be read leaves the card as it is.
Cleanup clears the label before archiving the thread, even while a hold stays open.
The label is display only, and T3's `crewOf` stays what makes a thread crew.

A T3 without the status label shows none of these, and holds and cleanup carry on as usual; the cards catch up on the first pass after T3 is updated.

What T3 can rely on, for any live ship or scout card in a home with the T3 credential:

- Working is T3's own fact: Firstmate clears its label while the worker works, except `Testing`, which stays.
- A card between turns with no Firstmate label has nothing Firstmate knows it waits on, so an unlabelled finished turn may read as finished; every wait Firstmate knows of carries `Waiting for captain`, `Testing`, or `Waiting`, and finished work carries `Ready`.
- A label changes only when its meaning does, so T3's `statusLabelSince` is the time that state began; a pass re-sends nothing.
- A label is current within seconds of a hold, answer, steer, or turn end, and within about a minute of a no-mistakes run starting or ending.
- A label T3 lost, as a restart could, is set again within about a minute, and cleanup clears the label before the thread is archived.

### Bridge decisions

Each open captain call is one decision on T3's Bridge tab, listed under Needs you, or under Scheduled while it waits for a deferred date.
It carries the call's question, its options, its project (the task's repo), when it started waiting (the hold's start, which the row's age counts from), and the words FirstMate raised and updated it with, which FirstMate records through `bin/fm-captain-hold.sh context` (the `captain-hold-lifecycle` skill says when).
A call with no recorded context still appears, with its hold reason as the question.

T3 keeps the decisions as one list that FirstMate replaces whole.
[`bin/fm-t3-needs-me.sh`](../bin/fm-t3-needs-me.sh) sends it after every hold, answer, reconcile, and context, before that command returns, so the Bridge changes in the same step as FirstMate's own records; the watcher sends it again about once a minute as the backstop:

- a live call, or one that has waited longer than the aging threshold, is listed until it is answered or closed, however long it waits;
- a call deferred with `--until` is listed with a return date of 00:00 UTC on that date, so it waits under Scheduled until then;
- a blocked, answered, released, or closed call is left out, so it leaves the Bridge with the next list.

When the captain replies, T3 hides that decision at once.
It shows again only when FirstMate's version of it changes, as when his reply left the call open and FirstMate records an update.

A list T3 refuses is reported and sent again on the next pass.
The third refusal in a row also wakes FirstMate with a `check: t3-decisions` wake carrying T3's exact error, once per run of failures; FirstMate reads the error, checks that T3 is running and current, and fixes the cause rather than waiting on it.
A single decision outside T3's bounds is left off the list and named in the pass's output, so it never holds back the rest.
FirstMate's thread, where replies go, is the project's pinned coordinator, else the live thread at the home's root; with neither, no list is sent.
Only a main home takes part, because a secondmate's calls reach the captain through its parent.

The T3 Code fork's `fork/README.md` "Bridge" owns the T3 side: the list's schema and its bounds, the reply message, and the stale-reply guard.
What FirstMate sends and relies on:

- Set: `t3_decisions_set` with `replyTo`, FirstMate's thread id, and `decisions`, the whole list; a decision left out is gone, and an identical list changes nothing.
  T3 must answer with the same `replyTo` and exactly the ids and revisions sent.
- Decision: `id` (the task id), `title`, `projectName`, `since`, `question`, `options`, `entries`, `revision`, and `wakeAt` for a deferred call.
  FirstMate always sends its own `revision`: the context record's revision plus one, or 1 with no record, so every raise and update is a new revision.
  An option is its `label` alone; `changed` and an attachment's `label` are left out when absent, and an attachment's path is absolute, or a URL for a link.
  Entries are oldest first, at most 12, each text at most 8192 bytes; `bin/fm-captain-hold.sh context` checks every other field against the fork's bounds when it records it.
- Reply: the captain's reply arrives in FirstMate's chat as one user message whose second line reads `needs-me-task: <task-id>`; `bin/fm-t3-needs-me.sh reply-task` reads that id, and FirstMate records his words as the answer to that task.

`bin/fm-t3-mcp.mjs` `decisions` owns the exact call and its proof.

A T3 without `t3_decisions_set` is not supported for decisions: it is skipped quietly, as a T3 without `t3_objectives_set` is, and its Bridge shows none.

The Bridge is an additional track beside chat, never a replacement for it.
Captain's Call in chat still lists every open decision as a short line, exactly as without T3 (the `bearings` skill owns that format), while each decision on the Bridge keeps its full context and every update since it was raised.

### Objectives

T3's Bridge tab (formerly Needs me) shows the captain's high level objectives above the decisions.
Their source is the home's `data/high-level-objectives.md`: a heading, a short preamble, a `Last reviewed: YYYY-MM-DD` line, then one `- **Name:** text` bullet per objective.
Each `bin/fm-t3-needs-me.sh sync` pass builds the Bridge's list from that file, as `bin/fm-objectives.sh` reads it, and pushes it with `t3_objectives_set` only when it differs from the last list T3 accepted.
The list keeps only the bullets, each with its name in bold and its text, without the heading, the preamble, or the review line, which stays in the file and is not sent to T3.
A trailing sentence that only points at a local file, such as `Decisions so far: /path/to/decisions.md`, is left out to keep the Bridge compact.
A list past T3's 8192-character limit keeps every objective and cuts each long text instead, and the pass says so.
An absent file, or one with no bullets, clears the objectives once.
A failed push is reported and retried on the next pass without holding back the decisions, and a T3 without `t3_objectives_set` is skipped quietly.
`bin/fm-t3-mcp.mjs` (`objectives-payload` and `objectives`) owns the exact payload rules, and the T3 Code fork's `fork/README.md` owns the tool's contract; like `t3_environment_preferences_update`, it needs the full-access sign-in Firstmate already uses.

### Model routing

The Bridge also shows the home's model routing table, read-only, after the decisions.
Its source is the home's `config/crew-dispatch.json` ([Crew dispatch profiles](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson)), which this feature only reads.
Each `bin/fm-t3-needs-me.sh sync` pass renders it as Markdown grouped under a small heading per model family (such as Opus, Fable, Sol, or Grok), with no provider headings, the default's family first and the rest in order of first appearance.
The family is read from the model name for display only; it never affects which worker or credential is chosen.
Each entry is one distinct model, highlighted as inline code (harness · model · effort, leaving out a missing model or effort), and, on the line beneath it, the When of every route to it joined by " · ", a rule the captain approves marked so and the default reading "Default".
A rule's Why is not shown.
It pushes the table with `t3_routing_set` only when it differs from the last table T3 accepted.
A table past T3's 8192-character limit keeps every entry and cuts each long When to one shared length, and the pass says so.
A file that is absent or unreadable clears the table once, and only if one was sent before.
A file without the fields the table needs is reported on every pass and leaves the Bridge's table as it was; `bin/fm-bootstrap.sh` still owns validating the file for dispatch.
Failures, retries, and a T3 without `t3_routing_set` are handled exactly as for the objectives.
`bin/fm-t3-mcp.mjs` (`routing-payload` and `routing`) owns the exact table rules, and the T3 Code fork's `fork/README.md` owns the tool's contract.

### Rules

The Bridge also lists every standing rule the captain has given FirstMate, approved or not, under headings by where it applies.
Its source is the home's private `data/rules/inventory.json`, which FirstMate keeps: each rule's id, heading, file, current wording, and either the date he approved it or FirstMate's recommendation for it (keep, keep narrower with the proposed wording, make it a rule, fact, or drop).
Each `bin/fm-t3-needs-me.sh sync` pass validates it and pushes the list with `t3_rules_set` only when it differs from the last list T3 accepted.
A list outside the contract (an unknown field, a rule id other than letters, digits, dots, underscores and hyphens, a pending rule without a recommendation, more than 400 rules, a text past 2000 characters) is reported on every pass and leaves the Bridge's rules as they were; nothing is cut to fit.
A file that is absent or unreadable clears the list once, and only if one was sent before.
Failures, retries, and a T3 without `t3_rules_set` are handled exactly as for the objectives.
- Answer: tapping a pending rule's recommendation sends FirstMate's thread a message whose last line reads `rule-answer: <id> <choice>`.
  `bin/fm-rules.sh answer <id> <choice>` records it: the inventory, one rules-history log entry with his words, and the rule-file edit FirstMate still owes, which it prints; `bin/fm-rules.sh edited <id>` clears that edit once made.
  An answer he writes himself is recorded the same way with `--words-file`.
`bin/fm-t3-mcp.mjs` (`rules-payload` and `rules`) owns the exact field rules, `bin/fm-rules.sh` owns the answer mechanics, and the T3 Code fork's `fork/README.md` owns the tool's contract.

## Restart and liveness behavior

The T3 thread id, transcript, provider binding, and Treehouse worktree outlive a server connection.
A server restart cancels in-flight runs even though the thread still exists, so a worker whose turn ended without a terminal status line may need a steer, which the [server restart](#server-restart) recovery sends.
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

A T3 server restart ends every provider session it hosts at once, a Firstmate main's running as a T3 thread and every worker's, with their background commands and waits.
T3 owns the restart event, and the [T3 Code fork](https://github.com/dascapytal1559/t3code)'s `fork/README.md` owns what it promises:

- **Restart identity.** `t3_restart_status` reports `serverStartedAt`, an ISO time set once per server process, which `bin/fm-t3-mcp.mjs status` passes on.
  It works for a remote origin too; a T3 without the tool has no identity, so no restart is detected there.
- **The note.** After each start T3 sends every pinned coordinator one message opening with `The T3 server restarted at <serverStartedAt>.`, naming the crew whose runs were cut and asking it to run its session-start steps again, which for Firstmate is `bin/fm-session-start.sh`.
  It heads T3's resume when T3 resumes the coordinator's own cut turn, and otherwise comes on its own, queued behind a busy turn.
- **Continuation.** On by default (`continueThreadsAfterServerUpdate`), T3 resumes a run it cut mid-turn where it can, and wakes an idle worker whose background wait it was marked to wait on (`t3_background_wait`, or a subagent or background task); an unmarked shell wait wakes nobody.
  Turned off, T3 resumes nothing and sends nothing, but `serverStartedAt` still changes.

A worker's long command started with [`bin/fm-job.sh`](../bin/fm-job.sh), such as a broad test sweep, is outside all of this: it runs in its own session reparented to init, so a restart does not stop it.
Its result reaches the worker as a steering-inbox record that the watcher sends once the job ends, so a result that lands while T3 is down waits in the record and its doorbell starts the worker's next turn.
`bin/fm-fleet-idle.sh` does not count a worker whose only running work is such a job, so a restart staged to wait for an idle fleet does not wait for the job.
Generated briefs tell workers to run any command longer than a few minutes this way and end their turn with a `paused:` line naming the job; the recovery steer below still reaches such a worker after a restart.

What T3 cannot see is Firstmate's durable record: a worker's last `working:` or `paused:` line still reads as current after the session behind it ended.
[`bin/fm-t3-restart.sh`](../bin/fm-t3-restart.sh) `recover`, run by the locked session start in a home with `config/t3code-token`, reconciles exactly that.

- **Pinning.** Every `recover` pins the home's own thread (the one the away daemon would find) as its project's coordinator where the server advertises `coordinatorRestartNote`, so the note reaches it after every start, even one that cut no crew run.
  The note is an ordinary user turn, not Firstmate operational input, so a main follows it whatever agent runs it, and Firstmate adds no hook of its own on the main.
  On the fork a pinned coordinator's notification-started turns end without an alert; the [T3 thread protocol](supervision-protocols/t3-thread.md), rendered into the session-start block of a main running as a T3 thread, owns when such a turn asks to alert.
- **Recovery.** When `serverStartedAt` differs from the one the home last handled, every ship or scout whose current claim is `working:`, `paused:`, or nothing yet gets one recovery steer through `fm-send.sh`, whose doorbell reopens an idle session or steers a resumed run, and the digest lists them under `T3 RESTART`.
  A worker whose current claim is stamped after the restart has already resumed and said where it stands, so it gets no steer; a busy resumed run without such a line is still steered, since being busy does not show it checked what the restart took.
  Workers with an open decision, a captain-held wait, or a terminal line are left alone, and an archived thread is reported rather than rung.
- **Untrusted claims.** Until a steered worker appends a new status line, its earlier pause is no longer a declared wait for the watcher or the away daemon, and `fm-crew-state.sh` reports its earlier `working:` or `paused:` claim as unknown, so the ordinary stale handling applies instead of the four-hour pause cadence.
- **Continuation off.** Nothing wakes the main until the captain next writes to it, when the harness's own [session-start path](sessionstart-nudge.md) applies; the session start it then runs still finds the restart from `serverStartedAt` and steers every working or waiting worker, since T3 resumed none of them.

<a id="clean-restart"></a>

### Clean restart

A restart Firstmate causes itself, such as installing a new T3 build, waits until no turn anywhere would be cut, FirstMate's own included.
[`bin/fm-fleet-idle.sh`](../bin/fm-fleet-idle.sh) counts only this home's workers, so on its own it can restart T3 in the middle of the main's reply.
[`bin/fm-t3-restart-request.sh`](../bin/fm-t3-restart-request.sh) closes that gap through the T3 Code fork's restart registry:

1. Once no worker is busy, `drain` requests the restart with a reason naming the build, so T3 shows the captain a notice that it will restart, holds every new message, and lets running turns finish.
2. It returns 0 only when T3 reports drained, every turn finished, and the caller then restarts T3; the server start releases the held messages in order.
3. When T3 has not drained within `--within` seconds, `drain` cancels the request, which releases the held messages, and reports it.
   A signal cancels it the same way, as when its watch is retired or replaced by a newer build, or its action times out.
4. A request the captain cancels from T3's notice, one replaced by another reason, or a T3 that restarted on its own means no restart.
   Another reason's pending request is never requested over or cancelled.

The usual shape is a [fleet-idle watch](configuration.md#process-to-event-sources-stateprocevent) whose action runs `drain` and then the restart, with the watch's `--action-timeout` above `--within`:

```sh
bin/fm-procevent-when.sh arm <name> --on-worker-event --interval 60 --stable 1 --action-timeout 2400 \
  --condition "$PWD/bin/fm-fleet-idle.sh" -q --action <script that runs drain, then restarts T3>...
```

Inside that script, run `bin/fm-t3-restart-request.sh drain --reason "<reason>" --within 1800` and restart T3 only on exit 0.
If the restart then cannot happen, the script runs `bin/fm-t3-restart-request.sh cancel --reason "<reason>"`, because a drained request keeps holding messages until a server start.
The script's header owns its exit codes and the reason and adoption rules; `bin/fm-t3-mcp.mjs` `restart-status`, `restart-request`, and `restart-cancel` own the registry calls.

### Fresh session with /clear

T3 Code's `/clear` keeps the Firstmate thread and starts the next message in a fresh agent session, so the captain sees one chat with a divider while the new session starts with no earlier context.
The thread id does not change, so records keyed by it stay valid.
Run `/stow` first when the session holds anything worth keeping; `/clear` itself saves nothing.

1. With the next message, T3 releases the old session and ends the agent's process: SIGTERM about 2 s later, SIGKILL 5 s after that.
   Nothing releases the session lock, and the Stop hook may fire once on the way out.
   A hook that fires once the process is gone arms nothing and moves no lock, whether that is before or after the new session starts.
2. The [T3 Code fork](https://github.com/dascapytal1559/t3code)'s Claude adapter waits for that exit before the new session opens.
   Upstream T3 Code does not wait, so there a new session can start beside the old process and come up read-only.
   Its read-only digest then says the previous session on this thread is still running and names the remedy: end that process, whose unacknowledged wakes stay queued, and run session start again.
3. The new process takes the helm through the ordinary session start.
   `bin/fm-lock.sh` reclaims the dead holder's lock, so the session does not come up read-only, and it writes the same thread id to `state/t3-main-thread`.
   The T3 server has not restarted, so `bin/fm-t3-restart.sh recover` steers no worker.
4. Wakes queued during the swap, and any the old session drained but had not acknowledged when it was stopped, stay durable and reach the new session in its digest.
   Claude ends a running Stop hook, its arm, and its watcher with the session ([dated evidence](verification/runtime-backends.md#fresh-session-swap-on-real-claude)), so the new session's first Stop starts the one cycle, and it attaches instead if a watcher did outlive the old session.
   A watcher that died leaves one recovery notice, in the digest or as a wake after that first Stop, which the new session acknowledges like any other.

A startup check from the old session that is still running can refuse the lock for up to its two-minute bound, which needs a `/clear` within two minutes of the previous session's start.

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
On the T3 Code fork, whose `t3_thread_wait` declares `settleOnPendingRequest`, each run wait also ends the moment a question or approval appears that the call has not already seen, and carries the thread's pending requests, so it raises the same wake within tens of milliseconds with no extra read and no server load while workers sit idle.
Firstmate requires the fork and keeps no polling substitute: on a T3 without that argument, and for a thread whose run starts after the call began, a new request is first seen by the next call's opening read, within the poll interval, and `fm-t3-mcp.mjs status` warns (`pendingRequestPush:false`).
On a T3 whose `orchestrator_capabilities` advertises the `approvalResponses` feature, the pending-request list names each approval by request id in its `approvals` array, and the wake carries its kind, command or file, the provider's reason, and its `override` (`provider_check` or `ask_rule`).
On an earlier T3 each approval is identified by its `approval_request` activity item, which T3 holds at status `waiting` until it is answered, among the thread's last 100 items, so an approval answered and replaced by another before the next cycle is a new set ([source evidence](verification/runtime-backends.md#permission-approvals-in-the-activity-view)).
Otherwise the call waits on each thread's exact active run and returns as soon as one turns terminal, so the poll loop reconciles that turn without waiting out its interval; with no active run it sleeps the interval instead of re-arming.
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
T3 puts the thread's id in the agent's environment as `T3CODE_THREAD_ID`, which session start records in `state/t3-main-thread`, but away-mode discovery does not read it: eligible discovery matches this home's real path to a live project's `workspaceRoot`, lists its threads with an active run through every `t3_thread_list` page, and selects the one unarchived thread with no worktree of its own.
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

- T3 Code remains experimental; its harnesses are the [adapter table](#provider-instances-and-models), and every harness needs a T3 with per-thread environment and instructions ([thread channels required](#thread-channels-required)).
  `claude`, `codex`, `grok`, and `pi` have dated live evidence on this backend ([`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code)); the other rows are covered by the portable suites only.
- T3 starts every agent at `full-access` with its provider instance's account and environment, so a spawn refuses any posture setting that asks for less (`config/claude-permission-mode` other than `bypass`, `config/codex-approval-mode=approve-for-me`, or `config/codex-permission-mode=restricted`), `config/launch-env-allowlist`, `config/crew-exclude-tools`, a worker account pin, and a raw launch command; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
  Unless `config/keep-ai-trailers` is present, the thread's environment selects Firstmate's Git commit hook to strip known AI trailers, including on T3 workers.
- T3 also owns the Codex provider command, so Firstmate cannot apply the pane-backed worker's hook-disable or turn-end notify options.
  Firstmate's pane-backed hook-trust workaround therefore does not apply; supervision uses T3's [thread status table](#restart-and-liveness-behavior).
- `fm-control.sh exit` is refused because the V2 `/mcp` tools have no session stop, and `relaunch` is refused because a thread keeps its conversation, so no fresh agent can replace it.
- The WebSocket event stream is not available to an `mcp-client` credential; the [run wait](#push-events-and-polling-fallback) stands in for it.
- A permission approval can be answered through `/mcp` only on a T3 that advertises `approvalResponses`; elsewhere firstmate interrupts and steers the worker instead.
- Request-id deduplication holds within one T3 auth session only: every sign-in starts a new session, so resending an unconfirmed send, or retrying a frozen away-mode digest, after the captain signs in again can deliver it twice; verify such a message in T3 Code first.
- Shell typing and Ctrl-U are unsupported; runtime Escape and Ctrl-C still interrupt the turn.
- A Firstmate main session in a T3 thread is verified only for Claude; a Codex supervisor has no away mode on this backend because it has no tracked background tool for `start-native`, and T3 has no terminal for `start` to create.
- A [work cause](#work-causes) is established only for a command an agent runs inside its own T3 turn on the same machine; an agent that runs commands in a shell older than its turn, a remote secondmate's steer, and a turn that received several prompts record none.
- T3 checkpoints each turn as hidden refs under `refs/t3/orchestration-v2/checkpoints/` in the project clone; they are never pushed and do not affect the landed-work test.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-t3-mcp.test.sh tests/fm-backend-t3code.test.sh tests/fm-t3-crew-status.test.sh tests/fm-t3-needs-me.test.sh tests/fm-t3-restart-request.test.sh tests/fm-rules.test.sh
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-daemon.test.sh tests/fm-control.test.sh
bin/fm-test-run.sh tests/fm-t3-clear-session.test.sh
FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
FM_T3CODE_PR_TOOLS_LIVE=1 FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-pr-tools-live-e2e.test.sh
```

The portable entry points cover the T3 adapter against a [fake `/mcp` server](../tests/t3-fake-server.mjs) and fake Treehouse, plus the shared backend, daemon, and control behavior.
`tests/fm-t3-clear-session.test.sh` runs the [`/clear`](#fresh-session-with-clear) swap with real processes: a real SIGTERM, the real session start, Stop hook, host or arm, and watcher.
The live guard spends no model tokens and changes nothing on the server: it checks the gate, the project catalog, and a typed missing-thread read against the server the configured credential names, and skips cleanly without one.
Set `FM_T3CODE_LIVE_E2E=0` to disable it or `FM_T3CODE_LIVE_E2E=1` to require it; the shared `FM_LIVE` override also applies.
The pull-request-tool guard is opt-in because it spends model tokens: it launches one scratch Claude thread that links, lists, and unlinks an old merged PR, and archives that thread afterwards.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the dated live results.
