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

## 4. One picture per fork feature, and a README that says less (31 October 2026)

![Worker cards in T3's sidebar: before, fm-recipe-box over fm-recipe-box-print-view; after, recipe-box over Print view for one recipe](../docs/media/fork/readable-crew-titles.png)

The ask, pointing at the instant-handoff chart:

> this is like super tight like one picture um super succinct no no garbage no no filler ... if we can produce a picture like this or a picture for every fork that would be great
>
> I also want each fork repo to get a full-blown fork.md ... which then frees up the the fork features in the main readme to be as simple as possible, like just dead simple.
>
> (31 October 2026)

What was built:

- `FORK.md` at the repository root, one section per fork feature: what it does, why, and a picture where one shows it.
- Three features got a picture: the instant-handoff chart, the readable crew titles above as a before and after, and one crew with Claude, Codex, Grok, and Pi workers side by side.
- Server-restart recovery, the full-access and clean-stop rule, and T3 0.1.3 support have nothing visible to show, so they have none.
- The README's fork section went from six long bullets to five short lines and a link to `FORK.md`.

The choices worth knowing:

- Both T3 pictures are real screenshots, not mockups, taken from the installed fork T3 run as three throwaway servers with made-up projects (`recipe-box`, `trail-notes`, `budget-sheet`) and idle worker threads launched by Firstmate's own T3 client.
  No prompt was sent, so no model was paid for, and nothing from his real T3 appears.
- Both are framed like the handoff chart: one title stating the result, one headline, the picture, a one-line source.
- The pictures live once, under `docs/media/fork/`, and this entry links to them rather than keeping a second copy.

## 4. The common set: every agent both sides already run (31 October 2026)

![Of the 11 agents Firstmate has and this T3 fork can run, four passed live today; this change readies Cursor, Gemini, Kimi, and Devin on the Firstmate side, OpenCode waits on the fork, and the rest wait on setup](media/t3-common-set.svg)

The ask, and the correction a moment later:

> Yeah, we just wanna support every like we wanna support the union set between First Mate and T three code
>
> Actually I don't know if it's a union set, but it's more like the common set
>
> (31 October 2026)

That is 11 agents.
Claude, Codex, Grok, and Pi already pass live as Firstmate workers in T3: each scout read its own task id from its environment, saw its brief as first-party, finished, and was cleaned up.
OpenCode and T3's own Cursor driver were refused, because neither can give a thread its own environment.

This entry is the Firstmate half of the plan:

- Cursor now runs as the ACP registry's `cursor` agent (`cursor-agent acp`), which T3 starts as one process per thread with that thread's environment.
  T3's in-process Cursor driver could only ever be refused.
- An ACP registry worker (Cursor, Gemini, Kimi, Devin) runs on whichever T3 instance reports that agent, whatever T3 named it.
  T3 names a new one after the agent, such as `acpRegistry_gemini_cli`, which the old table would have refused every time.
  An explicit instance mapping still wins, and two instances of one agent are refused rather than guessed.
- A Gemini thread trusts its workspace through its environment, as the pane launch already does.
- A model outside the short list T3 shows for an instance is now looked up in T3's full catalog before it is refused.
  That is the bug today's live checks hit with Codex `gpt-5.6-luna` and OpenCode `kimi-code/k3`.

The evidence is the T3 helper and backend suites against the fake T3.
The new cases cover a registry instance found by agent, the none and two-of-one-agent refusals, Cursor refusing T3's in-process driver, a Gemini spawn carrying the trust variable, and an omitted model found by search but a near-miss slug refused.
Today's four live passes are now in the verification record.
The remaining agents need the fork's OpenCode change or the captain's setup first, then one cheap live scout each.

## 6. A worker's approval comes to Firstmate, not to the captain (31 October 2026)

![A worker's approval request wakes Firstmate with the command; Firstmate allows, denies with feedback, or asks the captain as its own decision](media/t3-worker-approvals.svg)

The ask:

> I mean if it needs my core, it needs my core, you know, like you should be able to escalate like the the worker should be able to escalate that issue to you and if you can't resolve it and it genuinely needs my call then you will present that decision as opposed to the worker presenting it like you should still be able to like kill it at the worker level or whatever you need to do and then represent the decision as you because the principle of first mate is I never need to interact with workers.

Even at full access, Claude still stops for some commands, such as `python3 - <<EOF`, and T3 shows that request only in its own window.
Firstmate could see that something was pending but could not answer it, so the worker waited for the captain to click.
The fork's T3 is gaining a way to answer these over Firstmate's connection; this entry is the Firstmate half:

- When a worker parks on an approval, Firstmate is woken at once with the request id, the command or file, the provider's reason, and whether a provider check or one of the captain's ask rules caused it.
- `bin/fm-t3-approve.sh` allows or denies it, with feedback the worker sees on a deny, and records every decision in the task's own record.
- The rule Firstmate follows: allow what stays inside the task and its own copy; deny with feedback, and steer or interrupt, what does not; only a call that genuinely needs the captain reaches the captain, asked as Firstmate's own decision, never as "go click in the worker's window".
- On a T3 without the new feature the helper refuses, and Firstmate interrupts and steers the worker instead, which also ends the wait without the captain.

The evidence is the T3 helper and backend suites against the fake T3, with new cases for an approval waking Firstmate with its command, an allow, a deny with feedback, an already-answered approval, and a T3 without the feature.
Nothing has run live yet; the first live proof is one approval on a worker once the fork's half is installed.

## 7. Crew threads name their coordinator (31 October 2026)

![The main thread with a worker and a secondmate as its crew, and the secondmate's worker as the secondmate's crew, replacing the old guesses from folder names and fm- titles](media/t3-crew-lineage.svg)

The ask:

> I want you to kind of go over my changes for T3 code and first mate like our fork changes ... think about the direction or the architecture or the approach ... whether or not it could be done sort of more elegantly because we've kind of like bolted on layers after layers of sort of changes ...

The architecture review found one place where the seam was wrong: T3's sidebar found Firstmate's main and crew by guessing from the folder name, the newest thread without a worktree, and `fm-` titles, and each Firstmate title change broke it.
Its first recommendation was one recorded field instead: each thread names the thread it works for when it is launched.
This entry is the Firstmate half; the fork's T3 is gaining the field in parallel.

- Every thread Firstmate launches in T3 names the thread running the Firstmate that spawned it: a worker under the main or under its secondmate, and a secondmate under the main.
- The parent is sent only where T3 offers the field, and a thread that does not read back as crew of exactly that parent is archived and refused, like any other wrong binding.
- On a T3 without the field, when Firstmate is not running in T3, or when the home has several live threads, the thread launches as before with no parent, so nothing stops working.
- The optional step of pinning the main at session start was left out: it would add a network call to every session start for a purely visual gain.

The evidence is the T3 helper suite (45 passing, with a new case for a parent bound, a wrong lineage, a wrong parent, an unknown parent, and a T3 without the field) and the T3 backend suite (119 passing, with new spawn cases for the home's main, an explicit target, an older T3, and a home with two live threads).
Nothing has run live yet; the first live proof is one spawn once the fork's T3 half is installed.

## 8. T3 wakes the main after a restart, so the outside nudge goes (31 October 2026)

![The coordinator thread in a probe T3 after a restart: one note from T3 Code saying when the server restarted, which crew thread had its run cut, and to run session start](media/t3-restart-note.png)

The ask:

> I want you to kind of go over my changes for T3 code and first mate like our fork changes ... think about the direction or the architecture or the approach ... whether or not it could be done sort of more elegantly because we've kind of like bolted on layers after layers of sort of changes ...

A T3 restart ends the main's session along with every worker's, and nothing inside a dead session can wake it.
Until now a launchd job outside T3 polled the server every 30 seconds and sent the main one message per restart.
The architecture review's second recommendation was to let T3, which knows when it starts, say so itself; the fork's T3 now sends each thread with crew one note per server start (picture above, from that task's live probe).
This entry is the Firstmate half: the outside job, its launchd template, its records, its install and uninstall commands, and their docs are gone.

- The main's restart reminder is kept, against the review's plan to delete it.
  T3 skips the note for a main whose own turn the restart cut, and wakes it with "Continue where you left off." instead, which says nothing about session start; the reminder, which denies the first tool call while the lock names a dead process, is the only thing that sends that main to session start.
  The deletion is kept aside as a patch in case the captain wants it anyway.
- The credential guard in the same hook is unchanged, and `bin/fm-t3-restart.sh recover` still steers the interrupted workers once session start runs.
- The launchd job already installed on this Mac is left running until this lands; it is removed by hand afterwards.

The evidence is the T3 helper, away-daemon, turn-end guard, and T3 backend suites (44, 156, 91, and 113 passing), the linters, and the documentation check.
The note only reaches a main whose workers are recorded as its crew, which needs entry 7's Firstmate half to have landed.

## 9. A worker's approval wakes Firstmate even with Herdr workers in the home (31 October 2026)

![Before: two parked Herdr workers took the watcher's fast wait, so a T3 worker's prompt sat for about 9 minutes until a generic quiet-worker alert; after: every cycle reads the T3 workers' prompts first, and Firstmate is woken within 15 seconds with the command](media/t3-approval-wake-beside-herdr.svg)

The morning after entry 6 landed, a T3 worker hit a Claude safety check on an `rm` and sat on it for about 9 minutes; Firstmate only noticed through the general "worker has gone quiet" alert, without the command.
Asked whether to find out why and fix it with a test, the captain said:

> Yeah, investigate.

The cause was in Firstmate, not T3.
Entry 6's wake rides the watcher's T3 wait, and the watcher gave that wait to T3 only when no Herdr worker was recorded, so Herdr's own fast path was never slowed.
This home still records two parked Herdr workers, so no T3 worker's prompt was ever read; the old notes said T3 workers "stay on the poll loop", but the poll loop has no way to see a prompt.
The thread id and the installed T3 were both fine: the live T3 read the worker under its recorded id and lists approvals.

- Each cycle that waits on Herdr or Rex now first reads every T3 worker's pending prompts once, without waiting; against the live T3 that read takes 0.1 seconds for this home's five T3 workers.
- A prompt found there wakes Firstmate exactly as in a T3-only home: once per prompt, with the command, the reason, and how to decide it.
- Herdr keeps its wait, so nothing about Herdr workers changes.

The evidence is a new regression that adds one Herdr worker beside a T3 worker with a pending `rm` approval: it fails on the old watcher (no wake) and passes now (a wake on the first cycle, never repeated, Herdr's wait still run).
Replaying the watcher against copies of this home's live task records showed the same thing: before, only the two Herdr workers were handed to the wait; after, all five T3 workers are read first.

## 10. A quiet T3 restart wakes Firstmate too (31 October 2026)

![Before: T3 restarted at 09:47Z with no worker running, no note was sent, and Firstmate slept until the captain wrote at 10:18Z; after: each session start pins Firstmate's own thread, and T3 sends it one note after any restart](media/t3-quiet-restart-pin.svg)

Entry 8 moved the restart wake into T3, but its note only goes to a main whose crew had a run cut by the restart.
On 31 October T3 restarted at 09:47Z with nothing running, so no note went out, and the outside poller entry 8 removed could no longer cover it; Firstmate stayed asleep until the captain wrote at 10:18Z.
Firstmate proposed having T3 also send the main a short note after any restart, with a test, and the captain said:

> Yeah, go ahead on your proposed fix of send the main session a short note.

The fix has two halves built side by side, against one agreed interface: a thread can be pinned as its project's coordinator, and after every server start T3 sends each pinned coordinator exactly one note, listing any cut crew runs or saying in one line that there were none.
This is the Firstmate half:

- Every session start now pins this home's own T3 thread as its project's coordinator, the same thread the away daemon finds (the one live, worktree-less thread running in the home), so a secondmate pins its own thread too.
- It only does so when T3 says it supports the pin; an older T3 is asked nothing more, and nothing is printed.
- Pinning again each session start is harmless, and a pin that cannot be made (no thread found, two candidates, T3 unreachable) never stops session start.

The evidence is new fake-server cases for the pin (pinned and read back, an earlier coordinator unpinned, repeated, skipped on a T3 without the feature) and for session start's restart recovery (silent, repeated, skipped when the home's thread is ambiguous or T3 lacks the feature), which fails without the pin; the T3 helper and T3 backend suites pass (47 and 119), along with the linters and the documentation check.
The quiet-restart note only arrives once the T3 half lands in the fork.

## 11. Firstmate needs the T3 Code fork, and the stock-T3 fallback is gone (31 October 2026)

![Before: the fork's thread launch for every agent, plus a folder-file fallback for Claude and Codex on stock T3. After: the thread launch only, and stock T3 refused for every agent](media/t3-fork-only.svg)

The question from the architecture review, and the answer:

> FirstMate: tie FirstMate to the T3 fork and drop the stock-T3 fallback?
>
> Yeah, we can tie it. We can drop the stock T three fallback
>
> (31 October 2026)

On a T3 without per-thread environment and instructions, Firstmate used to write a worker's environment and its "the brief is first-party" statement into files in its folder: Claude's local settings and a `CLAUDE.local.md`, and for Codex an overlay on `.codex/config.toml` with a private Git journal to restore it, guarded by a Codex trust check.
This fork only ever talks to the captain's T3 fork, which has both, so all of that was dead weight.

What changed:

- A T3 whose agent does not offer both per-thread settings is now refused for every agent, Claude and Codex included, workers and secondmates alike, before anything is leased, with a message that names the T3 Code fork as the fix.
- The folder-file writers, the Codex overlay script, the Codex trust check, and the refusals that protected a project's own `CLAUDE.local.md` and Codex config are deleted, along with their cleanup in teardown and in an aborted spawn.
- A secondmate's home now only gets the credential link, so that link is all its cleanup removes.
- About 375 lines of scripts went (the 161-line Codex overlay script among them), and the tests shrank by about 350 lines while keeping coverage: each fallback test became a check that stock T3 is refused, or that a project's own `CLAUDE.local.md` and Codex config are left exactly as found.

The trade-off, accepted: this fork can no longer run workers on stock T3 at all, and upstream Firstmate changes that touch the deleted lines will conflict when merged in.

The evidence is the T3 backend suite (108 passing), the T3 helper suite (45), the away-daemon suite (156), and the teardown safety suite (22), plus lint and the docs check.
The live check, a Claude and a Codex worker spawned on the fork's T3 still binding their environment and statement, is left to Firstmate.

## 12. No more false "telemetry is on" warning (1 November 2026)

> Sure assume default telemetry off

Every T3 spawn and control action checks whether the T3 server counts worker turns, and it treated a server without `T3CODE_TELEMETRY_ENABLED` as telemetry on, which was right for stock T3.
The captain's T3 fork defaults telemetry off, so the live server, with the setting simply absent, drew a false warning on every action.

Now an absent setting reads off; an explicit `true` (or any value other than false, 0, no or off) still reads on and warns, and a server whose process cannot be read still warns as unknown.
The evidence is the T3 helper suite, with the default case now expecting off and no warning and a new case expecting on plus the warning for a server started with telemetry enabled.

## 13. A worker's permission prompt reaches Firstmate in about a second, and Firstmate can answer it (3 November 2026)

![Before: the watcher's wait missed a worker's permission prompt and woke on its timer 10.8 seconds later, unable to see what was asked. After: it woke 0.6 seconds after the prompt, naming the command, and the prompt could be allowed or denied directly](media/t3-approval-instant.svg)

The question:

> I noticed that when a crewmate has an approval pending first mate does not pick up the approval instantly. Can you check if the approval handoff is the same as the done handoff where it's instant like pub sub style or is it running on some sort of poll timer?

It was a timer.
A worker's status line ends the watcher's wait at once, but a permission prompt was only looked for when each wait began, so one that appeared mid-wait sat until the wait ran out, up to 15 seconds.
And once seen, Firstmate could not answer it: the T3 Code fork lists approvals in a field Firstmate never read, so Firstmate saw "one approval pending" with nothing to approve, and had to interrupt the worker and steer it instead.

Of the three fixes offered, his answer:

> Yeah, you should do all three if you believe the third one is the right move. At least do one two. But do three as well if you believe it.

The third, telling workers to avoid commands that trigger prompts, was done separately in this home's own brief additions.
This entry is the first two:

- Firstmate now reads the fork's approval list correctly, so it names each pending prompt with what it asks for, and allows or denies it directly.
- The watcher's wait now also checks for new questions and prompts about once a second, so one that appears mid-wait wakes Firstmate within about a second, the same way as before, once per prompt.

The choice made: this is a fast check, not true push.
T3 gives Firstmate's connection no signal when a prompt opens: its thread wait ends only when a run finishes, and its live event stream refuses this kind of sign-in.
A once-a-second read of a local server is cheap, and the old timer stays as the backstop.
True push would need a change to the fork, letting its thread wait also end when a prompt opens; that is left as a follow-up rather than done here.

What is still not instant: while Firstmate is in the middle of its own turn, nothing waits on workers at all, so a prompt raised then is picked up when that turn ends, as before.

The evidence is live, against the fork on 3 November 2026, with a scratch Claude thread told to run `touch` in a scratch project: before the fix the wait missed the prompt and ran out 10.8 seconds after it appeared, and the list came back empty; after, the wait woke 0.6 seconds after the prompt, naming `touch approval-probe-after.txt`, one prompt was allowed and its file appeared, and another was denied with a note and its file never did.
The T3 client and T3 backend suites cover the new check and the corrected list.

## 14. Approvals reach Firstmate by push, and idle workers cost the server nothing (3 November 2026)

![T3 Code's server load while Firstmate watches one waiting worker: 3.5% of a core with nothing extra watching, 5.4% with the once-a-second re-read, 3.6% with the fork's push; the prompt still wakes Firstmate 41 ms after it appears](media/t3-approval-push.svg)

His word on it:

> Earlier today we were discussing this and let's go with your recommendation here.

The recommendation was true push.
Entry 13 made a worker's permission prompt wake Firstmate within about a second by re-reading every watched worker's pending requests once a second.
Each of those reads cost T3 Code's server real work, so every watched worker kept part of a core busy, more with each worker, even while they all sat idle.
The fork's half landed first: its thread wait, which Firstmate already holds open on each running worker, can now also end the moment a question or prompt appears, and hands back what is pending.

What was built, in Firstmate:

- Firstmate's wait asks the fork to end on a new question or prompt, telling it which ones Firstmate has already reported, so a reported prompt never wakes it twice.
- When the fork ends the wait on one, Firstmate reports it from what the fork handed back, with no second read.
- The once-a-second re-read is gone. The 15-second check stays as the backstop.

The choice made: no fallback for an older T3.
Firstmate already requires the T3 Code fork, so on a T3 without the new wait it simply sees a new prompt at its next 15-second check, and `status` warns rather than quietly keeping the old loop.
One honest gap: a worker that is idle when the wait begins and starts a new turn during it is first seen at the next check, within 15 seconds, because there is no running turn to wait on yet.

The evidence is live, against the installed fork on 3 November 2026, with a throwaway Claude thread in a scratch project told to run `touch` under a rule that makes it ask: the prompt woke Firstmate 41 ms after it appeared, naming the command; and with the worker sitting on an already-reported prompt, the server's load was 3.6% of a core with the new wait against 5.4% with the old re-read and 3.5% with nothing extra watching.
The scratch threads and project were deleted afterwards.
The T3 client and T3 backend suites cover the push, the already-known prompt, run end, the time limit, and an older T3 without it.

## 15. The fast handoff now comes from upstream (4 November 2026)

![From a T3 worker's done to Firstmate waking: a Claude worker took 2 s before and 4-5 s after; a Codex or Grok worker took 2 s before and 35 s after](media/handoff-upstream-7648.svg)

His words, on hearing upstream was already fixing the same pause:

> Oh okay. I mean if upstream's already fixing it then yeah we don't need to worry about that. Um if it's simpler than ours, in that it's more elegant, we should try to adopt theirs and then fit our pieces around that. The standing rule would be to maintain minimum but necessary deviation from And maybe also add in the cause that's like especially if it's upstream is more elegant. But even if it's not more elegant, I should be notified about that and I can make a decision.

Upstream's open pull request [#7648](https://github.com/kunchenguid/firstmate/pull/7648) fixes the 30-second pause from entry 1 in 4 files instead of 21.
The pause becomes a limit rather than a fixed wait: it ends as soon as the worker's turn-end arrives after its status line, so the pair still costs one wake.

What changed in his fork:

- #7648 is merged in as its author wrote it, ahead of upstream merging it; the next upstream sync reconciles it.
- Entry 1's own machinery is gone: the record of which turn wrote a status, the proof checks, the report of a turn that ends badly after `done`, the state-folder watch, and cleanup's wait for a running turn.
  The watcher's difference from upstream went from about 490 added lines to about 55.
- Kept, because #7648 does not touch them: a finished worker's `done` still goes straight to Firstmate instead of through the supervision host's extra turn, and a T3 worker's question or approval still wakes Firstmate at once.

The part he asked to hear about: upstream's version is not better for every worker.
#7648 waits for the worker's turn-end marker, and on T3 Code only Claude writes one.
A Claude worker now reaches Firstmate 2-3 seconds after its turn ends, a little slower than before.
A Codex or Grok worker, this home's computer-use and probe lanes, now waits out the full 30-second pause again.
The option, if he wants it: a small T3-only addition that marks a worker's turn-end when Firstmate's T3 wait sees its run finish, which would bring those workers back to a few seconds for most finishes.

The evidence is the watcher, signal-grace, T3 backend, T3 client, supervision host, supervision events, turn-end, away daemon, branch dispatcher, and cleanup suites, all passing, including the poll-only-home case that the fork's own state-folder watch had been failing.
The timings come from scratch runs of the real watcher at its default settings against the fake T3 server, with the worker's turn ending 2 seconds after its `done`: before, both workers woke Firstmate in 2 seconds; after, a Claude worker took 4-5 seconds and a Codex worker 35.

## 16. Waiting for captain, on the card (4 November 2026)

![A worker's card through its life: Working, then Waiting for captain ahead of its title while only the captain can unblock it, then its plain title again once he answers](media/waiting-for-captain-card.svg)

An illustration of the card, not a screenshot: a browser pointed at the live T3 needs a pairing token, and minting one for a picture was not worth it.

His words:

> I imagine how it works is when a worker finishes, it will say done, and then first mate picks it up immediately, and then the done will either either disappear and turn into working again if first mate like tell it to risk to to act or um it can also say waiting for captain, which is where first mate has determined that okay, only a cap a captain is needed to unblock this.

> Yep, perfect. Okay. We're aligned. We're aligned on waiting for captain as well

What was built, in Firstmate alone, with no change to the T3 Code fork:

- When a captain hold is open on a live T3 worker, its thread title reads `Waiting for captain · <title>`. It goes when the hold ends, and when the worker is cleaned up.
- The title is rewritten from the thread's live title, so nothing keeps a copy that could go stale.
- A rename that fails, or meets a stopped T3, never fails the hold or the answer. A small record stays until the title is proven, and the watcher repairs it within about a minute.

The choices made:

- **The trigger is the captain hold, and only that.** The hold can be on the worker's own task or on a task with `--origin` naming the worker. A worker's `needs-decision` line does not count, since Firstmate settles most of those itself. A question a live worker is parked on is covered by Firstmate holding it as it escalates, which is already the rule, so there is no new status word or worker protocol.
- **A hold with no running worker changes nothing,** because there is no card to label.
- **Cleanup restores the title even while the hold stays open,** so an archived thread reads as the work.

The half that could not be done here: Done still clears only when the card is opened.
T3 clears it through a visit, and the visit command is only reachable from T3's own client: no tool Firstmate can call sends it, `t3_thread_organize` offers `mark_unread` and no opposite, and T3 refuses a Firstmate sign-in anywhere but its tool endpoint.
So a waiting card can read Done beside the new title until it is opened.
It needs one small fork change: a `mark_read` action on `t3_thread_organize` that sends the visit command.
With that, Firstmate marks the thread seen when it reads a worker's report.

The evidence is two throwaway threads on the live T3, a parent and a crew card, renamed through the same tool Firstmate calls.
The label landed mid-run and stayed when the run ended, the thread still read as crew of the same parent, and the title restored and relabelled cleanly on the finished thread.
A rename on an archived thread also works, which is why an archived thread always loses the label.
Firstmate's own rename command ran only against the fake T3 server, with the hold, answer, cleanup, watcher, and capability suites, because this worker had no sign-in for the live one.

## 17. Every check-in opens with the high level objectives (5 November 2026)

![A Bearings digest with made-up objectives: a High level objectives block sits above Captain's Call and the other three sections](media/objectives-in-bearings.svg)

The ask:

> I also want a Hoi or Bearings to announce our like high level objectives which I think you called it directions, although I'm not even sure why you called it directions. But yeah, I'm just gonna refer to it as our high level objectives. Um, which is kind of a good thing to just be reminded of anytime we're getting our bearings or any time we're checking in on what's happening.

What was built:

- One small reader, `bin/fm-objectives.sh`, returns the bullets under `## High level objectives` in this home's private `data/OBJECTIVES.md`. A missing file or section means none, and no error.
- Bearings gets them as an `objectives` field and opens every digest and file report with one short line each, above the four sections.
- A normal `/ahoy` recap opens with the same block. It may run that one reader and still nothing else. When `/ahoy` falls back to Bearings, the objectives arrive through Bearings, so they are not printed twice.

The choices made:

- **The block is not a fifth section.** The four sections always render, and an empty one says so. A home with no objectives has nothing to report, so the block is simply left out.
- **The chat shortens, the reader does not.** The field carries each objective's full text, and the chat writes the short line.
- **The Bearings board is unchanged.** The chat digest beside it carries the objectives.
- **One name throughout.** Tracked text says "high level objectives", and the captain approved renaming the private file to match, so it is now `data/OBJECTIVES.md`.

The evidence is the Bearings snapshot suite, with new cases for objectives present, section missing, and file missing, all using made-up objectives. The present case also plants lookalike bullets above and below the section, because the real file has one above it.
The skill wording itself has no automated test, so the first real `/bearings` and `/ahoy` after landing are its proof.
