#!/usr/bin/env python3
"""fm-clear-watch.py - nightly check of every clear of FirstMate's main session.

The fork's stage 2a of automatic clearing (FORK.md "A nightly check watches
every clear"). bin/fm-clear-watch.sh is the entry point and resolves FM_HOME;
this file owns the whole contract below. No model is called: it reads only
FirstMate's own Claude session transcripts.

Usage:
  fm-clear-watch.sh [--now <epoch>] [--transcripts <dir>]... [--weekly] [--no-write]

What it reads
  The transcripts of this home's Claude sessions, by default
  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<FM_HOME with every
  non-alphanumeric character replaced by "-">. --transcripts replaces that
  default (repeatable). A transcript is a main FirstMate session when its first
  prompt is not the supervision host's (MAIN DIALOG MIRROR, FIRSTMATE
  SUPERVISION WAKE) and it printed the session-start digest, or it began with
  the cold-reroute message, or it never got a model reply (a fresh session that
  failed to start). Main sessions are ordered by their first entry; each one
  that follows another is one clear.

The day
  The clears whose new session began in the 24 hours ending one hour before
  --now (default: now). The hour of slack gives every clear its full first
  hour, so each clear is judged once, by the run after its hour ends.

Each clear's cause
  - a cold start from a notification: the new session began with the message
    bin/fm-claude-stop-cold-reroute.sh sends;
  - a fresh start after a T3 restart: it began with T3's restart note;
  - a cold start from a message: the old session's last request was more than
    an hour (the prompt-cache lifetime) before the new session, and its context
    was over 100k tokens, the floor of both cold rules;
  - otherwise his /clear. A /clear he armed on a cold, large session reads as
    a cold start; either way the context was dropped.
  What it saved: the old session's last context before the clear (input plus
  cache read plus cache write) minus 71k, a fresh session's start.

Signs of harm, in the new session's first hour
  - his first message is under 60 characters and quotes nothing;
  - a message of his uses a recall phrase (RECALL_PHRASES below);
  - he quoted a reply the new session never wrote (T3 quotes carry the quoted
    reply's message id), that is, the previous session;
  - a decision is held again (fm-captain-hold.sh hold) that the old session had
    answered (fm-captain-hold.sh answer, or fm-send.sh --resolve-key);
  - a task is dispatched (fm-spawn.sh printed "spawned <id>") that was already
    dispatched in the day before;
  - a wake the old session was shown (WAKE_ACK_REQUIRED) and never acknowledged,
    or the wake a notification's cold start carries, is not acknowledged;
  - after an automatic clear (any cause but his /clear), no "lock acquired"
    within 5 minutes of the new session's start.
  Only successful tool calls count. No message text is ever written out: a
  recall sign names the phrase, nothing more.

What it writes
  - stdout and <FM_HOME>/data/clear-watch/<local date>.md: every clear of the
    day with its cause, context, saving, and signs;
  - <FM_HOME>/data/morning/<local date>.md, the morning briefing, under a
    "## Clear check" heading: one line only when a clear showed a sign of harm,
    and on Mondays (or with --weekly) one line totalling the seven days ending
    at the same point. Each line is written once per date, so a rerun adds
    nothing.
  --no-write prints the listing and the briefing lines and writes no file.

Exit status: 0 on success, 1 when no transcript directory exists, 2 on a usage
error.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime

CACHE_SECONDS = 3600
COLD_FLOOR_TOKENS = 100_000
FRESH_TOKENS = 71_000
FIRST_HOUR = 3600
LOCK_GRACE_SECONDS = 300
SHORT_CHARS = 60
LOAD_MARGIN_SECONDS = 3 * 86400

HOST_PREFIXES = ("MAIN DIALOG MIRROR", "FIRSTMATE SUPERVISION WAKE")
# The opening of the message bin/fm-claude-stop-cold-reroute.sh sends.
REROUTE_PREFIX = "A firstmate supervision wake is waiting in the durable wake queue."
RESTART_PREFIX = "The T3 server restarted"
# Prompts that are not his words.
NOT_CAPTAIN_PREFIXES = HOST_PREFIXES + (
    REROUTE_PREFIX,
    RESTART_PREFIX,
    "<task-notification",
    ": Firstmate operational",
    "<command-",
    "<local-command",
    "Continue where you left",
    "[Request interrupted",
    "Stop hook",
    "Context refreshed",
    "<bash-",
)
RECALL_PHRASES = (
    "earlier",
    "we discussed",
    "do you remember",
    "remember when",
    "as i said",
    "like i said",
    "i told you",
    "we talked about",
    "last time",
    "before the clear",
)

DIGEST_RE = re.compile(r"SESSION START (?:- |\(CONTEXT RE-EMIT\))")
LOCK_RE = re.compile(r"lock acquired: harness pid")
ACK_REQUIRED_RE = re.compile(r"WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain\.sh --ack-through (\d+)")
# A successful acknowledgement prints nothing, so it is read from the command
# and its result; a refused one says "nothing was acknowledged".
ACK_COMMAND_RE = re.compile(r"fm-wake-drain\.sh\s+--ack-through\s+(\d+)")
ACK_REFUSED = "nothing was acknowledged"
SPAWNED_RE = re.compile(r"(?:^|\n)spawned ([A-Za-z0-9][A-Za-z0-9._-]*) harness=")
HOLD_RE = re.compile(r"fm-captain-hold\.sh\s+hold\s+([A-Za-z0-9][A-Za-z0-9._-]*)")
ANSWER_RES = (
    re.compile(r"fm-captain-hold\.sh\s+answer\s+([A-Za-z0-9][A-Za-z0-9._-]*)"),
    re.compile(r"fm-send\.sh\b.*?--resolve-key[ =]([A-Za-z0-9][A-Za-z0-9._-]*)", re.S),
)
CITATIONS_RE = re.compile(r"<assistant_citations>.*?</assistant_citations>", re.S)
QUOTE_TOKEN_RE = re.compile(r"\[assistant-quote-\d+\]")
MESSAGE_ID_RE = re.compile(r'"messageId"\s*:\s*"([^"]*)"')
MSG_ID_RE = re.compile(r"msg_[A-Za-z0-9]+")

CAUSES = ("manual", "cold-message", "notification", "restart")
# (listing column, in a sentence, counted in the weekly total)
CAUSE_TEXT = {
    "manual": ("your /clear", "your /clear", ("by your /clear", "by your /clear")),
    "cold-message": (
        "cold start from your message",
        "the cold start from your message",
        ("cold start from your message", "cold starts from your message"),
    ),
    "notification": (
        "cold start from a notification",
        "the cold start from a notification",
        ("cold start from a notification", "cold starts from a notification"),
    ),
    "restart": (
        "fresh start after a T3 restart",
        "the fresh start after a T3 restart",
        ("fresh start after a T3 restart", "fresh starts after a T3 restart"),
    ),
}


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"
        )
    return ""


@dataclass
class Prompt:
    t: float
    text: str


@dataclass
class Session:
    sid: str
    start: float | None = None
    calls: list = field(default_factory=list)  # (t, ctx), deduped by message id
    msg_ids: set = field(default_factory=set)
    prompts: list = field(default_factory=list)
    digest: bool = False
    lock_t: float | None = None
    # (t, kind, value) in transcript order: kind is spawned, answered, held,
    # ack-required, or acked.
    events: list = field(default_factory=list)

    @property
    def first_prompt(self):
        return self.prompts[0].text if self.prompts else ""

    def is_main(self):
        first = self.first_prompt
        if first.startswith(HOST_PREFIXES):
            return False
        return self.digest or first.startswith(REROUTE_PREFIX) or (not self.calls and bool(self.prompts))


def load_session(path):
    session = Session(sid=os.path.basename(path)[: -len(".jsonl")])
    call_index = {}
    pending_tools = {}  # tool_use id -> (kind, value) list
    with open(path, errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("isSidechain"):
                continue
            t = parse_ts(entry.get("timestamp"))
            if t is not None and (session.start is None or t < session.start):
                session.start = t
            kind = entry.get("type")
            message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            if kind == "assistant":
                usage = message.get("usage")
                if t is None or not isinstance(usage, dict) or message.get("model") == "<synthetic>":
                    continue
                ctx = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                mid = message.get("id")
                if mid:
                    session.msg_ids.add(mid)
                if mid in call_index:
                    session.calls[call_index[mid]] = (session.calls[call_index[mid]][0], ctx)
                else:
                    call_index[mid] = len(session.calls)
                    session.calls.append((t, ctx))
                for part in message.get("content") or []:
                    if isinstance(part, dict) and part.get("type") == "tool_use":
                        command = (part.get("input") or {}).get("command")
                        if isinstance(command, str):
                            found = [("held", m) for m in HOLD_RE.findall(command)]
                            for regex in ANSWER_RES:
                                found += [("answered", m) for m in regex.findall(command)]
                            found += [("acked", int(m)) for m in ACK_COMMAND_RE.findall(command)]
                            if found:
                                pending_tools[part.get("id")] = found
                continue
            if kind not in ("user", "attachment") or t is None:
                continue
            content = message.get("content")
            is_tool_result = isinstance(content, list) and any(
                isinstance(part, dict) and part.get("type") == "tool_result" for part in content
            )
            if kind == "user" and not is_tool_result:
                if entry.get("isMeta") or entry.get("isCompactSummary"):
                    continue
                text = content_text(content).strip()
                if text:
                    session.prompts.append(Prompt(t, text))
                continue
            # Tool output and hook output: the only places command results appear.
            if DIGEST_RE.search(line):
                session.digest = True
            if session.lock_t is None and LOCK_RE.search(line):
                session.lock_t = t
            if is_tool_result:
                for part in content:
                    if not isinstance(part, dict) or part.get("type") != "tool_result":
                        continue
                    found = pending_tools.pop(part.get("tool_use_id"), None)
                    if part.get("is_error"):
                        continue
                    text = content_text(part.get("content"))
                    if found:
                        session.events += [
                            (t, k, v) for k, v in found if not (k == "acked" and ACK_REFUSED in text)
                        ]
                    record_output(session, t, text)
            else:
                record_output(session, t, json.dumps(entry.get("attachment"), ensure_ascii=False))
    return session


def record_output(session, t, text):
    if not text:
        return
    for match in ACK_REQUIRED_RE.findall(text):
        session.events.append((t, "ack-required", int(match)))
    for match in SPAWNED_RE.findall(text.replace("\\n", "\n")):
        session.events.append((t, "spawned", match))


def own_words(text):
    """His own words in a prompt: quote blocks dropped, quote comments kept."""
    comments = re.findall(r'"comment"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    body = QUOTE_TOKEN_RE.sub("", CITATIONS_RE.sub("", text))
    return " ".join([body.strip()] + comments).strip()


def is_quote(text):
    return text.startswith("[assistant-quote") or "<assistant_citations>" in text


def judge(old, new):
    start = new.start
    before = [c for c in old.calls if c[0] < start]
    last_t, old_ctx = before[-1] if before else (None, 0)
    first = new.first_prompt
    if first.startswith(REROUTE_PREFIX):
        cause = "notification"
    elif first.startswith(RESTART_PREFIX):
        cause = "restart"
    elif last_t is not None and start - last_t > CACHE_SECONDS and old_ctx > COLD_FLOOR_TOKENS:
        cause = "cold-message"
    else:
        cause = "manual"

    hour_end = start + FIRST_HOUR
    signs = []
    captain = [p for p in new.prompts if start <= p.t < hour_end and not p.text.startswith(NOT_CAPTAIN_PREFIXES)]
    if captain and not is_quote(captain[0].text) and len(captain[0].text) < SHORT_CHARS:
        signs.append("your first message was short and quoted nothing")
    phrases = sorted({ph for p in captain for ph in RECALL_PHRASES if ph in own_words(p.text).lower()})
    if phrases:
        signs.append("you used a recall phrase (" + ", ".join(f'"{ph}"' for ph in phrases) + ")")
    for prompt in captain:
        if not is_quote(prompt.text):
            continue
        ids = {m for raw in MESSAGE_ID_RE.findall(prompt.text) for m in MSG_ID_RE.findall(raw)}
        replied_before = any(c[0] < prompt.t for c in new.calls)
        if (ids and not ids <= new.msg_ids) or (not ids and not replied_before):
            signs.append("you quoted the previous session")
            break

    old_events = [e for e in old.events if e[0] < start]
    new_events = [e for e in new.events if start <= e[0] < hour_end]
    answered = {v for _, k, v in old_events if k == "answered"}
    reasked = sorted({v for _, k, v in new_events if k == "held"} & answered)
    if reasked:
        signs.append("a decision you had answered was asked again (" + ", ".join(reasked) + ")")
    earlier_spawns = {v for t, k, v in old_events if k == "spawned" and t >= start - 86400}
    seen, twice = set(), set()
    for _, k, v in new_events:
        if k != "spawned":
            continue
        if v in earlier_spawns or v in seen:
            twice.add(v)
        seen.add(v)
    if twice:
        signs.append("a task was dispatched twice (" + ", ".join(sorted(twice)) + ")")

    pending = None
    for _, k, v in old_events:
        if k == "ack-required":
            pending = v if pending is None else max(pending, v)
        elif k == "acked" and pending is not None and v >= pending:
            pending = None
    if cause == "notification" and pending is None:
        pending = 0
    if pending is not None:
        acks = [v for _, k, v in new_events if k == "acked"]
        if not any(v >= pending for v in acks):
            signs.append("a notification was left unacknowledged across the clear")

    if cause != "manual":
        if new.lock_t is None or new.lock_t >= hour_end:
            signs.append("FirstMate was not back at the helm within the hour")
        elif new.lock_t - start > LOCK_GRACE_SECONDS:
            signs.append(f"FirstMate was not back at the helm for {round((new.lock_t - start) / 60)} minutes")

    return {
        "start": start,
        "cause": cause,
        "old_ctx": old_ctx,
        "saved": max(0, old_ctx - FRESH_TOKENS),
        "signs": signs,
    }


def clears_between(sessions, win_start, win_end):
    mains = sorted((s for s in sessions if s.start is not None and s.is_main()), key=lambda s: s.start)
    return [judge(old, new) for old, new in zip(mains, mains[1:]) if win_start <= new.start < win_end]


def tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    return f"{round(n / 1000)}k"


def clock(t):
    return datetime.fromtimestamp(t).strftime("%a %H:%M")


def listing(clears, win_start, win_end):
    lines = [
        f"# Clears, {datetime.fromtimestamp(win_start).strftime('%a %d %b %H:%M')} to {datetime.fromtimestamp(win_end).strftime('%a %d %b %H:%M')}",
        "",
    ]
    if not clears:
        lines.append("No clears.")
        return "\n".join(lines) + "\n"
    lines += ["| When | Cause | Context before | Saved | Signs of harm |", "|---|---|---|---|---|"]
    for c in clears:
        lines.append(
            f"| {clock(c['start'])} | {CAUSE_TEXT[c['cause']][0]} | {tokens(c['old_ctx'])} | {tokens(c['saved'])} | {'; '.join(c['signs']) or 'none'} |"
        )
    total = sum(c["saved"] for c in clears)
    lines += ["", f"{len(clears)} clears, about {tokens(total)} tokens of context dropped."]
    return "\n".join(lines) + "\n"


def daily_line(clears, report_rel):
    harmed = [c for c in clears if c["signs"]]
    if not harmed:
        return None
    items = [
        f"after {CAUSE_TEXT[c['cause']][1]} at {clock(c['start'])}, {' and '.join(c['signs'])}" for c in harmed[:3]
    ]
    more = f"; and {len(harmed) - 3} more" if len(harmed) > 3 else ""
    return (
        f"- **Clear check:** {len(harmed)} of {len(clears)} clears in the last day showed a sign of harm: "
        f"{'; '.join(items)}{more}. Details: {report_rel}"
    )


def weekly_line(clears):
    if not clears:
        return "- **Clears this week:** none."
    counts = {}
    for c in clears:
        counts[c["cause"]] = counts.get(c["cause"], 0) + 1
    parts = [f"{counts[k]} {CAUSE_TEXT[k][2][counts[k] != 1]}" for k in CAUSES if k in counts]
    harmed = sum(1 for c in clears if c["signs"])
    return (
        f"- **Clears this week:** {len(clears)} ({', '.join(parts)}), dropping about "
        f"{tokens(sum(c['saved'] for c in clears))} tokens of context; {harmed} showed a sign of harm."
    )


def append_briefing(path, lines):
    """Append each line under the Clear check heading unless already there."""
    existing = ""
    if os.path.exists(path):
        with open(path) as handle:
            existing = handle.read()
    fresh = [line for line in lines if line.split(":**")[0] not in existing]
    if not fresh:
        return
    out = ""
    if existing and not existing.endswith("\n"):
        out += "\n"
    if "## Clear check" not in existing:
        out += ("\n" if existing else "") + "## Clear check\n\n"
    out += "\n".join(fresh) + "\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as handle:
        handle.write(out)


def default_transcript_dir(home):
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(root, "projects", re.sub(r"[^A-Za-z0-9]", "-", home))


def usage(code):
    stream = sys.stdout if code == 0 else sys.stderr
    stream.write(
        "Usage: fm-clear-watch.sh [--now <epoch>] [--transcripts <dir>]... [--weekly] [--no-write]\n\n"
        "Lists every clear of FirstMate's main session in the day ending an hour ago,\n"
        "with its cause, saving, and signs of harm from the new session's first hour.\n"
        "Writes data/clear-watch/<date>.md, and one line in the morning briefing\n"
        "(data/morning/<date>.md) only when something shows, plus a weekly total on\n"
        "Mondays or with --weekly. --no-write only prints. Header: bin/fm-clear-watch.py.\n"
    )
    sys.exit(code)


def main(argv):
    now = time.time()
    dirs = []
    weekly = False
    write = True
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            usage(0)
        elif arg == "--now" and args and re.fullmatch(r"[0-9]+", args[0]):
            now = float(args.pop(0))
        elif arg == "--transcripts" and args:
            dirs.append(args.pop(0))
        elif arg == "--weekly":
            weekly = True
        elif arg == "--no-write":
            write = False
        else:
            usage(2)
    home = os.environ.get("FM_HOME")
    if not home:
        sys.stderr.write("fm-clear-watch: FM_HOME is not set\n")
        return 2
    dirs = dirs or [default_transcript_dir(home)]
    dirs = [d for d in dirs if os.path.isdir(d)]
    if not dirs:
        sys.stderr.write("fm-clear-watch: no transcript directory found\n")
        return 1

    win_end = now - FIRST_HOUR
    day_start = win_end - 86400
    weekly = weekly or datetime.fromtimestamp(now).weekday() == 0
    load_from = (win_end - 7 * 86400 if weekly else day_start) - LOAD_MARGIN_SECONDS
    sessions = []
    for directory in dirs:
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
            if name.endswith(".jsonl") and os.path.isfile(path) and os.path.getmtime(path) >= load_from:
                sessions.append(load_session(path))

    date = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    report_rel = f"data/clear-watch/{date}.md"
    day = clears_between(sessions, day_start, win_end)
    text = listing(day, day_start, win_end)
    lines = [line for line in (daily_line(day, report_rel),) if line]
    if weekly:
        lines.append(weekly_line(clears_between(sessions, win_end - 7 * 86400, win_end)))

    sys.stdout.write(text)
    if lines:
        sys.stdout.write("\nMorning briefing:\n" + "\n".join(lines) + "\n")
    if write:
        report = os.path.join(home, report_rel)
        os.makedirs(os.path.dirname(report), exist_ok=True)
        with open(report, "w") as handle:
            handle.write(text)
        if lines:
            append_briefing(os.path.join(home, "data", "morning", f"{date}.md"), lines)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
