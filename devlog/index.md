# Firstmate, as it changes

A working journal of the captain's Firstmate fork: what changed in how the ship runs, in the captain's words where he gave them, with the evidence from each round.
It is added to as the work goes.

## 1. The handoff gets fast, and stays careful (29 October 2026)

![From a worker's done to the main reading it: before, a 30 second linger and a host engine turn; after, classify first and wake the main at once, absorbing the trailing turn-end only on proof](media/handoff-timeline.svg)

The question that started it:

> investigate if we can make sub agent handover a bit faster ... as a sub agent finishes first mate is able to like just read the output ... it's a sort of pub sub um one step after the other kind of speed
>
> — 29 October 2026

A read-only design pass timed the path from a worker's `done` line to the main being woken at 45 to 48 seconds.
Almost all of it was two waits: a fixed 30 second linger in the watcher, and a supervision-host engine turn that, for a finished worker, always handed the wake back to the main anyway.

He asked that the linger's author be read carefully before anything was removed:

> we would want to really try to understand the intention of the author because he designs things very carefully

The linger exists so that a worker's final status write and the same turn's turn-end hook, which land seconds apart, cost one main turn rather than two.
A second scout checked whether that trailing turn-end could ever carry a problem.
It cannot: it is an empty file whose only content is its timestamp, and a turn that fails never touches it.
But one real case in this home's own logs would have been hidden by a blind absorb: a worker that took on follow-up work after its `done`, whose only sign of finishing was that turn-end.

The principle he set:

> I think the optimal design here would be if something is over the line, like 80% of the time let's say then we do we there is a good enough argument to start taking action at that point but then there must be the ability for us to recover if the second event is also consequential. And if we can do both of these things, I would say we've strictly improved the system.

And on cleanup:

> Yeah, absolutely. I was thinking about this too. Act early but don't clean up until it's fully finished.

What was built, in his fork:

- The watcher classifies a new status span first. A `done`, `failed`, `needs-decision`, or `blocked` closes the cycle at once, with no linger. A `working:` note keeps the linger, where coalescing still saves a turn.
- At that moment the watcher records which turn wrote the event: the T3 run that was active, or the Claude busy record's sequence on a pane backend.
  The trailing turn-end is absorbed only when that proof holds end to end: same turn, ended cleanly, no status bytes and no steer since, and the worker's current state agrees.
  Anything unproven wakes the main exactly as a bare turn-end did before.
- A run that ends failed, interrupted, or cancelled after a surfaced `done` now wakes the main once, naming the task and the status, with T3's error message when it is readable.
  Nothing reported that before.
- A finished worker's wake goes straight to the main while the captain is present, instead of through the host's engine turn; the host keeps the routine and stale wakes.
- The cycle's wait now ends on the worker's own append, on every backend, so the poll interval is the backstop rather than the latency.
- Cleanup does not act early: before closing a T3 thread, teardown waits up to 30 seconds for a still-running turn to end, and refuses rather than interrupting it, unless forced.

The evidence is the regression suites, run under Bash 3.2 on the day of landing: the watcher, T3 backend, T3 client, branch dispatcher, away daemon, and supervision host suites, with new cases for every shape the scout listed.
The live measurement against the running home was deliberately left to Firstmate after landing, so no number from a real finish is claimed here yet.

## 2. Crew cards read like the work, not like the record (29 October 2026)

![A mockup of T3's sidebar crew cards: today each card reads fm-life-archive over fm-life-archive-calendar-month; after, the folder name over the backlog item's own title](media/crew-card-titles-mockup.png)

The ask, looking at the crew cards in T3's sidebar:

> I would like to get to a point, aesthetically speaking, where the first line is just the project that it's working on and then the second line is just the description without the machine readable names.
>
> (29 October 2026)

A scout traced both lines: the first is the T3 project's title, which Firstmate set to `fm-<folder>`, and the second is the thread's title, which was the task id.
The `fm-` prefix was doing real work in T3, though: the sidebar used it to tell Firstmate's crew apart from his own threads.
So the scout proposed three steps: teach his T3 fork to recognise crew by the client that launched them, give new projects and threads human titles, and retitle the existing projects.
His call:

> Um we can just do one and two of the recommended plan.

This entry is step two, the Firstmate half:

- A new T3 project is titled with the folder name, so its card reads `life-archive` and its monogram `LA`.
  Projects already in T3 keep the titles they have; retitling them was step three, which he left out, so today's `fm-life-archive` card stays as it is.
- A worker's thread is titled with its backlog item's title, cut to 96 characters with an ellipsis.
  When there is no item to read, it falls back to the old `fm-<id>`, and a second mate always keeps its `fm-<id>` title.
- The task id did not go anywhere: Firstmate's own record, cleanup, steering, and restart recovery still key on `fm-<id>` and the thread id, never on the title, so a title is only ever a label.
- A side effect worth knowing: the item title is now what he reads on the card, so short titles read best and the detail belongs in the item's notes.

This lands after the fork side is installed, because until the fork recognises crew by their launching client, a card without the `fm-` title would fall out of the crew tree.
The picture above is the scout's mockup, not a screenshot: no worker has launched with these titles yet.
The evidence is the T3 backend suite with new cases for the backlog title (quotes and accented text decoded, the 96-character cut, the fallback) and for a spawn whose thread carries that title while its record still reads `window=fm-<id>`.

## 3. Any agent can be a T3 worker, not only Claude and Codex (31 October 2026)

![Per fact, Firstmate picks the thread channel on the fork's T3, the Claude or Codex folder files on upstream T3, or a refusal before anything is leased](media/t3-any-agent-channels.svg)

The ask:

> so far we only support Codex or Claude, right? We should really be able to support orchestration across any agent. Neither Firstmate or T three code s themselves stop this. So we have to figure out w why it's stopping us and what we can do to change that.
>
> Any agent build, yeah, let's go the full path

The investigation found the limit was Firstmate's own: three hard refusals, and under them folder-file tricks that only Claude and Codex read, standing in for a per-thread environment and per-thread instructions that T3 did not have.
"The full path" is two changes: the fork's T3 gains those two per-thread fields, and Firstmate switches to them.
This entry is the Firstmate half:

- One adapter table now decides which harnesses T3 can run: claude, codex, grok, pi, muse, opencode, agy, cursor, and the ACP-registry gemini, kimi, and devin, each with its T3 driver, default instance, and effort option.
- Where the T3 instance advertises the new fields, the worker's environment and its "the brief is first-party" statement ride the thread launch, for every harness, and Firstmate reads them back to prove they bound.
  Upstream T3 keeps today's Claude and Codex folder files; any other harness there is refused rather than launched half-wired.
- An instance that cannot run full-access is refused, and so is a thread T3 says it runs lower, because such a worker would stall on approvals Firstmate cannot answer.
- No pane-style hook files are written for the new harnesses, global ones such as Grok's included; T3's own thread status already tells Firstmate when a worker is busy or done.
- Teardown now uses T3's Stop, so a worker's own delegated T3 tasks stop with it instead of running on in a returned slot.
- A Codex ship on an external review forge is refused, not just warned, when its push guard could be ignored.

Nothing has run live yet: the evidence is the T3 backend and helper suites against the fake T3, with new cases for a Grok worker with no hook files, a server with and without the new fields, a downgraded instance, and a worker that owns a running child.
The first live proof is one cheap Grok scout once the fork's half is installed.
