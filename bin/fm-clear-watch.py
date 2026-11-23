#!/usr/bin/env python3
"""fm-clear-watch.py - nightly check of every clear of FirstMate's main session.

The fork's stage 2a of automatic clearing (FORK.md "A nightly check watches
every clear"). bin/fm-clear-watch.sh is the entry point and resolves FM_HOME;
this file owns the whole contract below. No model is called: it reads only
FirstMate's own Claude session transcripts.

Usage:
  fm-clear-watch.sh [--now <epoch>] [--transcripts <dir>]... [--weekly] [--no-write]

What it reads
  The transcripts of this home's Claude sessions, by default under every
  account that can run it: ${CLAUDE_CONFIG_DIR:-$HOME/.claude} and each login
  folder $HOME/.claude-profiles/*, each at projects/<FM_HOME with every
  non-alphanumeric character replaced by "-">. A session id found in more than
  one folder counts once (the copy written last). --transcripts replaces that
  default (repeatable). When none of the folders holds a current main session,
  the listing says so instead of "No clears", and the morning briefing gets a
  line saying so. A transcript is a main FirstMate session when its first
  prompt is not the supervision host's (MAIN DIALOG MIRROR, FIRSTMATE
  SUPERVISION WAKE) and it printed the session-start digest, or it began with
  an operational-input doorbell, or it never got a model reply (a fresh session that
  failed to start). Main sessions are ordered by their first entry; each one
  that follows another is one clear.

The day
  The clears whose new session began in the 24 hours ending one hour before
  --now (default: now). The hour of slack gives every clear its full first
  hour, so each clear is judged once, by the run after its hour ends.

Each clear's cause
  - a cold start from a notification: the new session began with an
    operational-input doorbell (bin/fm-operational-input.sh), the form in
    which bin/fm-claude-stop-cold-reroute.sh rings a wake;
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
    "## Clear check" heading: one line only when a clear showed a sign of harm
    or no current main session was found, and on Mondays one line totalling the seven days ending
    at the same point, with how many of those clears showed the concrete sign
    (a decision already answered was asked again) and how the share of clears
    with any sign compares with the previous recorded week. Each line is
    written once per date, so a rerun adds nothing;
  - <FM_HOME>/data/clear-watch/weekly.tsv, on each Monday run: one row per
    week, tab-separated with a header: the week's end date (the local date of
    the run), its clears, the clears with any sign, and the clears with the
    concrete sign. Rerunning the same end date replaces its row. The previous
    week is the latest row with an earlier end date; with none, the line says
    nothing about change. The file is private and the record of the trend.
  --no-write prints the listing and the briefing lines and writes no file; the
  weekly line still compares with the rows already recorded. --weekly on any
  day but Monday prints that day's weekly line the same way and writes no file,
  so an off-cycle window never becomes the previous week.

Exit status: 0 on success, 1 when no transcript directory exists, 2 on a usage
error.
"""

from __future__ import annotations

import glob
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
# The opening of bin/fm-operational-input.sh's record-backed doorbell, which
# bin/fm-claude-stop-cold-reroute.sh sends.
DOORBELL_PREFIX = ": Firstmate operational input waiting: read '"
RESTART_PREFIX = "The T3 server restarted"
# Prompts that are not his words.
NOT_CAPTAIN_PREFIXES = HOST_PREFIXES + (
    DOORBELL_PREFIX,
    RESTART_PREFIX,
    "<task-notification",
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
        return self.digest or first.startswith(DOORBELL_PREFIX) or (not self.calls and bool(self.prompts))


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
    if first.startswith(DOORBELL_PREFIX):
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
        "concrete": bool(reasked),
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


NO_MAIN_LINE = (
    "- **Clear check:** no current main session found in {n} transcript folder(s), "
    "so no clears could be judged. Details: {report}"
)


def no_main_listing(dirs, win_start, win_end):
    """The listing when no main session is current: say so, never 'No clears'."""
    lines = [
        f"# Clears, {datetime.fromtimestamp(win_start).strftime('%a %d %b %H:%M')} to {datetime.fromtimestamp(win_end).strftime('%a %d %b %H:%M')}",
        "",
        "No current main session found, so no clears could be judged. "
        "FirstMate may be running under an account this check does not read.",
        "",
        "Folders read:",
    ]
    lines += [f"- {d}" for d in dirs]
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


WEEKLY_HEADER = ("week_end", "clears", "with_sign", "with_concrete_sign")
CONCRETE_SIGN = "a decision already answered was asked again"


def week_totals(clears):
    """The three counts kept for a week, in WEEKLY_HEADER order after its end date."""
    return (len(clears), sum(1 for c in clears if c["signs"]), sum(1 for c in clears if c["concrete"]))


def read_weekly(path):
    """Recorded weeks as {end date: (clears, with sign, with concrete sign)}; malformed rows are skipped."""
    rows = {}
    if not os.path.exists(path):
        return rows
    with open(path) as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 4 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", fields[0]) and all(f.isdigit() for f in fields[1:]):
                rows[fields[0]] = tuple(int(f) for f in fields[1:])
    return rows


def write_weekly(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w") as handle:
        handle.write("\t".join(WEEKLY_HEADER) + "\n")
        for end in sorted(rows):
            handle.write("\t".join((end,) + tuple(str(n) for n in rows[end])) + "\n")
    os.replace(tmp, path)


def previous_week(rows, end):
    earlier = [d for d in rows if d < end]
    return (max(earlier), rows[max(earlier)]) if earlier else None


def week_comparison(totals, previous):
    """How this week's share of clears with a sign compares with the previous recorded week."""
    if previous is None:
        return ""
    end, (p_clears, p_sign, p_concrete) = previous
    was = f"the week ending {end} had {p_sign} of {p_clears} clears with a sign, {p_concrete} concrete"
    clears, sign, _ = totals
    if not p_clears or not clears:
        return f"; {was}"
    # Cross-multiplied, so the comparison is exact.
    left, right = sign * p_clears, p_sign * clears
    trend = "up" if left > right else "down" if left < right else "level"
    return f"; {was}, so the share with a sign is {trend}"


def weekly_line(clears, previous=None):
    if not clears:
        return "- **Clears this week:** none."
    counts = {}
    for c in clears:
        counts[c["cause"]] = counts.get(c["cause"], 0) + 1
    parts = [f"{counts[k]} {CAUSE_TEXT[k][2][counts[k] != 1]}" for k in CAUSES if k in counts]
    totals = week_totals(clears)
    harm = f"{totals[1]} showed a sign of harm"
    if totals[1]:
        harm += f", {totals[2]} of them concrete ({CONCRETE_SIGN})"
    return (
        f"- **Clears this week:** {len(clears)} ({', '.join(parts)}), dropping about "
        f"{tokens(sum(c['saved'] for c in clears))} tokens of context; {harm}{week_comparison(totals, previous)}."
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


def default_transcript_dirs(home):
    """This home's transcript folder under every Claude account that can run it.

    The default config folder (CLAUDE_CONFIG_DIR, else ~/.claude) first, then
    each login folder ~/.claude-profiles/*. FirstMate's main session has run
    under more than one account, so reading a single folder would see no clears
    after a move.
    """
    encoded = re.sub(r"[^A-Za-z0-9]", "-", home)
    user = os.path.expanduser("~")
    roots = [os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(user, ".claude")]
    roots += sorted(glob.glob(os.path.join(glob.escape(user), ".claude-profiles", "*")))
    dirs, seen = [], set()
    for root in roots:
        directory = os.path.join(root, "projects", encoded)
        real = os.path.realpath(directory)
        if real not in seen:
            seen.add(real)
            dirs.append(directory)
    return dirs


def recent_transcripts(dirs, load_from):
    """Transcript paths modified since load_from, one per session id.

    The same session id found in two folders is one session: keep the copy
    written last.
    """
    newest = {}
    for directory in dirs:
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
            if not (name.endswith(".jsonl") and os.path.isfile(path)):
                continue
            mtime = os.path.getmtime(path)
            if mtime >= load_from and (name not in newest or mtime > newest[name][0]):
                newest[name] = (mtime, path)
    return [path for _, path in sorted(newest.values())]


def usage(code):
    stream = sys.stdout if code == 0 else sys.stderr
    stream.write(
        "Usage: fm-clear-watch.sh [--now <epoch>] [--transcripts <dir>]... [--weekly] [--no-write]\n\n"
        "Lists every clear of FirstMate's main session in the day ending an hour ago,\n"
        "with its cause, saving, and signs of harm from the new session's first hour.\n"
        "Writes data/clear-watch/<date>.md, and one line in the morning briefing\n"
        "(data/morning/<date>.md) only when something shows, plus a weekly total on\n"
        "Mondays, which also records the week in data/clear-watch/weekly.tsv.\n"
        "--weekly on another day prints that total and writes nothing.\n"
        "--no-write only prints. Header: bin/fm-clear-watch.py.\n"
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
    dirs = dirs or default_transcript_dirs(home)
    dirs = [d for d in dirs if os.path.isdir(d)]
    if not dirs:
        sys.stderr.write("fm-clear-watch: no transcript directory found\n")
        return 1

    win_end = now - FIRST_HOUR
    day_start = win_end - 86400
    monday = datetime.fromtimestamp(now).weekday() == 0
    write = write and (monday or not weekly)
    weekly = weekly or monday
    load_from = (win_end - 7 * 86400 if weekly else day_start) - LOAD_MARGIN_SECONDS
    sessions = [load_session(path) for path in recent_transcripts(dirs, load_from)]

    date = datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    report_rel = f"data/clear-watch/{date}.md"
    day = clears_between(sessions, day_start, win_end)
    has_main = any(s.start is not None and s.is_main() for s in sessions)
    if has_main:
        text = listing(day, day_start, win_end)
        lines = [line for line in (daily_line(day, report_rel),) if line]
    else:
        text = no_main_listing(dirs, day_start, win_end)
        lines = [NO_MAIN_LINE.format(n=len(dirs), report=report_rel)]
    weekly_path = os.path.join(home, "data", "clear-watch", "weekly.tsv")
    week = None
    if weekly and has_main:
        week = clears_between(sessions, win_end - 7 * 86400, win_end)
        recorded = read_weekly(weekly_path)
        lines.append(weekly_line(week, previous_week(recorded, date)))

    sys.stdout.write(text)
    if lines:
        sys.stdout.write("\nMorning briefing:\n" + "\n".join(lines) + "\n")
    if write:
        report = os.path.join(home, report_rel)
        os.makedirs(os.path.dirname(report), exist_ok=True)
        with open(report, "w") as handle:
            handle.write(text)
        if week is not None:
            recorded[date] = week_totals(week)
            write_weekly(weekly_path, recorded)
        if lines:
            append_briefing(os.path.join(home, "data", "morning", f"{date}.md"), lines)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
