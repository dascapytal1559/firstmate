#!/usr/bin/env node
// fm-t3-mcp.mjs - Firstmate's shell-callable client for a T3 Code server's
// Orchestrator V2 `/mcp` endpoint, the transport of the experimental `t3code`
// runtime backend (docs/t3code-backend.md owns the operator contract).
//
// Only bin/backends/t3code.sh and the captain's own sign-in call this; agents
// never do. Every verb opens one MCP streamable-HTTP session (protocol
// 2025-06-18, JSON or SSE replies), proves the server is the one the
// credential was issued by, runs the call, and prints exactly one JSON object
// on stdout.
//
// Usage:
//   fm-t3-mcp.mjs login --access full-access [--url <origin>] [--t3 <t3-bin>] [--base-dir <t3-base-dir>] [--label <label>]
//     Captain-run sign-in. Mints a two-minute one-time pairing code with the
//     operator's own `t3 auth pairing create` scoped to SCOPES, spends it on
//     T3's OAuth decision API at the chosen ceiling, exchanges the code with a PKCE verifier, and writes
//     the credential, the server's origin, its environment id, and its version
//     to the token file (mode 0600). The token and pairing code are never
//     printed. Only the full-access ceiling is accepted. The origin defaults to
//     $FM_T3CODE_ORIGIN, else the `origin` in
//     ~/.t3/userdata/server-runtime.json.
//   fm-t3-mcp.mjs status
//     Credential expiry, the capability gate, whether a loopback server's
//     own process runs with telemetry off (telemetry: off|on|unknown; anything
//     but off adds a stderr warning), and that process's identity
//     (serverStart: "<pid>@<kernel start time>", null for a remote origin or
//     an unreadable listener), which changes on every server restart.
//     Changes nothing.
//   fm-t3-mcp.mjs project-ensure --root <abs-path> [--title <title>]
//     The live T3 project whose workspaceRoot is <root> by real path, created
//     when absent. A create that fails is looked up again, so a project a
//     concurrent spawn registered meanwhile is used rather than refused.
//   fm-t3-mcp.mjs project-read --project <id>
//     That project's record (defaultModelSelection included); exit 3 with
//     code project_not_found when T3 lists no live project with that id.
//   fm-t3-mcp.mjs harness --harness <name>
//     The HARNESSES adapter-table row for that harness (driverKind,
//     effortOption, and either a default instanceId or an ACP registry
//     agentId), read locally with no server call; exit 4
//     (harness_unsupported) for a harness T3 cannot run.
//   fm-t3-mcp.mjs resolve-selection --harness <name> [--instance <id>]
//       --model <slug|default> --effort <level|default> [--project <id> | --root <abs-path>]
//     The model selection a launch sends, resolved against T3's own catalog
//     (orchestrator_capabilities): the instance (without --instance, the
//     row's default, or for an ACP registry row the one instance of any name
//     that reports its agentId, refusing none or several) must exist, be
//     usable, run the harness's driver, report the row's ACP registry agentId
//     when the row names one, and list full-access among its runtimeModes
//     when it lists any; the model must be one that instance lists, searched
//     for by its exact slug when the short list omits models and the tool
//     declares search; model default takes the default selection of the
//     project (by id, or the live project rooted at --root, read only),
//     which must name the same instance. A non-default effort must be one of
//     EFFORT_WORDS and is sent as the catalog value of that name on the row's
//     effort option (or the model's one EFFORT_OPTION_IDS option), replacing
//     only that option and keeping every other default option; every option
//     is then checked against that model's descriptors. The result also
//     carries the instance's threadEnvironment and threadInstructions
//     capabilities (false unless the catalog says true). Exit 4 refuses.
//   fm-t3-mcp.mjs launch --project <id> --title <title> --model-selection <json>
//       [--worktree <abs-path>] [--branch <name>] [--message-file <file>]
//       [--environment-file <json-file>] [--instructions-file <file>]
//       [--parent <thread-id>]
//     t3_thread_launch at runtimeMode full-access. With --worktree the
//     workspace strategy is existing_worktree; without it, root (the project's
//     own checkout). --environment-file (a JSON object of shell-variable names
//     to strings) and --instructions-file ride as the launch's per-thread
//     environment and instructions. --parent names the thread this one works
//     for, sent as parentThreadId only where t3_thread_launch's tools/list
//     schema declares it (T3 then lists the thread as that thread's crew);
//     elsewhere the launch goes ahead without it, and the result's
//     parentThreadId is null. Reads the thread and its configuration
//     back and archives and refuses it unless T3 bound exactly that
//     workspace, full access (and effectiveRuntimeMode full-access when the
//     read reports one), instance, model, every requested option value,
//     the given environment and instructions, and, when a parent was sent,
//     relationshipToParent crew under exactly that parent; a refused
//     thread that does not then read back archived with no active run exits
//     1, because it may still be live. A read-back that fails also archives
//     and exits 1, since the thread exists but its binding is unproven. T3's
//     catch-all orchestration_error can follow a created thread, so it exits
//     1 as well. A transport or unexpected failure of the
//     gate, before t3_thread_launch is requested, exits 8: no thread was
//     launched. Without --message-file the thread is created idle.
//   fm-t3-mcp.mjs send --thread <id> --message-file <file> --client-request-id <id>
//     t3_thread_send mode auto: start an idle thread's next turn or steer the
//     running one. T3 derives the message and command ids from the client
//     request id within the auth session that sent it, so a retry with the
//     same id under the same sign-in is the same delivery; after a fresh
//     sign-in it is a new delivery and can duplicate. T3 commits a send
//     before it replies, so a reply lost after the request went out, or T3's
//     catch-all orchestration_error, exits 7 (delivery_unconfirmed): the
//     message may have landed, and only a retry with the same client request
//     id is safe. A refusal before the request went out, or T3's own specific
//     typed refusal, is proven non-delivery for this attempt; exit 3 is only
//     T3's refusal of the send itself, so a typed failure of the gate's reads
//     exits 1.
//   fm-t3-mcp.mjs state --thread <id>
//     exists, archived, status, activeRunId, pendingRequestCount,
//     worktreePath, turnAt (the latest run's completion, else its start or
//     request time), latestRunId and latestRunStatus, runs (the newest
//     STATE_RUN_LIMIT runs as {runId, status}, newest first), and
//     latestRunError: the message of the latest `error` activity item of a
//     latest run that read failed, else null (T3's failure class never leaves
//     the server on this credential; the message is what `/mcp` exposes). A
//     thread the verified server does not have reads exists:false.
//   fm-t3-mcp.mjs read --thread <id> [--limit <n>]
//     t3_thread_read: the thread record and its latest run, unchanged. T3
//     caps --limit at 100.
//   fm-t3-mcp.mjs capture --thread <id> [--lines <n>]
//     The activity view rendered as a plain-text tail of at most 500 lines (a
//     larger --lines reads 500); the one verb whose stdout is text rather
//     than JSON.
//   fm-t3-mcp.mjs wait --thread <id> [--run <run-id>] [--timeout-ms <n>]
//     t3_thread_wait until that run (the latest run without --run) is
//     terminal or the timeout passes. Every wait re-arms in slices of at
//     most 240 s, under the 300 s Node's fetch allows one reply.
//   fm-t3-mcp.mjs interrupt --thread <id> [--timeout-ms <n>]
//     t3_thread_interrupt (T3 stops the latest active run), then
//     t3_thread_wait on exactly the run T3 named; cancel is confirmed only
//     when that run reads terminal, not-running when there was no active run,
//     and unconfirmed otherwise (timeout, or a wait that answered for a
//     different run). T3 ends the run asynchronously after the request.
//   fm-t3-mcp.mjs requests --thread <id>
//     The thread's pending runtime requests: questions (each user-input
//     request id with its questions, from T3's pending-request list/read);
//     approvalResponses, whether orchestrator_capabilities advertises that
//     feature; approvalRequests, the permission approvals T3's pending-request
//     list names when it does, each {requestId, kind, detail (the command or
//     file), reason, override (provider_check, ask_rule, or null)}; and
//     approvals, the count of the remaining pending requests those tools
//     cannot see or answer (every permission approval on a T3 without
//     approvalResponses). The signature
//     names the question ids, that count, the activity item id of each such
//     request T3 shows among the thread's last 100 items, and the request id
//     of each answerable approval.
//   fm-t3-mcp.mjs respond --thread <id> --request <request-id> --answers-file <file>
//     T3's pending-request respond with the JSON object in <file>, keyed by
//     question id. It answers questions only; approve answers an approval.
//   fm-t3-mcp.mjs approve --thread <id> --request <request-id> --decision allow|deny [--feedback-file <file>]
//     Answer one pending permission approval through T3's pending-request
//     respond, as T3 Code's own buttons do. Refuses (exit 4) unless
//     orchestrator_capabilities advertises approvalResponses and the request
//     reads back as an approval; --feedback-file holds the text the agent
//     sees, accepted only with deny. Prints the decision and the approval's
//     normalized entry as read just before the answer.
//   fm-t3-mcp.mjs watch --thread <id>... --timeout-ms <n> [--escalated <id>=<signature>]... [--state-dir <dir>]
//     The T3 event wait for the watcher. It first reads every thread: one
//     whose pending requests changed from its --escalated signature reports
//     event:blocked with that signature (as requests computes it), its
//     question ids, its approval count, and its approvalRequests; a thread given --escalated with
//     nothing pending is listed in cleared. Otherwise it waits on the exact
//     active run of every thread at once and reports event:run-ended, with
//     that run's threadId, runId, and terminal status, for the first that
//     turns terminal, event:timeout when none does, or event:none when no
//     thread has an active run (the caller sleeps instead of re-arming).
//     With --state-dir the same wait also races a change to a *.status or
//     *.turn-ended entry in that directory (bin/fm-state-watch.mjs owns the
//     filter and debounce) and reports event:state-changed with the entry's
//     name first; a directory watch that cannot be opened waits out the
//     budget instead, so the verb never spins, and with no active run the
//     wait then holds for the budget rather than answering none. When every
//     run wait failed rather than returned, the first failure is the verb's
//     error. --timeout-ms 0 reads the pending requests only and answers
//     event:none without waiting, for a cycle whose wait another backend holds.
//   fm-t3-mcp.mjs archive --thread <id> [--timeout-ms <n>]
//     t3_thread_organize archive, then read back until the thread reports
//     archived:true and activeRunId:null and no delegated (subagent) thread
//     below it, at any depth, has an active status (closed=true). A thread
//     the verified server no longer has is already closed (missing=true). A
//     close the read-back does not prove within the timeout exits 1
//     (close_unproven, naming any delegated thread still active).
//   fm-t3-mcp.mjs close --thread <id> [--timeout-ms <n>]
//     The teardown kill: closed at once for a missing thread or an archived
//     one with no active run and no active delegated thread below it;
//     otherwise an active run, or an active delegated thread, is stopped
//     with t3_thread_interrupt stop:true where that tool's tools/list schema
//     declares stop (T3's Stop: the turn, the queue, and every delegated
//     task), else the run alone with a plain interrupt, and the thread is
//     then archived with archive's proof.
//   fm-t3-mcp.mjs thread-for-root --root <abs-path>
//     The one unarchived, worktree-less thread with an active run on the live
//     project rooted at <root>, across every t3_thread_list page; a fork
//     counts, a delegated subagent does not: exit 0 with threadId; exit 5
//     when there is none; exit 6 when there are several (threadIds names
//     them).
//
// Every verb accepts --token-file <path>. It defaults to
// $FM_T3CODE_TOKEN_FILE, else ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/t3code-token,
// with FM_HOME defaulting to this repository.
//
// The capability gate (every verb, login included) runs tools/list and refuses
// unless all of REQUIRED_TOOLS and t3_environment_read are present and each
// TOOL_FAMILIES capability is met by its current or earlier tools, then reads
// t3_environment_read and refuses unless its environmentId equals the one
// recorded at sign-in, so a different T3 on the same origin is never driven
// with this credential.
//
// FM_T3CODE_ARCHIVE_TIMEOUT_MS, a positive integer, replaces the 15000 ms bound
// on the read-back that proves an archive (launch's cleanup archive, and
// archive's default --timeout-ms).
//
// Exit: 0 success; 1 transport or unexpected failure, including a JSON-RPC
// server error or any non-2xx HTTP answer, neither of which proves the request
// was not applied; 2 invalid use; 3 a typed T3 failure (a tool error, or a
// JSON-RPC error in a 2xx reply refusing the request itself: parse error,
// invalid request, unknown method, or invalid params; error.code carries T3's
// code, and a tool error without one reads as T3's catch-all
// orchestration_error); 4 a local refusal
// (no credential, expired credential, revoked credential, environment
// mismatch, capability gate, or a launch binding mismatch whose thread read
// back archived); 5 and 6 as thread-for-root says; 7 a
// mutation whose request went out but whose outcome is unproven (send); 8 a launch
// that failed before t3_thread_launch was requested (launch). A failure prints {"ok":false,"error":{...}} on stdout and one line on stderr.
// A credential within EXPIRY_WARN_DAYS of expiry adds a stderr warning on
// every verb and a `credentialWarning` field on status.

import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { watchStateDir } from "./fm-state-watch.mjs";

export const PROTOCOL = "2025-06-18";
export const REQUIRED_TOOLS = [
  "t3_thread_launch",
  "t3_thread_send",
  "t3_thread_read",
  "t3_thread_wait",
  "t3_thread_interrupt",
  "t3_thread_organize",
  "t3_thread_list",
  "t3_project_list",
  "t3_project_create",
  "orchestrator_capabilities",
];
// T3 0.1.3 merged two tool families. Each capability below is met by one
// complete family, tried in `prefer` order, so one helper drives T3 before
// and after the merge. The gate records the family it found on the session,
// and the call sites go through threadConfiguration and pendingRequest.
//   configuration: earlier T3 reads a thread's binding with
//     t3_thread_configuration and also lists t3_thread_configure, which there
//     requires modelSelection and only writes, so the dedicated read wins
//     whenever T3 lists it. From 0.1.3, t3_thread_configure called with only
//     threadId is the read (this helper never sends modelSelection).
//   pendingRequests: t3_pending_request with action list|read|respond;
//     earlier T3 served t3_pending_request_list|read|respond.
export const TOOL_FAMILIES = {
  configuration: { prefer: ["earlier", "current"], current: ["t3_thread_configure"], earlier: ["t3_thread_configuration"] },
  pendingRequests: {
    prefer: ["current", "earlier"],
    current: ["t3_pending_request"],
    earlier: ["t3_pending_request_list", "t3_pending_request_read", "t3_pending_request_respond"],
  },
};
const ENVIRONMENT_TOOL = "t3_environment_read";
const EXPIRY_WARN_DAYS = 5;
const DAY_MS = 86_400_000;
const REQUEST_TIMEOUT_MS = 30_000;
const ARCHIVE_TIMEOUT_MS = /^[1-9][0-9]*$/.test(process.env.FM_T3CODE_ARCHIVE_TIMEOUT_MS ?? "") ? Number(process.env.FM_T3CODE_ARCHIVE_TIMEOUT_MS) : 15_000;
const SESSION_CLOSE_TIMEOUT_MS = 2_000;
// Node's fetch drops a reply that takes longer than 300 s, so one
// t3_thread_wait, plus its 15 s grace, stays under that and a longer wait
// re-arms until its own deadline.
const WAIT_SLICE_MS = 240_000;
// JSON-RPC errors that refuse the request itself: parse error, invalid
// request, unknown method, invalid params.
const REFUSED_REQUEST_CODES = new Set([-32700, -32600, -32601, -32602]);
// T3's catch-all tool failure, which can follow a committed mutation, so it
// never proves a send or launch was not applied. A tool error without a code
// of its own is read as this one.
const UNPROVEN_TOOL_ERROR = "orchestration_error";
const CAPTURE_LINES_MAX = 500;
// The newest runs `state` reports, enough for a supervisor to find the run it
// recorded at a worker's `done` once a steer has started a newer one.
const STATE_RUN_LIMIT = 5;
// Activity items read back for the error message of a failed latest run.
const STATE_ERROR_TAIL_ITEMS = 20;
// The activity item T3 keeps for each permission approval, and the status it
// holds until the approval is answered (docs/verification/runtime-backends.md).
const APPROVAL_ITEM = "approval_request";
const APPROVAL_WAITING = "waiting";
// T3 derives that item's id from its runtime request id.
const APPROVAL_ITEM_ID_PREFIX = "turn-item:runtime-request:";
// The decisions approve sends; T3's approval respond takes exactly these.
const APPROVAL_DECISIONS = ["allow", "deny"];
// The orchestrator_capabilities feature that lets the pending-request tools
// list, read, and answer permission approvals.
const APPROVAL_FEATURE = "approvalResponses";
// The pairing code must cover every scope T3 grants a full-access mcp-client:
// T3 0.1.0 adds settings:write and source-control:write to the read and
// operate scopes of the 0.0.46 nightlies, and refuses a code that lacks one.
const SCOPES = ["orchestration:read", "orchestration:operate", "settings:write", "source-control:write"];
const ACCESS_CEILINGS = ["full-access"];
const TERMINAL_RUN = new Set(["completed", "failed", "cancelled", "interrupted", "rolled_back"]);
const ACTIVE_STATUSES = ["preparing", "queued", "starting", "running", "waiting"];
const READ_LIMIT_MAX = 100;
// The one harness adapter table: each Firstmate harness T3 can run, the T3
// driver it runs on, the model option that carries Firstmate's effort (null:
// the single option the model's catalog offers among EFFORT_OPTION_IDS), and
// either the provider instance it uses or, for the ACP registry driver, the
// registry agent its instance must report, whatever T3 named that instance
// (harnessInstance). config/t3code-instances names another instance. Cursor
// runs as the registry's `cursor` agent (`cursor-agent acp`), one process per
// thread, because T3's own cursor driver hosts Cursor's SDK inside the T3
// server, which gives a thread no environment of its own. Every other harness
// is refused.
export const HARNESSES = {
  claude: { driverKind: "claudeAgent", instanceId: "claudeAgent", effortOption: "effort" },
  codex: { driverKind: "codex", instanceId: "codex", effortOption: "reasoningEffort" },
  grok: { driverKind: "grok", instanceId: "grok", effortOption: "reasoningEffort" },
  pi: { driverKind: "pi", instanceId: "pi", effortOption: "thinking" },
  muse: { driverKind: "muse", instanceId: "muse", effortOption: "reasoningEffort" },
  opencode: { driverKind: "opencode", instanceId: "opencode", effortOption: "variant" },
  agy: { driverKind: "antigravity", instanceId: "antigravity", effortOption: null },
  cursor: { driverKind: "acpRegistry", effortOption: null, agentId: "cursor" },
  gemini: { driverKind: "acpRegistry", effortOption: null, agentId: "gemini" },
  kimi: { driverKind: "acpRegistry", effortOption: null, agentId: "kimi" },
  devin: { driverKind: "acpRegistry", effortOption: null, agentId: "devin" },
};
// Firstmate's effort words. Each is sent as the catalog value of the same
// name, and a word the model's catalog does not list is refused rather than
// mapped onto a neighbouring level.
const EFFORT_WORDS = ["low", "medium", "high", "xhigh", "max", "ultra"];
// The option ids a catalog names its reasoning level by, for a driver whose
// option is dynamic.
const EFFORT_OPTION_IDS = ["reasoningEffort", "effort", "thought_level", "thinking", "reasoning", "variant"];
// A name a thread environment may set; T3 checks names and caps sizes again.
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const REPEATABLE = new Set(["option", "thread", "escalated"]);
// Every MCP session this invocation opened, ended when the verb returns.
const SESSIONS = new Set();

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

class Refusal extends Error {
  constructor(code, message, exit = 4, extra = {}) {
    super(message);
    this.code = code;
    this.exit = exit;
    this.extra = extra;
  }
}

function usage(message) {
  throw new Refusal("usage", message ?? "invalid use; see the header of bin/fm-t3-mcp.mjs", 2);
}

// Every flag takes one value; a repeatable flag also collects every value in
// flags.all[key], while flags[key] keeps the last.
function parseFlags(argv) {
  const flags = { all: {} };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) usage(`unexpected argument '${arg}'`);
    const key = arg.slice(2);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) usage(`--${key} needs a value`);
    i++;
    if (REPEATABLE.has(key)) (flags.all[key] ??= []).push(value);
    flags[key] = value;
  }
  return flags;
}

function need(flags, key) {
  const v = flags[key];
  if (v === undefined || v === "") usage(`--${key} is required`);
  return v;
}

function positiveInt(flags, key, fallback, max) {
  if (flags[key] === undefined) return fallback;
  const n = Number(flags[key]);
  if (!Number.isInteger(n) || n <= 0 || (max && n > max)) usage(`--${key} must be a positive integer${max ? ` up to ${max}` : ""}`);
  return n;
}

export function tokenFile(flags, env = process.env) {
  if (flags["token-file"]) return flags["token-file"];
  if (env.FM_T3CODE_TOKEN_FILE) return env.FM_T3CODE_TOKEN_FILE;
  const home = env.FM_HOME || env.FM_ROOT_OVERRIDE || root;
  const config = env.FM_CONFIG_OVERRIDE || path.join(home, "config");
  return path.join(config, "t3code-token");
}

// The sign-in origin: --url, else $FM_T3CODE_ORIGIN, else the origin the
// local T3 server writes to its runtime file.
export function loginOrigin(flags, env = process.env) {
  if (flags.url) return normalizeOrigin(flags.url);
  if (env.FM_T3CODE_ORIGIN) return normalizeOrigin(env.FM_T3CODE_ORIGIN);
  const runtime = path.join(env.HOME || os.homedir(), ".t3", "userdata", "server-runtime.json");
  let origin = "";
  try {
    origin = JSON.parse(readFileSync(runtime, "utf8")).origin || "";
  } catch {
    origin = "";
  }
  if (!origin) usage(`no T3 origin: pass --url, set FM_T3CODE_ORIGIN, or start T3 Code so it writes ${runtime}`);
  return normalizeOrigin(origin);
}

function normalizeOrigin(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    usage(`--url '${raw}' is not a URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") usage("--url must be http or https");
  return url.origin;
}

// --- credential ---------------------------------------------------------

export function readCredential(file, now = Date.now()) {
  if (!existsSync(file)) {
    throw new Refusal("no_credential", `no T3 credential at ${file}; the captain signs in with: bin/fm-t3-mcp.mjs login --access full-access`);
  }
  const mode = statSync(file).mode & 0o777;
  if (mode & 0o077) {
    throw new Refusal("credential_permissions", `T3 credential ${file} is readable by others (mode ${mode.toString(8)}); chmod 600 it or sign in again`);
  }
  let cred;
  try {
    cred = JSON.parse(readFileSync(file, "utf8"));
  } catch (err) {
    throw new Refusal("credential_unreadable", `T3 credential ${file} is not valid JSON: ${err.message}`);
  }
  for (const key of ["origin", "access_token", "expires_at", "environment_id"]) {
    if (!cred[key]) throw new Refusal("credential_unreadable", `T3 credential ${file} lacks ${key}; sign in again`);
  }
  if (cred.expires_at <= now) {
    throw new Refusal("credential_expired", `T3 credential ${file} expired at ${new Date(cred.expires_at).toISOString()}; T3 issues no refresh token, so the captain signs in again`);
  }
  const daysLeft = (cred.expires_at - now) / DAY_MS;
  if (daysLeft <= EXPIRY_WARN_DAYS) {
    cred.warning = `T3 credential expires in ${daysLeft.toFixed(1)} days (${new Date(cred.expires_at).toISOString()}); the captain signs in again before then`;
    process.stderr.write(`warning: ${cred.warning}\n`);
  }
  return cred;
}

function writeCredential(file, record) {
  mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(record)}\n`, { mode: 0o600, flag: "wx" });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
}

// --- MCP streamable HTTP ------------------------------------------------

async function httpJson(url, init) {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(init.timeoutMs ?? REQUEST_TIMEOUT_MS) });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return { res, body, text };
}

async function postJson(url, payload) {
  const { res, body } = await httpJson(url, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok || body === null) {
    const detail = body?.error_description || body?.error || body?.message || `HTTP ${res.status}`;
    throw new Refusal("oauth_failed", `${new URL(url).pathname} failed: ${detail}`, 3);
  }
  return body;
}

export class McpSession {
  constructor(origin, token, timeoutMs = REQUEST_TIMEOUT_MS) {
    this.origin = origin;
    this.token = token;
    this.sid = null;
    this.nextId = 1;
    this.timeoutMs = timeoutMs;
    this.server = null;
    SESSIONS.add(this);
  }

  async rpc(method, params, { notify = false, timeoutMs, signal } = {}) {
    const body = notify ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", id: this.nextId++, method, params };
    const headers = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      authorization: `Bearer ${this.token}`,
      "mcp-protocol-version": PROTOCOL,
    };
    if (this.sid) headers["mcp-session-id"] = this.sid;
    let res;
    try {
      res = await fetch(`${this.origin}/mcp`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs ?? this.timeoutMs)]) : AbortSignal.timeout(timeoutMs ?? this.timeoutMs),
      });
    } catch (err) {
      throw new Refusal("transport", `T3 at ${this.origin} is unreachable: ${err.cause?.code || err.name}: ${err.message}`, 1);
    }
    this.sid = res.headers.get("mcp-session-id") ?? this.sid;
    const text = await res.text();
    if (res.status === 401 || res.status === 403) {
      throw new Refusal("unauthorized", `T3 at ${this.origin} rejected the credential (HTTP ${res.status}); it was revoked or belongs to another server, so the captain signs in again`, 4);
    }
    if (!res.ok && res.status !== 202) {
      throw new Refusal("transport", `T3 /mcp answered HTTP ${res.status}`, 1);
    }
    if (notify) return null;
    if (res.status === 202 || text.length === 0) throw new Refusal("transport", `T3 /mcp returned no reply to ${method}`, 1);
    let msg = null;
    if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) {
      for (const line of text.split("\n")) {
        if (!line.startsWith("data:")) continue;
        let m;
        try {
          m = JSON.parse(line.slice(5));
        } catch {
          continue;
        }
        if (m.id === body.id) msg = m;
      }
    } else {
      try {
        msg = JSON.parse(text);
      } catch {
        throw new Refusal("transport", "T3 /mcp returned a body that is not JSON", 1);
      }
      if (msg?.id !== body.id) msg = null;
    }
    if (!msg || !("result" in msg || msg.error)) throw new Refusal("transport", `T3 /mcp returned no reply to ${method}`, 1);
    if (msg.error) {
      throw new Refusal(String(msg.error.code ?? "rpc_error"), `T3 ${method} failed: ${msg.error.message ?? "unknown error"}`, REFUSED_REQUEST_CODES.has(msg.error.code) ? 3 : 1);
    }
    return msg.result;
  }

  // Best effort: a session T3 opened is ended rather than left to its expiry.
  async close() {
    if (!this.sid) return;
    try {
      await fetch(`${this.origin}/mcp`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${this.token}`, "mcp-protocol-version": PROTOCOL, "mcp-session-id": this.sid },
        signal: AbortSignal.timeout(SESSION_CLOSE_TIMEOUT_MS),
      });
    } catch {
      // The server ends an abandoned session on its own.
    }
  }

  async open() {
    this.server = await this.rpc("initialize", {
      protocolVersion: PROTOCOL,
      capabilities: {},
      clientInfo: { name: "firstmate", version: "1" },
    });
    await this.rpc("notifications/initialized", undefined, { notify: true });
    return this.server;
  }

  // tools/call; a result flagged isError is a typed T3 failure (exit 3).
  async call(name, args, opts) {
    const result = await this.rpc("tools/call", { name, arguments: args ?? {} }, opts);
    const data = result?.structuredContent ?? parseContentJson(result?.content);
    if (result?.isError) {
      const err = toolError(data, result?.content);
      throw new Refusal(err.code, `T3 ${name} failed: ${err.message}`, 3, { tool: name });
    }
    return data;
  }
}

function parseContentJson(content) {
  if (!Array.isArray(content)) return null;
  for (const item of content) {
    if (item?.type !== "text") continue;
    try {
      return JSON.parse(item.text);
    } catch {
      return { text: item.text };
    }
  }
  return null;
}

function toolError(data, content) {
  const e = data?.error ?? data ?? {};
  const text = Array.isArray(content) ? content.filter((c) => c?.type === "text").map((c) => c.text).join(" ") : "";
  return {
    code: typeof e.code === "string" && e.code ? e.code : UNPROVEN_TOOL_ERROR,
    message: String(e.message ?? e.detail ?? (text || "unknown error")),
  };
}

// The capability gate: required tools present, environment id unchanged.
export async function gate(session, cred) {
  const server = await session.open();
  const listed = await session.rpc("tools/list", {});
  const names = new Set((listed?.tools ?? []).map((t) => t.name));
  const version = server?.serverInfo?.version ?? null;
  const missing = REQUIRED_TOOLS.filter((t) => !names.has(t));
  const families = {};
  for (const [capability, family] of Object.entries(TOOL_FAMILIES)) {
    const found = family.prefer.find((generation) => family[generation].every((t) => names.has(t)));
    if (found) families[capability] = found;
    else missing.push(`${family.current.join(", ")} (or ${family.earlier.join(", ")})`);
  }
  if (missing.length) {
    throw new Refusal(
      "capability_gate",
      `T3 ${version ?? "(unknown version)"} at ${session.origin} lacks ${missing.join(", ")}; backend=t3code needs a T3 with the Orchestrator V2 thread tools (docs/t3code-backend.md)`,
      4,
      { serverVersion: version, missing },
    );
  }
  if (!names.has(ENVIRONMENT_TOOL)) {
    throw new Refusal("capability_gate", `T3 ${version} lacks ${ENVIRONMENT_TOOL}, so its identity cannot be verified`, 4, { serverVersion: version });
  }
  const envRead = await session.call(ENVIRONMENT_TOOL, {});
  const environmentId = envRead?.environmentId ?? envRead?.environment?.environmentId ?? null;
  if (!environmentId) throw new Refusal("capability_gate", `${ENVIRONMENT_TOOL} returned no environmentId`, 4);
  if (cred && cred.environment_id !== environmentId) {
    throw new Refusal(
      "environment_mismatch",
      `T3 at ${session.origin} is environment ${environmentId}, not the ${cred.environment_id} this credential was issued by; refusing to drive a different server`,
      4,
      { environmentId, expected: cred.environment_id },
    );
  }
  session.toolFamilies = families;
  session.toolSchemas = new Map((listed?.tools ?? []).map((t) => [t.name, t.inputSchema ?? {}]));
  return { serverVersion: version, environmentId, serverVersionReported: envRead?.serverVersion ?? null, tools: [...names].sort(), toolFamilies: families };
}

// Whether the server's tools/list schema for <tool> declares <property>: T3
// drops an argument a peer's schema lacks, so an optional field that matters
// is sent only where it is declared.
function toolOffers(session, tool, property) {
  const props = session.toolSchemas?.get(tool)?.properties;
  return Boolean(props && typeof props === "object" && Object.hasOwn(props, property));
}

// A thread's recorded binding (modelSelection, runtimeMode, and on a server
// with per-thread facts environment, instructions, effectiveRuntimeMode), read
// through the configuration family the gate found.
function threadConfiguration(session, threadId) {
  if (session.toolFamilies?.configuration === "earlier") return session.call("t3_thread_configuration", { threadId });
  return session.call("t3_thread_configure", { threadId });
}

// One pending-request action (list, read, or respond), through the family
// the gate found.
function pendingRequest(session, action, args) {
  if (session.toolFamilies?.pendingRequests === "earlier") return session.call(`t3_pending_request_${action}`, args);
  return session.call("t3_pending_request", { action, ...args });
}

// Whether this server answers permission approvals through the
// pending-request tools, read once per session.
async function approvalResponses(session) {
  if (session.approvalResponses === undefined) {
    const caps = await session.call("orchestrator_capabilities", {});
    session.approvalResponses = caps?.features?.[APPROVAL_FEATURE] === true;
  }
  return session.approvalResponses;
}

async function verifiedSession(flags) {
  const cred = readCredential(tokenFile(flags));
  const session = new McpSession(cred.origin, cred.access_token);
  const g = await gate(session, cred);
  return { cred, session, gate: g };
}

function isNotFound(err) {
  return err instanceof Refusal && err.exit === 3 && /not[_ ]found/i.test(err.code);
}

// T3 product telemetry is on unless the server process runs with
// T3CODE_TELEMETRY_ENABLED false (apps/server's AnalyticsService config).
// Only a loopback server's own process environment can show that, read from
// the listening process on this machine; anything else reads `unknown`.
export function telemetryState(listener) {
  if (listener === null) return "unknown";
  const m = listener.env.match(/(?:^|\s|\0)T3CODE_TELEMETRY_ENABLED=([^\s\0]*)/);
  if (!m) return "on";
  return /^(false|0|no|off)$/i.test(m[1]) ? "off" : "on";
}

// The one process listening on a loopback origin's port on this machine: its
// pid, its kernel start time, and its environment. `serverStart` joins the
// first two, so a restarted server always reads a new value
// (bin/fm-t3-restart.sh compares it); a remote origin, no single listener, or
// an unreadable process reads null.
export function loopbackListener(origin, probe = probeListener) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    return null;
  }
  if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) return null;
  return probe(url.port || (url.protocol === "https:" ? "443" : "80"));
}

function probeListener(port) {
  const run = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  try {
    const pids = run("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).split("\n").filter(Boolean);
    if (pids.length !== 1) return null;
    const pid = pids[0];
    const startedAt = run("ps", ["-o", "lstart=", "-p", pid]).trim().replace(/\s+/g, " ");
    if (!startedAt) return null;
    const env = process.platform === "linux" ? readFileSync(`/proc/${pid}/environ`, "utf8") : run("ps", ["eww", "-o", "command=", "-p", pid]);
    return { pid: Number(pid), startedAt, env };
  } catch {
    return null;
  }
}

// --- verbs ----------------------------------------------------------------

async function login(flags) {
  const access = need(flags, "access");
  if (!ACCESS_CEILINGS.includes(access)) {
    usage(`--access ${access} is not supported: Firstmate workers write their status outside the worktree, which only the full-access ceiling allows (docs/t3code-backend.md)`);
  }
  const origin = loginOrigin(flags);
  const file = tokenFile(flags);
  const t3 = flags.t3 || "t3";
  const label = flags.label || "firstmate";
  const redirect = "http://127.0.0.1:1/fm-t3-callback"; // never contacted: the decision API returns the redirect
  const reg = await postJson(`${origin}/oauth/mcp/register`, { client_name: label, redirect_uris: [redirect] });
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = randomBytes(12).toString("base64url");
  const resource = `${origin}/mcp`;
  const authorization = {
    response_type: "code",
    client_id: reg.client_id,
    redirect_uri: redirect,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    resource,
  };
  const pairingArgs = ["auth", "pairing", "create"];
  if (flags["base-dir"]) pairingArgs.push("--base-dir", flags["base-dir"]);
  for (const scope of SCOPES) pairingArgs.push("--scope", scope);
  pairingArgs.push("--ttl", "2m", "--label", `${label}-mcp-approval`, "--json");
  let pairing;
  try {
    pairing = JSON.parse(execFileSync(t3, pairingArgs, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
  } catch (err) {
    throw new Refusal("pairing_failed", `could not mint a pairing code with '${t3} auth pairing create': ${err.status !== undefined ? `exit ${err.status}` : err.message}`, 1);
  }
  if (!pairing?.credential) throw new Refusal("pairing_failed", "t3 auth pairing create returned no credential", 1);
  const decision = await postJson(`${origin}/oauth/mcp/decision`, {
    authorization,
    decision: { _tag: "pairing-code", access, code: pairing.credential },
  });
  const back = new URL(decision.redirectTo);
  if (back.searchParams.get("state") !== state) throw new Refusal("oauth_failed", "OAuth state mismatch on the decision redirect", 3);
  const code = back.searchParams.get("code");
  if (!code) throw new Refusal("oauth_failed", `the decision returned no code (${back.searchParams.get("error") ?? "no error given"})`, 3);
  const { res, body: tok } = await httpJson(`${origin}/oauth/mcp/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: redirect, client_id: reg.client_id, code_verifier: verifier, resource }),
  });
  if (!res.ok || !tok?.access_token) throw new Refusal("oauth_failed", `token exchange failed: ${tok?.error_description ?? tok?.error ?? `HTTP ${res.status}`}`, 3);
  const issuedAt = Date.now();
  const session = new McpSession(origin, tok.access_token);
  const g = await gate(session, null);
  const record = {
    version: 1,
    origin,
    access_token: tok.access_token,
    issued_at: issuedAt,
    expires_at: issuedAt + Number(tok.expires_in) * 1000,
    scope: tok.scope,
    access,
    label,
    client_id: reg.client_id,
    environment_id: g.environmentId,
    server_version: g.serverVersion,
  };
  writeCredential(file, record);
  return {
    ok: true,
    tokenFile: file,
    origin,
    access,
    scope: tok.scope,
    expiresAt: new Date(record.expires_at).toISOString(),
    environmentId: g.environmentId,
    serverVersion: g.serverVersion,
  };
}

async function status(flags) {
  const { cred, gate: g } = await verifiedSession(flags);
  const listener = loopbackListener(cred.origin);
  const telemetry = telemetryState(listener);
  if (telemetry !== "off") {
    process.stderr.write(`warning: T3 telemetry at ${cred.origin} is ${telemetry === "on" ? "on" : "not confirmed off"}; run the server that hosts Firstmate workers with T3CODE_TELEMETRY_ENABLED=false (docs/t3code-backend.md)\n`);
  }
  return {
    ok: true,
    origin: cred.origin,
    access: cred.access,
    expiresAt: new Date(cred.expires_at).toISOString(),
    daysLeft: Number(((cred.expires_at - Date.now()) / DAY_MS).toFixed(1)),
    environmentId: g.environmentId,
    serverVersion: g.serverVersion,
    recordedServerVersion: cred.server_version ?? null,
    telemetry,
    serverStart: listener ? `${listener.pid}@${listener.startedAt}` : null,
    ...(cred.warning ? { credentialWarning: cred.warning } : {}),
  };
}

// state: whether the thread exists, and its archive and run state. A thread
// the verified server does not have reads exists:false rather than failing.
async function state(flags) {
  const threadId = need(flags, "thread");
  const { session } = await verifiedSession(flags);
  let out;
  try {
    out = await session.call("t3_thread_read", { threadId, limit: 1, runLimit: STATE_RUN_LIMIT });
  } catch (err) {
    if (isNotFound(err)) return { ok: true, threadId, exists: false };
    throw err;
  }
  const t = threadOf(out);
  const recent = out?.recentRuns ?? [];
  const run = recent[0] ?? {};
  const runs = recent.map((r) => ({ runId: r?.runId ?? null, status: r?.status ?? null }));
  let latestRunError = null;
  if (run.status === "failed" && run.runId) {
    // The run record carries no failure detail on `/mcp`; the `error` activity
    // item T3 writes for the failure carries its message (its class and code
    // stay server-side). Best effort: a tail that cannot be read leaves null.
    try {
      const { items } = await readTail(session, threadId, t.itemCount ?? 0, STATE_ERROR_TAIL_ITEMS);
      const errorItem = [...items].reverse().find((item) => item?.type === "error" && (item.runId === undefined || item.runId === null || item.runId === run.runId));
      if (errorItem && typeof errorItem.text === "string" && errorItem.text) latestRunError = errorItem.text;
    } catch {
      latestRunError = null;
    }
  }
  return {
    ok: true,
    threadId,
    exists: true,
    archived: t.archived === true || Boolean(t.archivedAt),
    status: t.status ?? null,
    activeRunId: t.activeRunId ?? null,
    pendingRequestCount: t.pendingRequestCount ?? 0,
    worktreePath: t.worktreePath ?? null,
    turnAt: run.completedAt ?? run.startedAt ?? run.requestedAt ?? null,
    latestRunId: run.runId ?? null,
    latestRunStatus: run.status ?? null,
    runs,
    latestRunError,
  };
}

function realOrRaw(p) {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

// Every live project, across t3_project_list pages.
async function liveProjects(session) {
  const projects = [];
  let cursor;
  for (let page = 0; page < 100; page++) {
    const listed = await session.call("t3_project_list", { limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
    projects.push(...(listed?.projects ?? []));
    if (listed?.nextCursor === null || listed?.nextCursor === undefined) break;
    cursor = listed.nextCursor;
  }
  return projects.filter((p) => !p.deletedAt);
}

async function projectForRoot(session, rootPath) {
  const want = realOrRaw(rootPath);
  return (await liveProjects(session)).find((p) => realOrRaw(p.workspaceRoot ?? "") === want) ?? null;
}

async function projectEnsure(flags) {
  const rootPath = need(flags, "root");
  if (!path.isAbsolute(rootPath)) usage("--root must be an absolute path");
  const { session } = await verifiedSession(flags);
  const found = await projectForRoot(session, rootPath);
  if (found) return { ok: true, projectId: found.id, created: false };
  let made;
  try {
    made = await session.call("t3_project_create", { title: flags.title || path.basename(rootPath), workspaceRoot: realOrRaw(rootPath) });
  } catch (err) {
    const registered = await projectForRoot(session, rootPath);
    if (registered) return { ok: true, projectId: registered.id, created: false };
    throw err;
  }
  const projectId = made?.id ?? made?.projectId ?? made?.project?.id;
  if (!projectId) throw new Refusal("project_unconfirmed", "t3_project_create returned no project id", 1);
  return { ok: true, projectId, created: true };
}

async function projectRead(flags) {
  const projectId = need(flags, "project");
  const { session } = await verifiedSession(flags);
  const project = (await liveProjects(session)).find((p) => p.id === projectId);
  if (!project) throw new Refusal("project_not_found", `T3 lists no live project ${projectId}`, 3);
  return { ok: true, project };
}

function readMessage(flags) {
  const file = need(flags, "message-file");
  const text = readFileSync(file, "utf8");
  if (!text.trim()) usage(`--message-file ${file} is empty`);
  return text;
}

function modelSelection(flags) {
  let sel;
  try {
    sel = JSON.parse(need(flags, "model-selection"));
  } catch {
    usage("--model-selection must be JSON");
  }
  if (!sel || typeof sel.instanceId !== "string" || !sel.instanceId || typeof sel.model !== "string" || !sel.model) {
    usage("--model-selection needs a string instanceId and model");
  }
  return sel;
}

// An option selection is valid when the model's catalog describes its id and
// lists its value. Current catalogs list the allowed values as a plain
// `values` array (a boolean option lists `[false, true]`); older catalogs
// list them as `options: [{id}]` and type a boolean option as "boolean".
function optionProblem(model, option) {
  const descriptor = (model.options ?? []).find((d) => d.id === option.id);
  if (!descriptor) return `option '${option.id}' is not one model ${model.id} offers`;
  if (descriptor.type === "boolean") return typeof option.value === "boolean" ? null : `option '${option.id}' takes true or false`;
  const values = Array.isArray(descriptor.values) ? descriptor.values : (descriptor.options ?? []).map((c) => c.id);
  return values.includes(option.value) ? null : `option '${option.id}' value '${option.value}' is not one of ${values.join(", ")} for model ${model.id}`;
}

// The adapter-table row for <harness>, refusing every harness T3 cannot run.
function harnessRow(harness) {
  const row = Object.hasOwn(HARNESSES, harness) ? HARNESSES[harness] : null;
  if (!row) throw new Refusal("harness_unsupported", `backend=t3code runs only the ${Object.keys(HARNESSES).join(", ")} harnesses, not '${harness}'`);
  return row;
}

// harness: the adapter-table row, read locally with no server call.
async function harnessVerb(flags) {
  const harness = need(flags, "harness");
  return { ok: true, harness, ...harnessRow(harness) };
}

// The option that carries Firstmate's effort on <model>: the row's fixed id,
// or the single EFFORT_OPTION_IDS option the catalog lists for that model.
function effortOptionId(row, model, harness) {
  if (row.effortOption) return row.effortOption;
  const offered = (model.options ?? []).map((d) => d.id).filter((id) => EFFORT_OPTION_IDS.includes(id));
  if (offered.length === 1) return offered[0];
  throw new Refusal(
    "effort_unsupported",
    offered.length
      ? `model ${model.id} offers several effort options (${offered.join(", ")}) for harness '${harness}', so Firstmate cannot tell which one carries effort; pass --effort default`
      : `model ${model.id} offers no effort option for harness '${harness}'; pass --effort default`,
  );
}

// The provider instance <harness> runs on: the one --instance names (from
// config/t3code-instances); else, for an ACP registry row, the one instance of
// any name that runs its registry agent, since T3 names a new registry
// instance after the agent's label (acpRegistry_gemini_cli), refusing none or
// several rather than guessing; else the row's own instance.
function harnessInstance(providers, row, harness, named) {
  if (named || !row.agentId) {
    const instanceId = named || row.instanceId;
    const provider = providers.find((p) => p.providerInstanceId === instanceId);
    if (!provider) {
      throw new Refusal(
        "instance_unknown",
        `T3 has no provider instance '${instanceId}' (${named ? "config/t3code-instances maps the" : "the default instance of the"} ${harness} harness)`,
      );
    }
    return provider;
  }
  const matches = providers.filter((p) => p.driverKind === row.driverKind && p.agentId === row.agentId);
  if (!matches.length) {
    throw new Refusal(
      "instance_unknown",
      `T3 has no ACP registry instance running the '${row.agentId}' agent the ${harness} harness needs; add one in T3 Code under Settings, Providers, ACP Registry, or name an instance in config/t3code-instances`,
    );
  }
  if (matches.length > 1) {
    throw new Refusal(
      "instance_ambiguous",
      `T3 has several ACP registry instances running the '${row.agentId}' agent (${matches.map((p) => p.providerInstanceId).join(", ")}); name the one the ${harness} harness uses in config/t3code-instances`,
    );
  }
  return matches[0];
}

// The catalog entry for <slug> on <provider>. T3 lists a short set of models
// per instance and counts the rest in omittedModels; its search argument
// matches every model, so an exact slug outside the short set is looked up
// there before it is refused, where the tool declares search.
async function catalogModel(session, provider, slug) {
  const listed = (provider.models ?? []).find((m) => m.id === slug);
  if (listed || !(provider.omittedModels > 0) || !toolOffers(session, "orchestrator_capabilities", "search")) return listed;
  const found = await session.call("orchestrator_capabilities", { search: slug });
  const same = (found?.providers ?? []).find((p) => p.providerInstanceId === provider.providerInstanceId);
  return (same?.models ?? []).find((m) => m.id === slug);
}

async function resolveSelection(flags) {
  const harness = need(flags, "harness");
  const row = harnessRow(harness);
  const wantModel = need(flags, "model");
  const effort = need(flags, "effort");
  if (effort !== "default" && !EFFORT_WORDS.includes(effort)) usage(`--effort must be default or one of ${EFFORT_WORDS.join(", ")}`);
  const { session } = await verifiedSession(flags);
  const caps = await session.call("orchestrator_capabilities", {});
  const provider = harnessInstance(caps?.providers ?? [], row, harness, flags.instance);
  const instanceId = provider.providerInstanceId;
  if (provider.driverKind !== row.driverKind) {
    throw new Refusal("driver_mismatch", `T3 instance '${instanceId}' runs the ${provider.driverKind} driver, not ${row.driverKind}, so it cannot host the ${harness} harness; fix config/t3code-instances`);
  }
  if (row.agentId && provider.agentId !== row.agentId) {
    throw new Refusal(
      "agent_mismatch",
      `T3 instance '${instanceId}' ${provider.agentId ? `runs the ACP registry agent '${provider.agentId}'` : "does not report which ACP registry agent it runs"}, not '${row.agentId}', so it cannot host the ${harness} harness`,
    );
  }
  if ((provider.constraints ?? []).length) throw new Refusal("instance_unavailable", `T3 instance '${instanceId}' cannot run threads: ${provider.constraints.join(" ")}`);
  // T3 records full-access on the thread but runs a driver that does not
  // declare it at a lower mode, where a worker parks on an approval for every
  // guarded action. An instance that declares no modes supports every mode.
  if (Array.isArray(provider.runtimeModes) && !provider.runtimeModes.includes("full-access")) {
    throw new Refusal(
      "full_access_unsupported",
      `T3 instance '${instanceId}' runs only ${provider.runtimeModes.join(", ") || "no runtime modes"}, not full-access, so a ${harness} worker there would park on an approval for every guarded action`,
    );
  }
  let base = { instanceId, model: wantModel };
  if (wantModel === "default") {
    let project;
    if (flags.project) {
      project = (await liveProjects(session)).find((p) => p.id === flags.project);
      if (!project) throw new Refusal("project_not_found", `T3 lists no live project ${flags.project}`);
    } else {
      const rootPath = flags.root;
      if (!rootPath || !path.isAbsolute(rootPath)) usage("--model default needs --project <id> or an absolute --root");
      project = await projectForRoot(session, rootPath);
      if (!project) throw new Refusal("project_not_found", `T3 has no project rooted at ${rootPath} yet, so it has no default model; pass --model with a slug from the T3 model catalog`);
    }
    const projectId = project.id;
    const def = project.defaultModelSelection;
    if (!def) throw new Refusal("no_default_model", `T3 project ${projectId} has no default model; pass --model with a slug from the T3 model catalog`);
    if (def.instanceId !== instanceId) {
      throw new Refusal("default_instance_mismatch", `T3 project ${projectId} defaults to instance ${def.instanceId}, but the ${harness} harness runs on instance ${instanceId}; pass --model explicitly`);
    }
    base = { instanceId, model: def.model, ...(def.options !== undefined ? { options: def.options } : {}) };
  }
  const model = await catalogModel(session, provider, base.model);
  if (!model) throw new Refusal("model_unknown", `T3 instance '${instanceId}' does not list model '${base.model}'; pass --model with a slug from its catalog`);
  let options = base.options;
  if (effort !== "default") {
    const chosen = { id: effortOptionId(row, model, harness), value: effort };
    const problem = optionProblem(model, chosen);
    if (problem) throw new Refusal("effort_unsupported", `backend=t3code cannot pass effort '${effort}' to harness '${harness}': ${problem}`);
    const kept = options ?? [];
    options = kept.some((o) => o.id === chosen.id) ? kept.map((o) => (o.id === chosen.id ? chosen : o)) : [...kept, chosen];
  }
  for (const option of options ?? []) {
    const problem = optionProblem(model, option);
    if (problem) throw new Refusal("option_unsupported", `the selection for harness '${harness}' is not valid in T3's catalog: ${problem}`);
  }
  return {
    ok: true,
    driverKind: provider.driverKind,
    selection: { instanceId, model: base.model, ...(options !== undefined ? { options } : {}) },
    threadEnvironment: provider.threadEnvironment === true,
    threadInstructions: provider.threadInstructions === true,
  };
}

// --environment-file: a JSON object of environment names to string values.
function launchEnvironment(flags) {
  const file = flags["environment-file"];
  if (file === undefined) return null;
  let env;
  try {
    env = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    usage(`--environment-file ${file} must hold JSON`);
  }
  if (!env || typeof env !== "object" || Array.isArray(env)) usage("--environment-file must hold a JSON object of names to strings");
  for (const [name, value] of Object.entries(env)) {
    if (!ENV_NAME.test(name) || typeof value !== "string") usage(`--environment-file entry '${name}' must be a shell variable name with a string value`);
  }
  return env;
}

function launchInstructions(flags) {
  const file = flags["instructions-file"];
  if (file === undefined) return null;
  const text = readFileSync(file, "utf8");
  if (!text.trim()) usage(`--instructions-file ${file} is empty`);
  return text;
}

const sameEnvironment = (a, b) =>
  Boolean(b) && typeof b === "object" && !Array.isArray(b) && Object.keys(a).length === Object.keys(b).length && Object.entries(a).every(([k, v]) => b[k] === v);

// What a launch must read back: the workspace, full access (and the effective
// mode T3 runs the driver at, when it reports one), exactly the requested
// instance, model, and option values, the thread environment and
// instructions it was given, and the crew lineage under the parent it named.
function bindingProblems(t, config, selection, worktree, environment, instructions, parent) {
  const problems = [];
  if (parent !== null && (t.relationshipToParent !== "crew" || t.parentThreadId !== parent)) {
    problems.push(`lineage ${t.relationshipToParent ?? "none"} under ${t.parentThreadId ?? "no parent"}`);
  }
  if (worktree ? realOrRaw(t.worktreePath ?? "") !== realOrRaw(worktree) : (t.worktreePath ?? null) !== null) {
    problems.push(`worktreePath ${t.worktreePath ?? "none"}`);
  }
  if (t.runtimeMode !== "full-access" || config?.runtimeMode !== "full-access") problems.push(`runtimeMode ${config?.runtimeMode ?? t.runtimeMode ?? "none"}`);
  const effective = config?.effectiveRuntimeMode;
  if (effective !== undefined && effective !== null && effective !== "full-access") problems.push(`effectiveRuntimeMode ${effective}`);
  if (environment && !sameEnvironment(environment, config?.environment)) problems.push(`environment ${config?.environment === undefined ? "not bound" : "differs"}`);
  if (instructions !== null && config?.instructions !== instructions) problems.push(`instructions ${config?.instructions === undefined ? "not bound" : "differ"}`);
  const bound = config?.modelSelection ?? {};
  if (t.providerInstanceId !== selection.instanceId || bound.instanceId !== selection.instanceId) problems.push(`provider ${bound.instanceId ?? t.providerInstanceId ?? "none"}`);
  if (bound.model !== selection.model) problems.push(`model ${bound.model ?? "none"}`);
  for (const option of selection.options ?? []) {
    const got = (bound.options ?? []).find((o) => o.id === option.id);
    if (got?.value !== option.value) problems.push(`option ${option.id}=${got ? got.value : "none"}`);
  }
  return problems;
}

async function launch(flags) {
  const worktree = flags.worktree;
  if (worktree !== undefined && !path.isAbsolute(worktree)) usage("--worktree must be an absolute path");
  const selection = modelSelection(flags);
  const message = flags["message-file"] ? readMessage(flags) : null;
  const environment = launchEnvironment(flags);
  const instructions = launchInstructions(flags);
  if (flags.parent !== undefined && !flags.parent) usage("--parent needs a thread id");
  let session;
  let g;
  try {
    ({ session, gate: g } = await verifiedSession(flags));
  } catch (err) {
    if (err instanceof Refusal && err.exit !== 1) throw err;
    throw new Refusal(err instanceof Refusal ? err.code : "unexpected", `${err?.message ?? String(err)}; no thread was launched`, 8, err instanceof Refusal ? err.extra : {});
  }
  // A T3 without crew lineage drops an undeclared argument, so the parent
  // rides, and is proven, only where the launch schema declares it.
  const parent = flags.parent !== undefined && toolOffers(session, "t3_thread_launch", "parentThreadId") ? flags.parent : null;
  const workspaceStrategy = worktree
    ? { type: "existing_worktree", worktreePath: worktree, ...(flags.branch ? { branch: flags.branch } : {}) }
    : { type: "root", ...(flags.branch ? { branch: flags.branch } : {}) };
  const args = {
    projectId: need(flags, "project"),
    title: need(flags, "title"),
    modelSelection: selection,
    runtimeMode: "full-access",
    interactionMode: "default",
    workspaceStrategy,
    ...(environment ? { environment } : {}),
    ...(instructions !== null ? { instructions } : {}),
    ...(message ? { message } : {}),
    ...(parent !== null ? { parentThreadId: parent } : {}),
  };
  let out;
  try {
    out = await session.call("t3_thread_launch", args);
  } catch (err) {
    if (err instanceof Refusal && err.code === UNPROVEN_TOOL_ERROR) {
      throw new Refusal("launch_unconfirmed", `${err.message}, which can follow a created thread; inspect t3_thread_list before retrying`, 1);
    }
    throw err;
  }
  if (!out?.threadId) throw new Refusal("launch_unconfirmed", "t3_thread_launch returned no threadId; inspect t3_thread_list before retrying", 1);
  const archiveLaunched = () => archiveThread(session, out.threadId, ARCHIVE_TIMEOUT_MS).then((r) => r.archived === true, () => false);
  // Prove the binding T3 recorded before anyone relies on it.
  let t;
  let config;
  try {
    t = threadOf(await session.call("t3_thread_read", { threadId: out.threadId, limit: 1, runLimit: 1 }));
    config = await threadConfiguration(session, out.threadId);
  } catch (e) {
    const archived = await archiveLaunched();
    throw new Refusal(
      "binding_unconfirmed",
      `T3 launched thread ${out.threadId} but reading back its binding failed (${e.message}); ${archived ? "it then read back archived with no active run" : "its archive is unproven, so archive it in T3 Code"}`,
      1,
      { threadId: out.threadId },
    );
  }
  const problems = bindingProblems(t, config, selection, worktree, environment, instructions, parent);
  if (problems.length) {
    const archived = await archiveLaunched();
    throw new Refusal(
      "binding_mismatch",
      `T3 bound thread ${out.threadId} to ${problems.join(", ")}, not the requested ${worktree ? "worktree" : "project root"}, model selection${environment || instructions !== null ? ", thread environment and instructions" : ""}${parent !== null ? `, crew of ${parent}` : ""} at full access; ${archived ? "archived it" : "its archive is unproven, so archive it in T3 Code"}`,
      archived ? 4 : 1,
      { threadId: out.threadId },
    );
  }
  return {
    ok: true,
    threadId: out.threadId,
    projectId: out.projectId ?? args.projectId,
    instanceId: selection.instanceId,
    model: selection.model,
    runId: out.runId ?? null,
    status: t.status ?? null,
    parentThreadId: parent,
    environmentId: g.environmentId,
    origin: session.origin,
    serverVersion: g.serverVersion,
  };
}

async function send(flags) {
  const args = { threadId: need(flags, "thread"), message: readMessage(flags), mode: "auto", clientRequestId: need(flags, "client-request-id") };
  let session;
  try {
    ({ session } = await verifiedSession(flags));
  } catch (err) {
    // Exit 3 means T3 refused this send; a typed failure of the gate's own
    // reads is a failure before the request went out.
    if (err instanceof Refusal && err.exit === 3) throw new Refusal(err.code, err.message, 1, err.extra);
    throw err;
  }
  let out;
  try {
    out = await session.call("t3_thread_send", args);
  } catch (err) {
    // A specific typed T3 refusal (3) or a refused credential (4) proves the
    // message was not taken; anything else happened after the request went
    // out.
    if (err instanceof Refusal && (err.exit === 3 || err.exit === 4) && err.code !== UNPROVEN_TOOL_ERROR) throw err;
    throw new Refusal(
      "delivery_unconfirmed",
      `the outcome of t3_thread_send on thread ${args.threadId} is unproven (${err.message}); T3 may have committed it, so retry only with client request id ${args.clientRequestId}`,
      7,
      { threadId: args.threadId, clientRequestId: args.clientRequestId },
    );
  }
  return { ok: true, threadId: args.threadId, clientRequestId: args.clientRequestId, delivery: out?.delivery ?? null, status: out?.status ?? null, runId: out?.runId ?? null, messageId: out?.messageId ?? null };
}

async function read(flags) {
  const { session } = await verifiedSession(flags);
  const out = await session.call("t3_thread_read", { threadId: need(flags, "thread"), limit: positiveInt(flags, "limit", 1, READ_LIMIT_MAX), runLimit: 1 });
  return { ok: true, ...out };
}

function itemText(item) {
  const raw = item?.text ?? item?.summary ?? item?.title ?? item?.message ?? item?.detail ?? "";
  return String(typeof raw === "string" ? raw : JSON.stringify(raw)).replace(/\s+/g, " ").trim();
}

// One `[type/status] text` line per activity item, then the thread's own
// status line last, so the tightest bound still shows the run state.
export function renderCapture(out, lines) {
  const t = out?.thread ?? {};
  const items = out?.items ?? [];
  const body = items.map((it) => {
    const kind = it?.type ?? "item";
    const st = it?.status ? `/${it.status}` : "";
    return `[${kind}${st}] ${itemText(it)}`.slice(0, 600);
  });
  const archived = t.archived === true || Boolean(t.archivedAt);
  const tail = `t3code: status=${archived ? "archived" : (t.status ?? "none")} run=${t.activeRunId ?? "none"}`;
  return [...body, tail].slice(-lines).join("\n");
}

// The last <lines> items of the activity view, with the last page read.
// t3_thread_read pages forward from the oldest item, so the tail starts from
// the thread's itemCount and widens backwards if that undercounts the visible
// timeline (forked or handed-off threads).
async function readTail(session, threadId, itemCount, lines) {
  const read = (afterPosition) =>
    session.call("t3_thread_read", { threadId, view: "activity", limit: READ_LIMIT_MAX, maxCharsPerItem: 600, runLimit: 1, ...(afterPosition >= 0 ? { afterPosition } : {}) });
  let start = Math.max(0, itemCount - lines);
  for (;;) {
    let out = await read(start - 1);
    const items = [...(out?.items ?? [])];
    for (let page = 0; out?.hasMore && out.nextPosition !== null && page < 50; page++) {
      out = await read(out.nextPosition);
      items.push(...(out?.items ?? []));
    }
    if (items.length >= lines || start === 0) return { out, items: items.slice(-lines) };
    start = Math.max(0, start - lines);
  }
}

async function capture(flags) {
  const threadId = need(flags, "thread");
  const lines = Math.min(positiveInt(flags, "lines", 40), CAPTURE_LINES_MAX);
  const { session } = await verifiedSession(flags);
  const head = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
  const { out, items } = await readTail(session, threadId, head.itemCount ?? 0, lines);
  return { text: renderCapture({ ...out, items }, lines) };
}

// t3_thread_wait in slices of at most WAIT_SLICE_MS until the run is terminal
// or timeoutMs passes; runId selects the exact run, else T3 waits on the
// thread's latest run.
async function waitRun(session, threadId, runId, timeoutMs, signal) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const slice = Math.min(WAIT_SLICE_MS, Math.max(1, deadline - Date.now()));
    const out = await session.call("t3_thread_wait", { threadId, ...(runId ? { runId } : {}), timeoutMs: slice }, { timeoutMs: slice + 15_000, signal });
    if (out?.timedOut !== true || Date.now() >= deadline) return out;
  }
}

async function wait(flags) {
  const timeoutMs = positiveInt(flags, "timeout-ms", 600_000, 3_600_000);
  const { session } = await verifiedSession(flags);
  const out = await waitRun(session, need(flags, "thread"), flags.run, timeoutMs);
  return { ok: true, ...out };
}

// cancel: confirmed (the run T3 interrupted reached a terminal status),
// not-running (there was no active run), or unconfirmed (the wait timed out
// or answered for another run). T3 interrupts its latest active run and ends
// it asynchronously, while a run queued behind it may already be terminal or
// start meanwhile, so only that exact run's state counts.
async function interrupt(flags) {
  const threadId = need(flags, "thread");
  const timeoutMs = positiveInt(flags, "timeout-ms", 10_000, 600_000);
  const { session } = await verifiedSession(flags);
  return interruptThread(session, threadId, timeoutMs, false);
}

// One t3_thread_interrupt and the wait on exactly the run T3 named. With stop
// (only where the tool's schema declares it), T3 stops the thread as its Stop
// button does: it interrupts the running turn, holds queued messages, and
// stops every task the thread delegated.
async function interruptThread(session, threadId, timeoutMs, stop) {
  const requested = await session.call("t3_thread_interrupt", {
    threadId,
    ...(stop ? { stop: true } : {}),
    clientRequestId: `fm-interrupt-${Date.now()}-${randomBytes(4).toString("hex")}`,
  });
  const base = { ok: true, threadId, stop };
  if (requested?.status === "no_active_run") return { ...base, requested: requested.status, cancel: "not-running" };
  const runId = requested?.runId ?? null;
  Object.assign(base, { runId, requested: requested?.status ?? null });
  if (!runId) return { ...base, cancel: "unconfirmed" };
  if (TERMINAL_RUN.has(requested.status)) return { ...base, status: requested.status, timedOut: false, cancel: "confirmed" };
  const waited = await waitRun(session, threadId, runId, timeoutMs);
  const done = waited?.runId === runId && waited?.timedOut !== true && TERMINAL_RUN.has(waited?.status);
  return { ...base, waitedRunId: waited?.runId ?? null, status: waited?.status ?? null, timedOut: waited?.timedOut === true, cancel: done ? "confirmed" : "unconfirmed" };
}

// The ids of every delegated (subagent) thread below <threadId> whose status
// is active, at any depth. T3 lists active threads with their parent; a parent
// link through a thread that is not itself active is followed with a read.
// The listing covers every project where t3_thread_list declares allProjects,
// else the thread's own project, where T3 puts a delegated task by default.
async function activeDescendants(session, threadId, projectId) {
  const scope = toolOffers(session, "t3_thread_list", "allProjects") ? { allProjects: true } : { projectId };
  const parentOf = new Map();
  let cursor;
  for (let page = 0; page < 1000; page++) {
    const listed = await session.call("t3_thread_list", { ...scope, statuses: ACTIVE_STATUSES, includeSubagents: true, limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
    for (const item of listed?.threads ?? []) {
      if (item.relationshipToParent === "subagent") parentOf.set(item.threadId, item.parentThreadId ?? null);
    }
    if (listed?.nextCursor === null || listed?.nextCursor === undefined) break;
    cursor = listed.nextCursor;
  }
  const active = [...parentOf.keys()];
  const below = [];
  for (const id of active) {
    let parent = parentOf.get(id);
    for (let depth = 0; parent && parent !== threadId && depth < 64; depth++) {
      if (!parentOf.has(parent)) {
        let t = null;
        try {
          t = threadOf(await session.call("t3_thread_read", { threadId: parent, limit: 1, runLimit: 1 }));
        } catch (err) {
          if (!isNotFound(err)) throw err;
        }
        parentOf.set(parent, t?.relationshipToParent === "subagent" ? (t.parentThreadId ?? null) : null);
      }
      parent = parentOf.get(parent);
    }
    if (parent === threadId) below.push(id);
  }
  return below;
}

// close: the teardown kill. A thread the verified server lacks is closed; an
// archived thread with no active run and no active delegated thread below it
// is already the end state. Otherwise any active run, and every active
// delegated task, is stopped (t3_thread_interrupt stop where the server's
// schema offers it, else a plain interrupt of the thread's own run), and the
// thread is archived with archive's proof, which also requires no delegated
// thread below it to be active.
async function close(flags) {
  const threadId = need(flags, "thread");
  const timeoutMs = positiveInt(flags, "timeout-ms", ARCHIVE_TIMEOUT_MS, 600_000);
  const { session } = await verifiedSession(flags);
  let t;
  try {
    t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
  } catch (err) {
    if (isNotFound(err)) return { ok: true, threadId, closed: true, missing: true };
    throw err;
  }
  const archived = t.archived === true || Boolean(t.archivedAt);
  const activeRun = (t.activeRunId ?? null) !== null;
  const children = await activeDescendants(session, threadId, t.projectId);
  if (archived && !activeRun && !children.length) return { ok: true, threadId, closed: true, archived: true, activeRunId: null, status: t.status ?? null };
  const stop = toolOffers(session, "t3_thread_interrupt", "stop");
  let interrupted = null;
  if (activeRun || (stop && children.length)) interrupted = await interruptThread(session, threadId, Math.min(timeoutMs, 10_000), stop);
  const out = await archiveThread(session, threadId, timeoutMs);
  return { ...out, ...(interrupted ? { stop, cancel: interrupted.cancel } : {}) };
}

function threadOf(out) {
  return out?.thread ?? out ?? {};
}

// One approval entry of T3's pending-request list or read, normalized to
// what a supervisor decides on: detail is the command or file it asks for.
function approvalEntry(e) {
  const files = Array.isArray(e.files) ? e.files.map((f) => (typeof f === "string" ? f : f?.path)).filter(Boolean).join(", ") : "";
  const detail = [e.command, e.prompt, e.detail, e.filePath, e.path, files].find((v) => typeof v === "string" && v.trim()) ?? null;
  return { requestId: e.requestId, kind: e.kind ?? null, detail, reason: e.reason ?? null, override: e.override ?? null };
}

// The pending runtime requests on one thread: the questions T3's
// pending-request tools can read and answer, the approvals they list and
// answer on a server with approvalResponses (approvalRequests), and the
// remainder of pendingRequestCount, which those tools cannot see. Each
// unseen request is identified by the id of its waiting approval_request item
// among the thread's last READ_LIMIT_MAX activity items, so an approval
// answered and replaced by another between two reads is a new set; a pending
// request T3 shows no such item for is counted only.
async function pendingOf(session, threadId, t) {
  const count = t.pendingRequestCount ?? 0;
  if (!count) return { questions: [], approvals: 0, approvalIds: [], approvalRequests: [] };
  const listed = await pendingRequest(session, "list", { threadId });
  const entries = (Array.isArray(listed?.requests) ? listed.requests : []).filter((e) => e && typeof e.requestId === "string");
  const listedApprovals = entries.filter((e) => e.type === "approval");
  const approvalIdSet = new Set(listedApprovals.map((e) => e.requestId));
  const ids = [...new Set([...(listed?.requestIds ?? []), ...entries.map((e) => e.requestId)])].filter((id) => !approvalIdSet.has(id)).sort();
  const approvalRequests = (await approvalResponses(session))
    ? listedApprovals.map(approvalEntry).sort((a, b) => (a.requestId < b.requestId ? -1 : a.requestId > b.requestId ? 1 : 0))
    : [];
  const answerable = new Set(approvalRequests.map((a) => a.requestId));
  const approvals = Math.max(0, count - ids.length - approvalRequests.length);
  if (!approvals) return { questions: ids, approvals, approvalIds: [], approvalRequests };
  const { items } = await readTail(session, threadId, t.itemCount ?? 0, READ_LIMIT_MAX);
  const open = items
    .filter((it) => it?.type === APPROVAL_ITEM && it.status === APPROVAL_WAITING && !answerable.has(it.requestId ?? String(it.itemId).replace(APPROVAL_ITEM_ID_PREFIX, "")))
    .map((it) => it.itemId);
  return { questions: ids, approvals, approvalIds: open.slice(-approvals), approvalRequests };
}

// The signature the watcher stores once it has escalated a thread's pending
// requests, so the same requests never wake it twice:
// q:<question ids>;a:<unseen count>[:<approval item ids>][;r:<approval request ids>].
const pendingSignature = (p) =>
  `q:${p.questions.join(",")};a:${p.approvals}${p.approvalIds.length ? `:${p.approvalIds.join(",")}` : ""}` +
  (p.approvalRequests.length ? `;r:${p.approvalRequests.map((a) => a.requestId).join(",")}` : "");

async function requests(flags) {
  const threadId = need(flags, "thread");
  const { session } = await verifiedSession(flags);
  const t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
  const pending = await pendingOf(session, threadId, t);
  const questions = [];
  for (const requestId of pending.questions) {
    const q = await pendingRequest(session, "read", { threadId, requestId });
    questions.push({ requestId, questions: q?.questions ?? [] });
  }
  return {
    ok: true,
    threadId,
    pendingRequestCount: t.pendingRequestCount ?? 0,
    questions,
    approvalResponses: await approvalResponses(session),
    approvalRequests: pending.approvalRequests,
    approvals: pending.approvals,
    signature: pendingSignature(pending),
  };
}

async function respond(flags) {
  const threadId = need(flags, "thread");
  const requestId = need(flags, "request");
  const file = need(flags, "answers-file");
  let answers;
  try {
    answers = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    usage(`--answers-file ${file} must hold JSON`);
  }
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) usage("--answers-file must hold a JSON object keyed by question id");
  const { session } = await verifiedSession(flags);
  await pendingRequest(session, "respond", { threadId, requestId, answers });
  return { ok: true, threadId, requestId };
}

// approve: answer one pending permission approval (see the header).
async function approve(flags) {
  const threadId = need(flags, "thread");
  const requestId = need(flags, "request");
  const decision = need(flags, "decision");
  if (!APPROVAL_DECISIONS.includes(decision)) usage(`--decision must be one of ${APPROVAL_DECISIONS.join(", ")}`);
  let feedback;
  if (flags["feedback-file"] !== undefined) {
    if (decision !== "deny") usage("--feedback-file holds the text the agent sees on a deny; it is accepted only with --decision deny");
    try {
      feedback = readFileSync(flags["feedback-file"], "utf8");
    } catch {
      usage(`--feedback-file ${flags["feedback-file"]} cannot be read`);
    }
  }
  const { session } = await verifiedSession(flags);
  if (!(await approvalResponses(session))) {
    throw new Refusal(
      "approval_responses_unsupported",
      `T3 at ${session.origin} does not advertise ${APPROVAL_FEATURE}, so a permission approval cannot be answered over /mcp; interrupt the worker and steer it instead (docs/t3code-backend.md)`,
      4,
    );
  }
  const read = await pendingRequest(session, "read", { threadId, requestId });
  if (read?.type !== "approval") {
    throw new Refusal("not_an_approval", `request ${requestId} on thread ${threadId} is not a pending permission approval; answer a question with respond`, 4);
  }
  const approval = approvalEntry({ ...read, requestId });
  await pendingRequest(session, "respond", { threadId, requestId, decision, ...(feedback !== undefined ? { feedback } : {}) });
  return { ok: true, threadId, requestId, decision, ...(feedback !== undefined ? { feedback } : {}), approval };
}

// watch: one bounded supervision wait across threads (see the header).
async function watch(flags) {
  const threadIds = [...new Set(flags.all.thread ?? [])];
  if (!threadIds.length) usage("--thread is required");
  const timeoutMs = flags["timeout-ms"] === "0" ? 0 : positiveInt(flags, "timeout-ms", 60_000, 3_600_000);
  const stateDir = flags["state-dir"];
  if (stateDir !== undefined && !path.isAbsolute(stateDir)) usage("--state-dir must be an absolute path");
  const escalated = new Map();
  for (const pair of flags.all.escalated ?? []) {
    const eq = pair.indexOf("=");
    if (eq <= 0) usage("--escalated takes <thread-id>=<signature>");
    escalated.set(pair.slice(0, eq), pair.slice(eq + 1));
  }
  const { session } = await verifiedSession(flags);
  const cleared = [];
  const runs = [];
  for (const threadId of threadIds) {
    let t;
    try {
      t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
    } catch (err) {
      if (isNotFound(err)) continue;
      throw err;
    }
    if (t.archived === true || t.archivedAt) continue;
    const pending = await pendingOf(session, threadId, t);
    const signature = pendingSignature(pending);
    if (pending.questions.length || pending.approvals || pending.approvalRequests.length) {
      if (escalated.get(threadId) !== signature) {
        return { ok: true, event: "blocked", threadId, signature, questions: pending.questions, approvals: pending.approvals, approvalRequests: pending.approvalRequests, cleared };
      }
    } else if (escalated.has(threadId)) {
      cleared.push(threadId);
    }
    if (t.activeRunId) runs.push({ threadId, runId: t.activeRunId });
  }
  if (!timeoutMs || (!runs.length && stateDir === undefined)) return { ok: true, event: "none", cleared };
  const abort = new AbortController();
  const notEnded = new Error("not ended");
  const waits = runs.map(async ({ threadId, runId }) => {
    const waited = await waitRun(session, threadId, runId, timeoutMs, abort.signal);
    if (waited?.runId === runId && waited?.timedOut !== true && TERMINAL_RUN.has(waited?.status)) return { threadId, runId, status: waited.status };
    throw notEnded;
  });
  if (stateDir !== undefined) {
    waits.push(
      stateDirWait(stateDir, timeoutMs, abort.signal).then((changed) => {
        if (changed?.event === "state-changed") return { stateChanged: changed.name };
        throw notEnded;
      }),
    );
  }
  try {
    const ended = await Promise.any(waits).catch((err) => {
      if (err.errors.every((e) => e !== notEnded)) throw err.errors[0];
      return null;
    });
    if (ended?.stateChanged !== undefined) return { ok: true, event: "state-changed", name: ended.stateChanged, cleared };
    return ended ? { ok: true, event: "run-ended", ...ended, cleared } : { ok: true, event: "timeout", cleared };
  } finally {
    abort.abort();
  }
}

// The state-directory half of a watch: a directory that cannot be watched is
// a timeout after the budget, never an immediate answer, so a caller that
// re-arms on return cannot spin on an unwatchable directory.
function stateDirWait(dir, timeoutMs, signal) {
  return watchStateDir(dir, timeoutMs, signal).catch(
    (err) =>
      new Promise((resolve) => {
        const timer = setTimeout(() => resolve({ event: "timeout", error: err?.message ?? String(err) }), timeoutMs);
        signal?.addEventListener(
          "abort",
          () => {
            clearTimeout(timer);
            resolve({ event: "aborted" });
          },
          { once: true },
        );
      }),
  );
}

async function archive(flags) {
  const threadId = need(flags, "thread");
  const timeoutMs = positiveInt(flags, "timeout-ms", ARCHIVE_TIMEOUT_MS, 600_000);
  const { session } = await verifiedSession(flags);
  return archiveThread(session, threadId, timeoutMs);
}

// t3_thread_organize archive, then the read-back that proves the close:
// archived:true and activeRunId:null with no active delegated thread below
// it (archive does not stop delegated tasks), or a thread the server no
// longer has.
async function archiveThread(session, threadId, timeoutMs) {
  try {
    await session.call("t3_thread_organize", { threadId, action: "archive" });
  } catch (err) {
    if (isNotFound(err)) return { ok: true, threadId, closed: true, missing: true };
    // An already-archived thread is the end state; the read-back decides.
    if (!(err instanceof Refusal && /already archived/i.test(err.message))) throw err;
  }
  const deadline = Date.now() + timeoutMs;
  let t = {};
  let children = [];
  for (;;) {
    t = threadOf(await session.call("t3_thread_read", { threadId, limit: 1, runLimit: 1 }));
    const archived = t.archived === true || Boolean(t.archivedAt);
    if (archived && (t.activeRunId ?? null) === null) {
      children = await activeDescendants(session, threadId, t.projectId);
      if (!children.length) return { ok: true, threadId, closed: true, archived: true, activeRunId: null, status: t.status ?? null };
    }
    if (Date.now() >= deadline) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  const childNote = children.length ? `, and delegated thread(s) ${children.join(", ")} still run; stop them in T3 Code` : "";
  throw new Refusal(
    "close_unproven",
    `thread ${threadId} did not read back archived with no active run within ${timeoutMs} ms (archived=${t.archived === true || Boolean(t.archivedAt)}, activeRunId=${t.activeRunId ?? null})${childNote}`,
    1,
    { thread: t, activeChildren: children },
  );
}

// Every thread T3 lists for a project with the given statuses, across pages,
// without delegated subagents.
async function listThreads(session, projectId, statuses) {
  const seen = new Map();
  let cursor;
  for (let page = 0; page < 1000; page++) {
    const listed = await session.call("t3_thread_list", { projectId, statuses, includeSubagents: false, limit: 100, ...(cursor !== undefined ? { cursor } : {}) });
    for (const item of listed?.threads ?? []) seen.set(item.threadId, item);
    if (listed?.nextCursor === null || listed?.nextCursor === undefined) break;
    cursor = listed.nextCursor;
  }
  return [...seen.values()];
}

// thread-for-root: away-mode supervisor discovery. T3 puts no thread id into
// the agent's environment, so the only self-discovery is a cwd match: on the
// project rooted at <root>, the unarchived thread with no worktree of its own
// whose run is active (the daemon starts from inside the captain's own turn).
// A fork is an ordinary conversation and counts; a delegated subagent does not.
async function threadForRoot(flags) {
  const rootPath = need(flags, "root");
  if (!path.isAbsolute(rootPath)) usage("--root must be an absolute path");
  const { session } = await verifiedSession(flags);
  const project = await projectForRoot(session, rootPath);
  if (!project) throw new Refusal("no_thread", `T3 has no project rooted at ${rootPath}`, 5);
  const live = [];
  for (const item of await listThreads(session, project.id, ACTIVE_STATUSES)) {
    if (item.relationshipToParent === "subagent") continue;
    const t = threadOf(await session.call("t3_thread_read", { threadId: item.threadId, limit: 1, runLimit: 1 }));
    if (t.relationshipToParent === "subagent" || t.archived === true || t.archivedAt || (t.worktreePath ?? null) !== null) continue;
    if (ACTIVE_STATUSES.includes(t.status)) live.push(item.threadId);
  }
  if (live.length === 1) return { ok: true, threadId: live[0] };
  if (live.length === 0) throw new Refusal("no_thread", `no live T3 thread runs in ${rootPath}`, 5);
  throw new Refusal("ambiguous_thread", `${live.length} live T3 threads run in ${rootPath} (${live.join(", ")}); set FM_SUPERVISOR_TARGET to the captain thread id`, 6, { threadIds: live });
}

const VERBS = {
  login,
  status,
  state,
  "project-ensure": projectEnsure,
  "project-read": projectRead,
  harness: harnessVerb,
  "resolve-selection": resolveSelection,
  launch,
  send,
  read,
  capture,
  wait,
  interrupt,
  requests,
  respond,
  approve,
  watch,
  archive,
  close,
  "thread-for-root": threadForRoot,
};

async function main(argv) {
  const [verb, ...rest] = argv;
  const fn = VERBS[verb];
  if (!fn) usage(`unknown verb '${verb ?? ""}' (verbs: ${Object.keys(VERBS).join(", ")})`);
  let out;
  try {
    out = await fn(parseFlags(rest));
  } finally {
    await Promise.all([...SESSIONS].map((s) => s.close()));
  }
  if (verb === "capture") process.stdout.write(`${out.text}\n`);
  else process.stdout.write(`${JSON.stringify(out)}\n`);
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return path.resolve(entry) === self;
  }
}

if (invokedDirectly()) {
  main(process.argv.slice(2)).catch((err) => {
    const r = err instanceof Refusal ? err : new Refusal("unexpected", err?.message ?? String(err), 1);
    process.stdout.write(`${JSON.stringify({ ok: false, error: { code: r.code, message: r.message, ...r.extra } })}\n`);
    process.stderr.write(`fm-t3-mcp: ${r.message}\n`);
    process.exit(r.exit);
  });
}
