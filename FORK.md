# What this fork adds

This fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) regularly merges upstream's `main` and carries the changes below on top.
Each section says what the change does and why, with a picture where one shows it.
The [README](README.md) keeps a one-line summary of each, and the [devlog](devlog/index.md) tells how each came about.

## Instant handoff

![Instant handoff: the median wait from a worker finishing to FirstMate being notified fell from 38 s to 3.5 s](docs/media/fork/instant-handoff.png)

When a worker reports that it is done, failed, blocked, or needs a decision, FirstMate hears about it within a few seconds of the worker's turn ending, for any agent that marks that end.
Before, every finish waited out a fixed 30-second pause, so a finished worker typically sat unnoticed for 38 seconds.
That pause existed so a worker's last status line and the end of the same turn would cost FirstMate one wake instead of two.
The pause now ends as soon as that turn's end arrives, so the pair still costs one wake.
That part is upstream's own fix, [#7648](https://github.com/kunchenguid/firstmate/pull/7648), which this fork carries ahead of its merge upstream; the next upstream sync reconciles it once #7648 merges or changes.
On T3 Code only Claude marks it, so a Codex, Grok, or other T3 Code worker still waits out the full pause.
A worker's `done` or `failed` also goes straight to FirstMate's own session instead of through the supervision host's extra turn first, which is this fork's part.
Routine `working:` notes keep the pause, where it still saves a wake.
The chart was measured on the fork's earlier version of this change, which #7648 replaced.
Details: [`FM_SIGNAL_GRACE`](docs/configuration.md#environment-variables) and [decision-owned rows](docs/pi-supervision-branch.md#decision-owned-rows).

## Any T3 Code agent can be a worker

![One FirstMate crew in the T3 Code sidebar with Claude, Codex, Grok, and Pi workers](docs/media/fork/any-agent-workers.png)

On the T3 Code backend, FirstMate used to run only Claude and Codex workers.
Every worker needs its own environment and a note that its instructions really come from FirstMate, and only Claude and Codex could be given those through files in their folder.
Where a T3 Code build supports per-thread environment and instructions, FirstMate now sends both with the thread itself and reads them back to prove they took.
That opens the backend to every agent whose T3 Code driver takes those settings.
Claude, Codex, Grok, and Pi are verified live.
Muse and Antigravity run on their own T3 Code drivers, and Cursor, Gemini, Kimi, and Devin go through the ACP registry, found by agent; those are covered by the test suites only.
OpenCode 2 is refused, because its one shared server gives a thread no environment of its own.
FirstMate now requires the T3 Code fork, which has those settings: a T3 Code without them is refused for every agent, Claude and Codex included, before anything starts, and the folder files are gone.
A model and an effort are checked against T3 Code's own list for that agent before anything starts, and an effort the model does not offer is refused, never swapped for the nearest one.
Details: [worker environment](docs/t3code-backend.md#worker-environment-and-channel-statement) and [provider instances and models](docs/t3code-backend.md#provider-instances-and-models).

## Workers listed as FirstMate's crew

Each thread FirstMate launches names the FirstMate thread that started it as its parent, so T3 Code lists it as that thread's crew, as in the picture above.
A worker sits under the FirstMate or second mate that spawned it, and a second mate sits under the main FirstMate.
T3 Code used to guess the crew from folder names and `fm-` titles; now the grouping comes from a recorded field.
A thread that does not read back as crew of exactly that parent is archived and refused.
A T3 Code without crew lineage, a FirstMate not running in T3 Code, or a home with several live threads launches the thread with no parent, which changes only the grouping.
Details: [task shape](docs/t3code-backend.md#task-shape-and-metadata).

## Readable project and task titles

![Worker cards before, fm-recipe-box over fm-recipe-box-print-view, and after, recipe-box over Print view for one recipe](docs/media/fork/readable-crew-titles.png)

A new T3 Code project is titled with its folder name instead of `fm-<folder>`, and a worker's thread is titled with its task's title instead of an internal id.
The worker cards in T3 Code's sidebar then read as the project and the work.
Task titles are cut to 96 characters, so short titles read best.
Projects already in T3 Code keep their old titles, and FirstMate's own records still track each worker by its id, never by the title.
Details: [task lifecycle](docs/t3code-backend.md#current-lifecycle-and-safety).

## Full access and a clean stop

A T3 Code worker is refused unless it runs with full access, because a worker stuck waiting on an approval FirstMate cannot give would stall silently.
A setting T3 Code cannot honour, such as a narrower permission mode or a tool exclusion list, is refused the same way, before anything starts.
Cleanup uses T3 Code's own Stop, which also stops any tasks the worker started itself, instead of leaving them running after the worker is gone.
Details: [task lifecycle](docs/t3code-backend.md#current-lifecycle-and-safety).

## Approvals reach FirstMate at once

![A worker's approval reaches FirstMate in 41 ms instead of 10.8 s, measured from the prompt appearing to FirstMate's wait ending](docs/media/fork/approval-at-once.png)

When a T3 Code worker stops on a question or a permission approval anyway, FirstMate hears about it at once instead of at the end of its next 15-second wait.
FirstMate can then allow or deny the approval itself, from its own session, instead of interrupting the worker and steering it again.
The T3 Code fork's wait ends the moment a request appears, so FirstMate no longer re-reads idle workers every second, and the 15-second check stays as the backstop.
In a home that also runs Herdr or Rex workers, that other backend keeps the wait, and each 15-second cycle reads the T3 Code workers' requests first, so one still wakes FirstMate within that time.
Details: [push events and polling fallback](docs/t3code-backend.md#push-events-and-polling-fallback).

## Waiting for captain and Testing on the worker's card

![FirstMate's crew in the T3 Code sidebar: one worker's card reads Waiting for captain, another reads Testing, and a third shows only its age, each with a plain title](docs/media/fork/worker-card-status.png)

T3 Code knows when a worker's turn ended, but only FirstMate knows that a worker now needs the captain or sits in a no-mistakes run.
FirstMate says so in the status spot on the worker's card, and the title stays as it is.
When FirstMate decides that only the captain can unblock a live worker, the card reads Waiting for captain.
A worker's own question does not set it, because FirstMate settles most of those itself.
While a worker's no-mistakes run is active, the card reads Testing, and Waiting for captain wins when both apply.
The words go when the wait or the run ends, and when the worker is cleaned up.
Only T3 Code workers show this, and it needs a T3 Code with the crew card status; on an older one the card shows neither word and nothing else changes.
A failed update is retried, so the card comes right within about a minute, and Testing can take that long to appear or go.
Upstream now reports worker status to terminals that understand it ([#8011](https://github.com/kunchenguid/firstmate/pull/8011), [`fm-osc7501.sh`](bin/fm-osc7501.sh)), including a blocked state for a captain hold, but it never runs on T3 Code, so the two do not meet.
Details: [crew card status](docs/t3code-backend.md#crew-card-status).

## Priorities and high level objectives in every check-in

![A Bearings digest with made-up lists: Priorities and High level objectives blocks sit above Captain's Call and the other three sections, with Ideas after Charted Next](docs/media/fork/focus-and-ideas-in-bearings.svg)

Bearings and `/ahoy` now open with this home's priorities and then its high level objectives, one short line each, so what to get done and the broad aim of the work are in view whenever FirstMate checks in.
They come from the home's private `data/priorities.md` and `data/high-level-objectives.md`, each a plain bullet list, and a home without one simply shows no block.
A Bearings board stays as it was; the chat digest beside it carries them.
With the T3 Code fork, the high level objectives also sit at the top of T3 Code's Bridge tab, above the decisions, and follow the file as it changes.
Details: [`fm-objectives.sh`](bin/fm-objectives.sh) and [Objectives](docs/t3code-backend.md#objectives).

## Ideas in the backlog

The backlog has an `idea` kind for something the captain may pick up, with no work on it yet, so one list answers "what's open".
An idea is never dispatched, never counts as ready, and never reads as waiting on the captain.
Bearings shows them after Charted Next: a count, the newest few, and how to list them all.
Changing an idea's kind turns it into work.
Details: [ideas](docs/configuration.md#ideas).

## Recovery after a T3 Code restart

A T3 Code server restart ends every agent session it hosts at once, including FirstMate's own when it runs inside T3 Code.
FirstMate notices the restart at its next start and nudges each interrupted worker to check what is still running and report again.
Until such a worker reports, its last `working:` or `paused:` line no longer counts as current.
The T3 Code fork tells a FirstMate running inside it that the server restarted, so FirstMate restarts its session once the server is back.
FirstMate pins its own thread as its project's coordinator, so that note arrives after every restart, even one that cut no worker's run.
If the restart cut FirstMate's own turn, its first tool call is refused once with a reminder to run session start.
Details: [server restart](docs/t3code-backend.md#server-restart).

## Do it when no worker is running

![Before, the idle hook waited for two quiet 30 second polls; after, the watcher rings it on the turn-end itself and it fires about a second and a half later](devlog/media/fleet-idle-doorbell.svg)

An instruction such as "restart when no worker is running" becomes a watch that fires the moment the last worker's turn ends, instead of on a timer.
The watcher rings a doorbell on every worker status write or turn-end it sees, including the routine ones it absorbs, and a watch armed with `--on-worker-event` re-checks at once.
`bin/fm-fleet-idle.sh` is the check: no worker of this home is inside a turn or still has its own work running in its worktree, such as a background test run, with an unreadable worker counted as busy.
The action still fires at most once, and FirstMate gets the outcome as an ordinary wake.
The watch's interval stays as the backstop for a worker whose agent does not mark turn ends.
Details: [the fleet-idle pattern](docs/configuration.md#process-to-event-sources-stateprocevent).

## The live FirstMate's thread on record

Anything that must reach FirstMate, such as an incident listener or a notifier, can read the live session's T3 thread id from `state/t3-main-thread`.
A fixed id went stale, and several FirstMate threads can exist at once.
Only the session holding the session lock writes the record, a read-only session leaves it alone, and a session not running in T3 Code removes a stale one.
Details: [`state/` records](docs/configuration.md#operational-home-layout-and-state).

## The T3 Code credential stays out of transcripts

`config/t3code-token` is a full-access credential, and a T3 Code thread keeps whatever its agent reads.
So in a home signed in to T3 Code, FirstMate's own session is refused any read of that file, a search over `config/`, and a shell command that would print the file or a glob over `config/`.
This guards against a mistake, not a determined reader, and only Claude runs the check.
Details: [`fm-t3-main-pretool-check.sh`](bin/fm-t3-main-pretool-check.sh).

## Current T3 Code releases

T3 Code 0.1.3 renamed some of the tools FirstMate uses and changed how model options are listed.
FirstMate accepts both the old and the new forms, so it works with 0.1.3 and later as well as earlier builds.
Details: [capability gate](docs/t3code-backend.md#capability-gate).

## Telemetry warning that fits the T3 Code fork

The T3 Code fork turns its product telemetry off by default, so a server with no telemetry setting now reads as off and draws no warning.
FirstMate still warns when the server turns telemetry on, or when it cannot read the setting.
Details: [setup](docs/t3code-backend.md#setup).
