#!/usr/bin/env node
// tests/t3-fake-server.mjs - a fake T3 Code server for the t3code backend
// suites (tests/fm-t3-mcp.test.sh, tests/fm-backend-t3code.test.sh).
//
// It serves T3's headless OAuth sign-in (/oauth/mcp/register, /decision,
// /token) and the Orchestrator V2 `/mcp` streamable-HTTP endpoint with the
// tool subset bin/fm-t3-mcp.mjs drives. Shapes follow T3 main 50647de0 and
// 0.0.46 nightly as recorded in docs/verification/runtime-backends.md,
// including the protocol facts a simpler fake would hide:
//   - t3_thread_list pages by cursor (default 50, at most 100) and reports
//     each thread's relationshipToParent (fork or subagent);
//   - t3_thread_read caps limit at 100;
//   - t3_thread_wait waits on the exact runId when given and on the latest
//     run by ordinal otherwise, blocking until that run is terminal or the
//     timeout passes;
//   - t3_thread_interrupt targets the latest active run and only requests
//     the stop: the run ends asynchronously, before the next call by default;
//   - archive is distinct from run end: the active run ends asynchronously;
//   - a send is committed before its reply, which dropReplyTools can lose;
//   - pendingRequestCount counts every pending runtime request, while the
//     pending-request tools see only user-input questions;
//   - T3 0.1.3 merged t3_thread_configuration into t3_thread_configure (a
//     read when called without modelSelection; earlier T3 also lists
//     t3_thread_configure but refuses it without modelSelection) and
//     t3_pending_request_list, _read, and _respond into t3_pending_request
//     {action}. The fake serves both generations; tools/list offers the
//     earlier one by default and CURRENT_TOOLS when the world sets toolset
//     "current", and a tools/call for a tool tools/list does not offer is
//     refused, as T3 refuses it;
//   - tools/list declares t3_thread_interrupt's `stop` and t3_thread_list's
//     `allProjects` in their input schemas, and a peer from before `stop`
//     (world noStop) drops it and interrupts the run alone; with stop, the
//     latest active run and every active delegated (subagent) thread below
//     the thread are interrupted, as T3's Stop does;
//   - a fork's per-thread facts (world threadFacts): orchestrator_capabilities
//     reports threadEnvironment and threadInstructions per provider, a launch
//     binds its `environment` and `instructions`, and the configuration read
//     returns them with effectiveRuntimeMode; upstream T3 (no threadFacts)
//     drops both fields and reads back neither;
//   - orchestrator_capabilities lists a short set of models per provider and
//     counts the rest in omittedModels (a provider's `omitted` models), and
//     its declared `search` argument (absent under world noSearch) instead
//     lists every model whose id or label contains the text, with no count.
//   - a T3 with approval responses (world approvalResponses) advertises
//     features.approvalResponses in orchestrator_capabilities, and its
//     pending-request list also names each pending approval in `requests`
//     ({requestId, type: "approval", kind, command, reason, override}, from the
//     approval's runtime request), its read reads one, and its respond answers
//     one with decision allow|deny and optional feedback; without it the
//     pending-request tools see only user-input questions.
//
// Usage: t3-fake-server.mjs --case-file <file> --port-file <file> [--parent-pid <pid>] [--port <n>]
// --port listens on that port instead of a free one, so a test can restart the
// server behind the same origin.
// <case-file> holds the path of the current case directory. Every request
// re-reads <case-dir>/world.json, writes it back after a mutation, and appends
// one JSON line to <case-dir>/requests.jsonl, so a test can switch cases and
// edit the world between calls. World keys (all optional):
//   tokens (accepted bearers; sign-in appends), environmentId, serverVersion,
//   tools (array of names; default all), toolset ("current": the T3 0.1.3
//   tool names instead of the earlier default), revoked (every /mcp call is 401),
//   sse (SSE replies), expiresIn (seconds), bindWorktree, bindInstance,
//   bindRuntimeMode, bindModel, bindOptions, bindEnvironment,
//   bindInstructions, bindEffectiveRuntimeMode (override what a launch binds),
//   threadFacts, noStop,
//   archiveKeepsRun (archive never ends the run), interruptStuck or
//   waitTimesOut (an interrupt never ends the run), queueAfterInterrupt
//   (text a queued run starts with once an interrupt lands), failTools
//   ({name: {code, message}}), dropTools ({name: count}: close the connection
//   without a reply or effect that many times), dropReplyTools ({name:
//   count}: apply the call, then close without a reply), emptyReplyTools
//   ({name: count}: answer 200 with an empty event stream and no effect, as a
//   server that shuts down cleanly before replying), rpcErrorTools ({name:
//   code}: apply the call once, then answer with a JSON-RPC error of that
//   code, as a server that failed after committing), committedErrorTools
//   ({name: code}: apply the call once, then answer with a tool error of that
//   code, as T3's catch-all orchestration_error after a commit; a null code
//   answers with text content only, as a tool handler that throws), waitCapMs (one
//   t3_thread_wait times out after at most this long), probePath (each log
//   line records whether it exists), providers (the orchestrator_capabilities
//   catalog; default FAKE_PROVIDERS), projects ([{id, title, workspaceRoot,
//   defaultModelSelection, deletedAt}]), threads ({id: detail plus items,
//   runs, and runtimeRequests [{id, kind: user_input|approval, status,
//   questions, and for an approval requestKind, command, reason, override}]}). An approval's activity item is an items entry {itemId,
//   type: "approval_request", status} the world keeps beside its request.
// DELETE /mcp ends a session and is logged with the session id it names.

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].slice(2)] = process.argv[i + 1];

const ALL_TOOLS = [
  "t3_thread_launch", "t3_thread_send", "t3_thread_read", "t3_thread_wait", "t3_thread_interrupt",
  "t3_thread_organize", "t3_thread_list", "t3_thread_configuration", "t3_thread_configure", "t3_project_list", "t3_project_create",
  "t3_pending_request_list", "t3_pending_request_read", "t3_pending_request_respond",
  "orchestrator_capabilities", "t3_environment_read",
];
const CURRENT_TOOLS = ALL_TOOLS.filter((n) => n !== "t3_thread_configuration" && !n.startsWith("t3_pending_request_"))
  .concat(["t3_pending_request"]);
const offeredTools = (w) => w.tools ?? (w.toolset === "current" ? CURRENT_TOOLS : ALL_TOOLS);
const ACTIVE = new Set(["preparing", "queued", "starting", "running", "waiting"]);
const TERMINAL = new Set(["completed", "failed", "cancelled", "interrupted", "rolled_back"]);
const select = (id, values) => ({ id, label: id, type: "select", options: values.map((v) => ({ id: v, label: v })) });
// Input schemas for the tools whose optional fields the helper gates on.
const TOOL_SCHEMAS = {
  t3_thread_interrupt: (w) => ({
    type: "object",
    properties: Object.fromEntries(["environmentId", "threadId", "runId", "reason", ...(w.noStop ? [] : ["stop"]), "clientRequestId"].map((k) => [k, {}])),
  }),
  orchestrator_capabilities: (w) => ({
    type: "object",
    properties: Object.fromEntries(["environmentId", ...(w.noSearch ? [] : ["search"])].map((k) => [k, {}])),
  }),
  t3_thread_list: () => ({
    type: "object",
    properties: Object.fromEntries(["environmentId", "projectId", "allProjects", "statuses", "titleContains", "settled", "snoozed", "includeSubagents", "cursor", "limit"].map((k) => [k, {}])),
  }),
};
const FAKE_PROVIDERS = [
  {
    providerInstanceId: "claudeAgent", driverKind: "claudeAgent", displayName: "Claude", constraints: [],
    models: ["claude-sonnet-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-5-5"].map((id) => ({
      id, label: id, options: [select("effort", ["low", "medium", "high", "xhigh", "max"]), { id: "fastMode", label: "Fast Mode", type: "boolean" }],
    })),
  },
  {
    providerInstanceId: "codex", driverKind: "codex", displayName: "Codex", constraints: [],
    models: ["gpt-5.6-sol", "gpt-6-luna"].map((id) => ({
      id, label: id, options: [select("reasoningEffort", ["low", "medium", "high", "xhigh"]), select("serviceTier", ["default", "priority"])],
    })),
  },
  // The live Grok catalog entry (docs/verification/runtime-backends.md).
  {
    providerInstanceId: "grok", driverKind: "grok", displayName: "Grok", constraints: [],
    runtimeModes: ["approval-required", "auto", "full-access"],
    models: ["grok-4.7", "grok-4.7-build-fast"].map((id) => ({
      id, options: [{ id: "reasoningEffort", values: ["xhigh", "high", "medium", "low"], default: "high" }],
    })),
  },
];
// The catalog as served: with threadFacts every provider that does not say
// otherwise advertises both per-thread capabilities. A search lists every
// matching model, the omitted ones included; otherwise omitted models are
// only counted.
const servedProviders = (w, search) =>
  (w.providers ?? FAKE_PROVIDERS).map(({ omitted = [], ...p }) => {
    const all = [...(p.models ?? []), ...omitted];
    const needle = typeof search === "string" && !w.noSearch ? search.toLowerCase() : null;
    const served = needle !== null
      ? { ...p, models: all.filter((m) => `${m.id} ${m.label ?? ""}`.toLowerCase().includes(needle)) }
      : { ...p, ...(omitted.length ? { omittedModels: omitted.length } : {}) };
    return w.threadFacts ? { threadEnvironment: true, threadInstructions: true, ...served } : served;
  });

const caseDir = () => readFileSync(args["case-file"], "utf8").trim();
const worldFile = () => path.join(caseDir(), "world.json");
const loadWorld = () => {
  try {
    return JSON.parse(readFileSync(worldFile(), "utf8"));
  } catch {
    return {};
  }
};
const saveWorld = (w) => writeFileSync(worldFile(), JSON.stringify(w));
const log = (w, entry) => {
  if (w.probePath) entry.probe = existsSync(w.probePath);
  appendFileSync(path.join(caseDir(), "requests.jsonl"), `${JSON.stringify(entry)}\n`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const clients = new Map();
const codes = new Map();

function body(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
  });
}

function json(res, status, obj, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(obj));
}

const err = (code, message) => ({ isError: true, structuredContent: { error: { code, message } }, content: [{ type: "text", text: message }] });
const ok = (data) => ({ structuredContent: data, content: [{ type: "text", text: JSON.stringify(data) }] });
const now = () => new Date().toISOString();

const pendingRequests = (t) => (t.runtimeRequests ?? []).filter((r) => r.status === "pending");
// A pending approval as the approval-responses pending-request tools show it.
const approvalEntry = (r) => ({
  requestId: r.id, type: "approval", kind: r.requestKind ?? "command", command: r.command ?? null, reason: r.reason ?? null, override: r.override ?? null,
});

function detail(t) {
  const { items, runs, runtimeRequests, modelSelection, environment, instructions, ...rest } = t;
  if (runtimeRequests) rest.pendingRequestCount = pendingRequests(t).length;
  return rest;
}

// Runs newest first; a run without an ordinal ranks by its array position.
const byOrdinal = (t) => (t.runs ?? []).map((r, i, all) => ({ r, o: r.ordinal ?? all.length - i })).sort((a, b) => b.o - a.o).map((x) => x.r);
const latestRun = (t) => byOrdinal(t)[0];
const latestActiveRun = (t) => byOrdinal(t).find((r) => ACTIVE.has(r.status));

function refreshThread(t) {
  const active = latestActiveRun(t);
  t.activeRunId = active?.runId ?? null;
  t.status = active?.status ?? latestRun(t)?.status ?? "idle";
}

function startRun(t, text) {
  const runId = `run:${randomUUID()}`;
  t.runs = t.runs ?? [];
  const ordinal = Math.max(0, ...byOrdinal(t).map((r, i, all) => r.ordinal ?? all.length - i)) + 1;
  t.runs.unshift({ runId, ordinal, status: "running", requestedAt: now(), startedAt: now(), completedAt: null });
  t.activeRunId = runId;
  t.status = "running";
  t.latestRunId = runId;
  t.items = t.items ?? [];
  t.items.push({ type: "user_message", status: "completed", text });
  return runId;
}

function endRun(t, run, status) {
  run.status = status;
  run.completedAt = now();
  delete run.stopRequested;
  if ((t.runs ?? []).length > 0) refreshThread(t);
}

// The asynchronous provider effects of an earlier interrupt or archive land
// before the next call (or wait poll), unless the world holds them back.
function settle(w) {
  let changed = false;
  for (const t of Object.values(w.threads ?? {})) {
    for (const run of t.runs ?? []) {
      if (!run.stopRequested || !ACTIVE.has(run.status)) continue;
      if (run.stopRequested === "interrupt" && (w.interruptStuck || w.waitTimesOut)) continue;
      if (run.stopRequested === "archive" && w.archiveKeepsRun) continue;
      endRun(t, run, "interrupted");
      changed = true;
      if (run.queueAfterInterrupt) startRun(t, run.queueAfterInterrupt);
    }
  }
  return changed;
}

const notFound = (id) => err("thread_not_found", `Thread ${id} is no longer available.`);

function listItem(x) {
  return {
    threadId: x.threadId, title: x.title, status: x.status, latestRunId: x.latestRunId ?? null,
    parentThreadId: x.parentThreadId ?? null, relationshipToParent: x.relationshipToParent ?? null,
  };
}

// Every delegated (subagent) thread below <id>, at any depth.
function descendants(threads, id) {
  const out = [];
  const queue = [id];
  while (queue.length) {
    const parent = queue.shift();
    for (const x of Object.values(threads)) {
      if (x.parentThreadId === parent && x.relationshipToParent === "subagent") {
        out.push(x);
        queue.push(x.threadId);
      }
    }
  }
  return out;
}

// Returns [result, changed].
async function callTool(w, name, a) {
  const fail = (w.failTools ?? {})[name];
  if (fail) return [err(fail.code, fail.message), false];
  const threads = (w.threads = w.threads ?? {});
  const projects = (w.projects = w.projects ?? []);
  const t = a.threadId !== undefined ? threads[a.threadId] : undefined;
  switch (name) {
    case "t3_environment_read":
      return [ok({ environmentId: w.environmentId ?? "env-fake-1", serverVersion: w.serverVersion ?? "0.0.46-nightly.fake" }), false];
    case "orchestrator_capabilities":
      return [ok({
        parentThreadId: null, runtimeMode: "full-access", interactionMode: "default", providers: servedProviders(w, a.search),
        features: { appOwnedSubagents: true, ...(w.approvalResponses ? { approvalResponses: true } : {}) },
      }), false];
    case "t3_project_list":
      return [ok({ projects, nextCursor: null }), false];
    case "t3_project_create": {
      if (projects.some((p) => !p.deletedAt && p.workspaceRoot === a.workspaceRoot)) return [err("invalid_request", "workspace already registered"), false];
      const p = { id: `mcp:proj-${randomUUID()}`, title: a.title, workspaceRoot: a.workspaceRoot, defaultModelSelection: null, deletedAt: null };
      projects.push(p);
      return [ok(p), true];
    }
    case "t3_thread_launch": {
      const ws = a.workspaceStrategy ?? {};
      const id = `mcp:${randomUUID()}`;
      const sel = a.modelSelection ?? {};
      const modelSelection = {
        instanceId: w.bindInstance ?? sel.instanceId,
        model: w.bindModel ?? sel.model,
        ...(w.bindOptions !== undefined ? { options: w.bindOptions } : sel.options !== undefined ? { options: sel.options } : {}),
      };
      const n = {
        threadId: id, projectId: a.projectId, title: a.title, status: "idle", latestRunId: null, activeRunId: null,
        providerInstanceId: modelSelection.instanceId, model: modelSelection.model, modelSelection,
        runtimeMode: w.bindRuntimeMode ?? a.runtimeMode, interactionMode: a.interactionMode,
        branch: ws.branch ?? null, worktreePath: w.bindWorktree ?? (ws.type === "existing_worktree" ? ws.worktreePath : null),
        parentThreadId: null, relationshipToParent: null, pendingRequestCount: 0, archived: false, items: [], runs: [],
      };
      if (w.threadFacts) {
        if (a.environment !== undefined || w.bindEnvironment !== undefined) n.environment = w.bindEnvironment ?? a.environment;
        if (a.instructions !== undefined || w.bindInstructions !== undefined) n.instructions = w.bindInstructions ?? a.instructions;
      }
      threads[id] = n;
      if (a.message) startRun(n, a.message);
      return [ok({ threadId: id, projectId: n.projectId, runId: n.activeRunId, status: n.status }), true];
    }
    case "t3_thread_send": {
      if (!t) return [notFound(a.threadId), false];
      if (t.archived) return [err("thread_not_sendable", `Thread ${a.threadId} is archived and cannot receive messages.`), false];
      w.requestIds = w.requestIds ?? {};
      const key = `${a.threadId}|${a.clientRequestId}`;
      if (a.clientRequestId && w.requestIds[key]) return [ok(w.requestIds[key]), false];
      let delivery = "steered";
      if (t.activeRunId) t.items.push({ type: "user_message", status: "completed", text: a.message });
      else {
        startRun(t, a.message);
        delivery = "started";
      }
      const out = { threadId: t.threadId, messageId: `msg:${randomUUID()}`, runId: t.activeRunId, status: "running", delivery };
      if (a.clientRequestId) w.requestIds[key] = out;
      return [ok(out), true];
    }
    case "t3_thread_read": {
      if (!t) return [notFound(a.threadId), false];
      if ((a.limit ?? 0) > 100) return [err("invalid_request", "limit must be <= 100"), false];
      // T3 pages forward from afterPosition (exclusive), oldest first.
      const matching = (t.items ?? []).map((it, position) => ({ ...it, position })).filter((it) => it.position > (a.afterPosition ?? -1));
      const items = matching.slice(0, a.limit ?? 50);
      const thread = { ...detail(t), itemCount: (t.items ?? []).length };
      return [ok({ thread, recentRuns: byOrdinal(t).slice(0, a.runLimit ?? 5), items, nextPosition: items.at(-1)?.position ?? null, hasMore: matching.length > items.length }), false];
    }
    case "t3_thread_list": {
      if ((a.limit ?? 0) > 100) return [err("invalid_request", "limit must be <= 100"), false];
      const wanted = a.statuses ? new Set(a.statuses) : null;
      const list = Object.values(threads)
        .filter((x) => (a.allProjects === true || x.projectId === a.projectId) && (!wanted || wanted.has(x.status)))
        .filter((x) => a.includeSubagents !== false || x.relationshipToParent !== "subagent");
      const cursor = a.cursor ?? 0;
      const page = list.slice(cursor, cursor + (a.limit ?? 50));
      const nextCursor = cursor + page.length < list.length ? cursor + page.length : null;
      return [ok({ projectId: a.projectId, currentThreadId: null, threads: page.map(listItem), nextCursor, total: list.length }), false];
    }
    case "t3_thread_configure":
      if (a.modelSelection === undefined && offeredTools(w).includes("t3_thread_configuration")) {
        return [err("invalid_params", "Invalid parameters for tool 't3_thread_configure': Missing key at [\"modelSelection\"]"), false];
      }
      if (a.modelSelection !== undefined) return [err("unsupported", "the fake serves only the configuration read"), false];
    // falls through: from T3 0.1.3, without modelSelection it is the read
    case "t3_thread_configuration": {
      if (!t) return [notFound(a.threadId), false];
      const modelSelection = t.modelSelection ?? { instanceId: t.providerInstanceId, model: t.model };
      const facts = w.threadFacts
        ? { environment: t.environment ?? {}, instructions: t.instructions ?? null, effectiveRuntimeMode: w.bindEffectiveRuntimeMode ?? t.runtimeMode }
        : {};
      return [ok({ threadId: t.threadId, modelSelection, runtimeMode: t.runtimeMode, interactionMode: t.interactionMode ?? "default", ...facts }), false];
    }
    case "t3_thread_wait":
      return [await waitRun(a), false];
    case "t3_thread_interrupt": {
      if (!t) return [notFound(a.threadId), false];
      if (a.stop === true && !w.noStop) {
        // T3's Stop: the running turn, whichever run it is, and every active
        // delegated thread below this one.
        let changed = false;
        for (const child of descendants(threads, t.threadId)) {
          const childRun = latestActiveRun(child);
          if (childRun) {
            childRun.stopRequested = "interrupt";
            changed = true;
          }
        }
        const run = latestActiveRun(t);
        if (!run) return [ok({ threadId: t.threadId, runId: null, status: "no_active_run" }), changed];
        run.stopRequested = "interrupt";
        return [ok({ threadId: t.threadId, runId: run.runId, status: "interrupt_requested" }), true];
      }
      const explicit = a.runId === undefined ? undefined : (t.runs ?? []).find((r) => r.runId === a.runId);
      if (a.runId !== undefined && !explicit) return [err("run_not_found", `Run ${a.runId} is not in thread ${a.threadId}.`), false];
      if (explicit && TERMINAL.has(explicit.status)) return [ok({ threadId: t.threadId, runId: explicit.runId, status: explicit.status }), false];
      const run = latestActiveRun(t);
      if (!run) {
        if (a.runId === undefined) return [ok({ threadId: t.threadId, runId: null, status: "no_active_run" }), false];
        return [err("thread_not_interruptible", `Run ${a.runId} is not interruptible.`), false];
      }
      if (a.runId !== undefined && run.runId !== a.runId) return [err("thread_not_interruptible", `Run ${a.runId} is not interruptible.`), false];
      run.stopRequested = "interrupt";
      if (w.queueAfterInterrupt) run.queueAfterInterrupt = w.queueAfterInterrupt;
      return [ok({ threadId: t.threadId, runId: run.runId, status: "interrupt_requested" }), true];
    }
    case "t3_thread_organize": {
      if (!t) return [notFound(a.threadId), false];
      if (a.action === "archive") {
        t.archived = true;
        const run = latestActiveRun(t);
        if (run) run.stopRequested = "archive";
        else if (t.activeRunId && !w.archiveKeepsRun) {
          // A hand-written thread whose run list does not name its active run.
          t.activeRunId = null;
          t.status = "interrupted";
        }
      }
      return [ok({ threadId: t.threadId, action: a.action }), true];
    }
    case "t3_pending_request":
      if (!["list", "read", "respond"].includes(a.action)) return [err("invalid_action", `unknown action ${a.action}`), false];
      return callTool(w, `t3_pending_request_${a.action}`, a);
    case "t3_pending_request_list": {
      if (!t) return [notFound(a.threadId), false];
      const requestIds = pendingRequests(t).filter((r) => r.kind === "user_input").map((r) => r.id);
      if (!w.approvalResponses) return [ok({ requestIds }), false];
      const requests = [
        ...requestIds.map((requestId) => ({ requestId, type: "question" })),
        ...pendingRequests(t).filter((r) => r.kind === "approval").map(approvalEntry),
      ];
      return [ok({ requestIds, requests }), false];
    }
    case "t3_pending_request_read":
    case "t3_pending_request_respond": {
      if (!t) return [notFound(a.threadId), false];
      const appr = w.approvalResponses && pendingRequests(t).find((r) => r.id === a.requestId && r.kind === "approval");
      if (appr) {
        if (name === "t3_pending_request_read") return [ok(approvalEntry(appr)), false];
        if (!["allow", "deny"].includes(a.decision)) return [err("invalid_request", "decision must be allow or deny"), false];
        appr.status = "resolved";
        appr.decision = a.decision;
        if (a.feedback !== undefined) appr.feedback = a.feedback;
        for (const it of t.items ?? []) if (it.type === "approval_request" && it.itemId === `turn-item:runtime-request:${appr.id}`) it.status = a.decision === "allow" ? "completed" : "cancelled";
        return [ok({ sequence: 1 }), true];
      }
      const q = pendingRequests(t).find((r) => r.id === a.requestId && r.kind === "user_input");
      if (!q) return [err("request_not_found", `Request ${a.requestId} is not a pending question in thread ${a.threadId}.`), false];
      if (name === "t3_pending_request_read") return [ok({ requestId: q.id, questions: q.questions ?? [] }), false];
      q.status = "resolved";
      q.answers = a.answers;
      return [ok({ sequence: 1 }), true];
    }
    default:
      return [err("unknown_tool", `no tool ${name}`), false];
  }
}

// t3_thread_wait: T3 selects the exact runId, else the latest run by ordinal,
// and resolves when that run is terminal or the timeout passes.
async function waitRun(a) {
  const deadline = Date.now() + Math.max(1, Math.min(a.timeoutMs ?? 600_000, loadWorld().waitCapMs ?? Infinity));
  for (;;) {
    const w = loadWorld();
    if (settle(w)) saveWorld(w);
    const t = (w.threads ?? {})[a.threadId];
    if (!t) return notFound(a.threadId);
    const run = a.runId === undefined ? latestRun(t) : (t.runs ?? []).find((r) => r.runId === a.runId);
    if (a.runId !== undefined && !run) return err("run_not_found", `Run ${a.runId} is not in thread ${a.threadId}.`);
    if (!run) return ok({ threadId: t.threadId, runId: null, status: "idle", timedOut: false });
    if (!ACTIVE.has(run.status)) return ok({ threadId: t.threadId, runId: run.runId, status: run.status, timedOut: false });
    if (Date.now() >= deadline) return ok({ threadId: t.threadId, runId: run.runId, status: run.status, timedOut: true });
    await sleep(25);
  }
}

async function mcp(req, res) {
  const w = loadWorld();
  const auth = (req.headers.authorization ?? "").replace(/^Bearer /, "");
  const msg = JSON.parse(await body(req));
  const entry = { path: "/mcp", method: msg.method, tool: msg.params?.name, arguments: msg.params?.arguments, auth, protocol: req.headers["mcp-protocol-version"] };
  if (w.revoked || !(w.tokens ?? []).includes(auth)) {
    log(w, { ...entry, status: 401 });
    return json(res, 401, { error: "invalid_token" });
  }
  if (msg.method === "tools/call" && (w.dropTools ?? {})[msg.params.name] > 0) {
    w.dropTools[msg.params.name]--;
    saveWorld(w);
    log(w, { ...entry, dropped: true });
    return req.socket.destroy();
  }
  if (msg.method === "tools/call" && (w.emptyReplyTools ?? {})[msg.params.name] > 0) {
    w.emptyReplyTools[msg.params.name]--;
    saveWorld(w);
    log(w, { ...entry, emptyReply: true });
    res.writeHead(200, { "content-type": "text/event-stream", "mcp-session-id": "sess-fake" });
    return res.end();
  }
  let result;
  if (msg.method === "initialize") {
    result = { protocolVersion: msg.params.protocolVersion, serverInfo: { name: "t3", version: w.serverVersion ?? "0.0.46-nightly.fake" }, capabilities: { tools: {} } };
  } else if (msg.method === "notifications/initialized") {
    log(w, entry);
    res.writeHead(202);
    return res.end();
  } else if (msg.method === "tools/list") {
    result = { tools: offeredTools(w).map((name) => ({ name, inputSchema: TOOL_SCHEMAS[name]?.(w) ?? { type: "object" } })) };
  } else if (msg.method === "tools/call" && !offeredTools(w).includes(msg.params.name)) {
    result = err("unknown_tool", `Tool ${msg.params.name} not found`);
  } else if (msg.method === "tools/call") {
    let changed = settle(w);
    let mutated;
    [result, mutated] = await callTool(w, msg.params.name, msg.params.arguments ?? {});
    changed = changed || mutated;
    // A wait re-reads the world while it blocks; never write back the stale copy.
    if (changed && msg.params.name !== "t3_thread_wait") saveWorld(w);
    if ((w.dropReplyTools ?? {})[msg.params.name] > 0) {
      const fresh = loadWorld();
      fresh.dropReplyTools[msg.params.name]--;
      saveWorld(fresh);
      log(fresh, { ...entry, replyDropped: true });
      return req.socket.destroy();
    }
    if ((w.rpcErrorTools ?? {})[msg.params.name] !== undefined) {
      const fresh = loadWorld();
      const code = fresh.rpcErrorTools[msg.params.name];
      delete fresh.rpcErrorTools[msg.params.name];
      saveWorld(fresh);
      log(fresh, { ...entry, rpcError: code });
      return json(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code, message: "internal error" } }, { "mcp-session-id": "sess-fake" });
    }
    if ((w.committedErrorTools ?? {})[msg.params.name] !== undefined) {
      const fresh = loadWorld();
      const code = fresh.committedErrorTools[msg.params.name];
      delete fresh.committedErrorTools[msg.params.name];
      saveWorld(fresh);
      log(fresh, { ...entry, committedError: code });
      const result = code === null ? { isError: true, content: [{ type: "text", text: "The operation could not be completed." }] } : err(code, "The operation could not be completed.");
      return json(res, 200, { jsonrpc: "2.0", id: msg.id, result }, { "mcp-session-id": "sess-fake" });
    }
  } else {
    return json(res, 200, { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
  }
  log(w, entry);
  const reply = { jsonrpc: "2.0", id: msg.id, result };
  const headers = { "mcp-session-id": "sess-fake" };
  if (w.sse) {
    res.writeHead(200, { "content-type": "text/event-stream", ...headers });
    return res.end(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
  }
  return json(res, 200, reply, headers);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  try {
    if (req.method === "POST" && url.pathname === "/mcp") return await mcp(req, res);
    if (req.method === "DELETE" && url.pathname === "/mcp") {
      log(loadWorld(), { path: url.pathname, method: "DELETE", session: req.headers["mcp-session-id"] ?? null, protocol: req.headers["mcp-protocol-version"] });
      res.writeHead(200);
      return res.end();
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/register") {
      const b = JSON.parse(await body(req));
      const id = `client-${randomBytes(4).toString("hex")}`;
      clients.set(id, b);
      log(loadWorld(), { path: url.pathname, client_name: b.client_name });
      return json(res, 201, { client_id: id });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/decision") {
      const b = JSON.parse(await body(req));
      log(loadWorld(), { path: url.pathname, tag: b.decision?._tag, access: b.decision?.access });
      if (b.decision?.code !== "PAIR-OK") return json(res, 400, { error: "invalid_pairing" });
      const code = randomBytes(8).toString("hex");
      codes.set(code, { challenge: b.authorization.code_challenge, access: b.decision.access });
      const to = new URL(b.authorization.redirect_uri);
      to.searchParams.set("code", code);
      to.searchParams.set("state", b.authorization.state);
      return json(res, 200, { redirectTo: to.href });
    }
    if (req.method === "POST" && url.pathname === "/oauth/mcp/token") {
      const b = new URLSearchParams(await body(req));
      const w = loadWorld();
      const entry = codes.get(b.get("code"));
      const challenge = createHash("sha256").update(b.get("code_verifier") ?? "").digest("base64url");
      log(w, { path: url.pathname, grant_type: b.get("grant_type"), pkce: Boolean(entry && entry.challenge === challenge) });
      if (!entry || entry.challenge !== challenge) return json(res, 400, { error: "invalid_grant" });
      const token = `tok-${randomBytes(12).toString("hex")}`;
      w.tokens = [...(w.tokens ?? []), token];
      saveWorld(w);
      return json(res, 200, { access_token: token, token_type: "Bearer", expires_in: w.expiresIn ?? 2592000, scope: "orchestration:read orchestration:operate" });
    }
    json(res, 404, { error: "not_found" });
  } catch (e) {
    json(res, 500, { error: String(e) });
  }
});

server.listen(Number(args.port ?? 0), "127.0.0.1", () => {
  writeFileSync(args["port-file"], String(server.address().port));
});

if (args["parent-pid"]) {
  setInterval(() => {
    try {
      process.kill(Number(args["parent-pid"]), 0);
    } catch {
      process.exit(0);
    }
  }, 500).unref();
}
