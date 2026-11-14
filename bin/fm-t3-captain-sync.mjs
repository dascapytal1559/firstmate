#!/usr/bin/env node
// fm-t3-captain-sync.mjs - the Node half of `bin/fm-t3-captain-sync.sh listen`,
// which owns the contract (file watches, the action loop, retries, logging).
// Run only through that verb, never directly.
//
// Usage: fm-t3-captain-sync.mjs --home <dir> --state <dir> --data <dir>
//          --config <dir> --backlog <file-or-empty> --bin <dir>
//
// It prints nothing on stdout: anything there would reach firstmate as an
// unexpected process-event result.

import { spawn } from "node:child_process";
import { appendFileSync, readdirSync, readFileSync, renameSync, statSync, watch } from "node:fs";
import path from "node:path";

const DEBOUNCE_MS = 250;
const ACTIONS_WAIT_MS = 25_000;
const BACKOFF_MIN_MS = 1_000;
const BACKOFF_MAX_MS = 30_000;
const UNSUPPORTED_RETRY_MS = 300_000;
const ACTION_RETRY_MS = 30_000;
const LOG_MAX_BYTES = 256 * 1024;

function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i]?.startsWith("--") || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    flags[argv[i].slice(2)] = argv[i + 1];
  }
  for (const k of ["home", "state", "data", "config", "bin"]) if (!flags[k]) throw new Error(`--${k} is required`);
  return flags;
}

const flags = parseArgs(process.argv.slice(2));
const own = path.join(flags.state, "t3-captain-sync");
const logFile = path.join(own, "listen.log");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function log(message) {
  try {
    if (statSync(logFile, { throwIfNoEntry: false })?.size > LOG_MAX_BYTES) renameSync(logFile, `${logFile}.1`);
    appendFileSync(logFile, `${new Date().toISOString()} ${message}\n`);
  } catch {
    // Logging never stops the listener.
  }
}

function run(cmd, args) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], env: process.env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => resolve({ code: 127, stdout, stderr: err.message }));
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

const firstLine = (s) => (s.split("\n").find((l) => l.trim()) ?? "").trim();

// --- sync passes: one at a time, and one more when asked meanwhile ---------

let syncing = null;
let again = false;
let timer = null;

function syncNow() {
  if (syncing) {
    again = true;
    return syncing;
  }
  syncing = (async () => {
    do {
      again = false;
      const r = await run(path.join(flags.bin, "fm-t3-needs-me.sh"), ["sync"]);
      if (r.code !== 0) log(`sync: ${firstLine(r.stdout) || firstLine(r.stderr) || `exit ${r.code}`}`);
    } while (again);
    syncing = null;
  })();
  return syncing;
}

function schedule(why) {
  clearTimeout(timer);
  timer = setTimeout(() => {
    log(`change: ${why}`);
    syncNow();
  }, DEBOUNCE_MS);
}

// --- file watches -----------------------------------------------------------

// Each task record's thread and kept-review fields, so only a change to
// those (not every status write) runs a pass.
const metaFields = new Map();
function metaChanged(name) {
  let fields = null;
  try {
    const text = readFileSync(path.join(flags.state, name), "utf8");
    const last = (key) => [...text.matchAll(new RegExp(`^${key}=(.*)$`, "gm"))].pop()?.[1] ?? "";
    fields = `${last("t3_thread_id")}\t${last("t3_review")}`;
  } catch {
    fields = null;
  }
  const before = metaFields.has(name) ? metaFields.get(name) : undefined;
  metaFields.set(name, fields);
  return before !== fields && !(before === undefined && (fields === null || fields === "\t"));
}

function seedMetas() {
  let names = [];
  try {
    names = readdirSync(flags.state);
  } catch {
    // An unreadable state directory is retried by its watch.
  }
  for (const name of names) if (name.endsWith(".meta")) metaChanged(name);
}

const watches = new Map();
function addWatch(dir, test, label) {
  const entry = watches.get(dir) ?? { tests: [] };
  entry.tests.push({ test, label });
  watches.set(dir, entry);
}

function startWatch(dir, entry) {
  try {
    const w = watch(dir, { persistent: true }, (_event, name) => {
      const file = name ? String(name) : null;
      for (const { test, label } of entry.tests) {
        if (file === null || test(file)) {
          schedule(file === null ? label : `${label} (${file})`);
          return;
        }
      }
    });
    w.on("error", (err) => {
      log(`watch ${dir}: ${err.message}; watching again in 5 s`);
      w.close();
      setTimeout(() => startWatch(dir, entry), 5_000);
    });
  } catch (err) {
    log(`watch ${dir}: ${err.message}; trying again in 30 s`);
    setTimeout(() => startWatch(dir, entry), 30_000);
  }
}

if (flags.backlog) {
  const base = path.basename(flags.backlog);
  addWatch(path.dirname(flags.backlog), (f) => f === base, "backlog");
}
addWatch(path.join(flags.data, "needs-me"), (f) => f.endsWith(".json"), "context records");
addWatch(flags.data, (f) => f === "high-level-objectives.md", "objectives");
addWatch(path.join(flags.data, "rules"), (f) => f === "inventory.json", "rules");
addWatch(flags.config, (f) => f === "crew-dispatch.json", "model routing");
addWatch(flags.state, (f) => f.endsWith(".meta") && metaChanged(f), "task records");

// --- the captain's actions ---------------------------------------------------

// One apply-pending round (bin/fm-t3-captain-sync.sh owns the order, the
// retries, and the acknowledgement); 0 when every action T3 held settled.
async function applyPending() {
  const r = await run(path.join(flags.bin, "fm-t3-captain-sync.sh"), ["apply-pending"]);
  for (const line of r.stdout.split("\n")) if (line.trim()) log(line.replace(/^t3-captain-sync: /, ""));
  if (r.code !== 0 && r.code !== 75) log(`actions: ${firstLine(r.stderr) || `exit ${r.code}`}`);
  return r.code;
}

async function actionLoop() {
  let highest = 0;
  let retryAt = null; // when the actions T3 still holds are tried again
  let backoff = BACKOFF_MIN_MS;
  let fullPush = true;
  for (;;) {
    if (fullPush) {
      await syncNow();
      fullPush = false;
    }
    const wait = retryAt === null ? ACTIONS_WAIT_MS : Math.max(0, Math.min(ACTIONS_WAIT_MS, retryAt - Date.now()));
    const r = await run(process.execPath, [path.join(flags.bin, "fm-t3-mcp.mjs"), "actions", "--after", String(highest),
      "--wait-ms", String(wait), "--token-file", path.join(flags.config, "t3code-token")]);
    if (r.code !== 0) {
      if (r.code === 4) {
        log(`actions: ${firstLine(r.stderr) || "unsupported"}; asking again in ${UNSUPPORTED_RETRY_MS / 1000} s`);
        await sleep(UNSUPPORTED_RETRY_MS);
      } else {
        log(`actions: ${firstLine(r.stderr) || `exit ${r.code}`}; retrying in ${backoff / 1000} s`);
        await sleep(backoff);
        backoff = Math.min(backoff * 2, BACKOFF_MAX_MS);
      }
      // Back from a failure: the whole list first, then every action T3 kept.
      highest = 0;
      fullPush = true;
      continue;
    }
    backoff = BACKOFF_MIN_MS;
    const { actions } = JSON.parse(r.stdout);
    for (const a of actions) highest = Math.max(highest, a.seq);
    if (!actions.length && (retryAt === null || retryAt > Date.now())) continue;
    retryAt = (await applyPending()) === 0 ? null : Date.now() + ACTION_RETRY_MS;
  }
}

async function main() {
  seedMetas();
  for (const [dir, entry] of watches) startWatch(dir, entry);
  log("listening");
  await actionLoop();
}

main().catch(async (err) => {
  log(`stopped: ${err?.stack ?? err}`);
  // The runner starts the listener again; never in a tight loop.
  await sleep(30_000);
  process.exit(1);
});
