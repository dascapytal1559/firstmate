#!/usr/bin/env node
// fm-state-watch.mjs - a bounded wait for a worker's status or turn-end change
// in a Firstmate state directory, so a watcher cycle on a home with no
// push-capable backend wakes on the append itself instead of sleeping out its
// poll interval (bin/fm-watch.sh state_wait_or_sleep; docs/watcher-continuity.md
// "Signal coalescing and the terminal fast path").
//
// Usage:
//   fm-state-watch.mjs --dir <state-dir> --timeout-ms <n>
//     Prints one JSON object: {"ok":true,"event":"state-changed","name":"<entry>"}
//     once an entry named *.status or *.turn-ended directly under <dir>
//     changes (any other name, including this home's dot-prefixed bookkeeping,
//     is ignored), after a short debounce so the write that follows a create
//     rides the same wake; or {"ok":true,"event":"timeout"} when the budget
//     passes first. Exit 0 either way. Exit 1 when the directory cannot be
//     watched at all, printed with the reason, so the caller sleeps its budget
//     instead; exit 2 on invalid use.
//
// bin/fm-t3-mcp.mjs imports watchStateDir to race the same change against its
// T3 run wait (`watch --state-dir`), so one name filter and one debounce serve
// both the push and the poll-only path.

import { realpathSync, watch } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const STATE_WATCH_DEBOUNCE_MS = 50;

// Only the two worker-written signal files the watcher scans (scan_signals in
// bin/fm-watch.sh); dot-prefixed entries are the home's own markers.
export function stateWatchName(name) {
  if (typeof name !== "string" || name === "" || name.startsWith(".")) return false;
  return name.endsWith(".status") || name.endsWith(".turn-ended");
}

// Resolves {event:"state-changed", name} on the first matching change,
// {event:"timeout"} when timeoutMs passes, or {event:"aborted"} when the
// signal fires; rejects only when the directory cannot be watched.
export function watchStateDir(dir, timeoutMs, signal) {
  return new Promise((resolve, reject) => {
    let watcher = null;
    let timer = null;
    let debounce = null;
    let settled = false;
    const onAbort = () => finish(resolve, { event: "aborted" });
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (debounce) clearTimeout(debounce);
      signal?.removeEventListener("abort", onAbort);
      try {
        watcher?.close();
      } catch {
        // Closing a watcher that already errored is not a second failure.
      }
      fn(value);
    };
    if (signal?.aborted) {
      finish(resolve, { event: "aborted" });
      return;
    }
    signal?.addEventListener("abort", onAbort, { once: true });
    try {
      watcher = watch(dir, { persistent: true }, (_type, name) => {
        const entry = typeof name === "string" ? name : name ? name.toString() : "";
        if (!stateWatchName(entry) || debounce) return;
        debounce = setTimeout(() => finish(resolve, { event: "state-changed", name: entry }), STATE_WATCH_DEBOUNCE_MS);
      });
    } catch (err) {
      finish(reject, err);
      return;
    }
    watcher.on("error", (err) => finish(reject, err));
    timer = setTimeout(() => finish(resolve, { event: "timeout" }), timeoutMs);
  });
}

function usage(message) {
  process.stderr.write(`fm-state-watch: ${message}\nusage: fm-state-watch.mjs --dir <state-dir> --timeout-ms <n>\n`);
  process.exit(2);
}

async function main(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined || value.startsWith("--")) usage(`unexpected argument '${key ?? ""}'`);
    flags[key.slice(2)] = value;
  }
  const dir = flags.dir;
  if (!dir || !path.isAbsolute(dir)) usage("--dir must be an absolute path");
  const timeoutMs = Number(flags["timeout-ms"]);
  if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) usage("--timeout-ms must be a positive integer");
  let out;
  try {
    out = await watchStateDir(dir, timeoutMs);
  } catch (err) {
    process.stdout.write(`${JSON.stringify({ ok: false, error: { code: "unwatchable", message: err?.message ?? String(err) } })}\n`);
    process.stderr.write(`fm-state-watch: cannot watch ${dir}: ${err?.message ?? err}\n`);
    process.exit(1);
  }
  process.stdout.write(`${JSON.stringify({ ok: true, ...out })}\n`);
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
  main(process.argv.slice(2));
}
