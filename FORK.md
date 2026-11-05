# What this fork adds

This fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) regularly merges upstream's `main` and carries the changes below on top.
Each section says what the change does and why, with a picture where one shows it.
The [README](README.md) keeps a one-line summary of each.

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
That opens the backend to every agent whose T3 Code driver takes those settings; Claude, Codex, Grok, and Pi are verified live; Cursor, Gemini, Kimi, and Devin go through the ACP registry, found by agent; and OpenCode 2 is refused until the T3 fork's per-session environment is installed.
FirstMate now requires the T3 Code fork, which has those settings: a T3 Code without them is refused for every agent, Claude and Codex included, before anything starts, and the folder files are gone.
Details: [worker environment](docs/t3code-backend.md#worker-environment-and-channel-statement).

## Readable project and task titles

![Worker cards before, fm-recipe-box over fm-recipe-box-print-view, and after, recipe-box over Print view for one recipe](docs/media/fork/readable-crew-titles.png)

A new T3 Code project is titled with its folder name instead of `fm-<folder>`, and a worker's thread is titled with its task's title instead of an internal id.
The worker cards in T3 Code's sidebar then read as the project and the work.
Task titles are cut to 96 characters, so short titles read best.
Projects already in T3 Code keep their old titles, and FirstMate's own records still track each worker by its id, never by the title.
Details: [task lifecycle](docs/t3code-backend.md#current-lifecycle-and-safety).

## Full access and a clean stop

A T3 Code worker is refused unless it runs with full access, because a worker stuck waiting on an approval FirstMate cannot give would stall silently.
Cleanup uses T3 Code's own Stop, which also stops any tasks the worker started itself, instead of leaving them running after the worker is gone.
Details: [task lifecycle](docs/t3code-backend.md#current-lifecycle-and-safety).

## Approvals reach FirstMate at once

When a T3 Code worker stops on a question or a permission approval anyway, FirstMate hears about it at once instead of at the end of its next 15-second wait.
FirstMate can then allow or deny the approval itself, from its own session, instead of interrupting the worker and steering it again.
The T3 Code fork's wait ends the moment a request appears, so FirstMate no longer re-reads idle workers every second, and the 15-second check stays as the backstop.
Details: [push events and polling fallback](docs/t3code-backend.md#push-events-and-polling-fallback).

## Waiting for captain and Testing on the worker's card

![A worker's card through its life: Working, then Testing during its no-mistakes run, Waiting for captain while only the captain can unblock it, Testing again once he answers, and Working when the run ends, with the title plain throughout](devlog/media/crew-card-status.svg)

T3 Code knows when a worker's turn ended, but only FirstMate knows that a worker now needs the captain or sits in a no-mistakes run.
FirstMate says so in the status spot on the worker's card, and the title stays as it is.
When FirstMate decides that only the captain can unblock a live worker, the card reads Waiting for captain.
A worker's own question does not set it, because FirstMate settles most of those itself.
While a worker's no-mistakes run is active, the card reads Testing, and Waiting for captain wins when both apply.
The words go when the wait or the run ends, and when the worker is cleaned up.
Only T3 Code workers show this, and it needs a T3 Code with the crew card status; on an older one the card shows neither word and nothing else changes.
A failed update is retried, so the card comes right within about a minute, and Testing can take that long to appear or go.
Details: [crew card status](docs/t3code-backend.md#crew-card-status).

## Priorities and high level objectives in every check-in

![A Bearings digest with made-up lists: Priorities and High level objectives blocks sit above Captain's Call and the other three sections, with Ideas after Charted Next](devlog/media/focus-and-ideas-in-bearings.svg)

Bearings and `/ahoy` now open with this home's priorities and then its high level objectives, one short line each, so what to get done and the broad aim of the work are in view whenever FirstMate checks in.
They come from the home's private `data/priorities.md` and `data/high-level-objectives.md`, each a plain bullet list, and a home without one simply shows no block.
A Bearings board stays as it was; the chat digest beside it carries them.
Details: [`fm-objectives.sh`](bin/fm-objectives.sh).

## Ideas in the backlog

The backlog has an `idea` kind for something the captain may pick up, with no work on it yet, so one list answers "what's open".
An idea is never dispatched, never counts as ready, and never reads as waiting on the captain.
Bearings shows them after Charted Next: a count, the newest few, and how to list them all.
Changing an idea's kind turns it into work.
Details: [ideas](docs/configuration.md#ideas).

## Recovery after a T3 Code restart

A T3 Code server restart ends every agent session it hosts at once, including FirstMate's own when it runs inside T3 Code.
FirstMate notices the restart at its next start and nudges each interrupted worker to check what is still running and report again.
The T3 Code fork tells a FirstMate running inside it that the server restarted, so FirstMate restarts its session once the server is back.
Details: [server restart](docs/t3code-backend.md#server-restart).

## Refresh context on the FirstMate thread

The T3 Code fork's Refresh context button swaps the agent session behind the FirstMate thread, so the context starts clean while the thread and the chat stay as they were.
FirstMate does the other half.
The old session stows without asking anything, because the swap waits for that turn to end, and whatever it would have asked becomes a held decision the new session reads.
The new session takes over the session lock the old one left behind, and it comes up in charge, not read-only.
T3 Code opens the new session with `Context refreshed.`, which FirstMate treats as a start and not as the captain speaking, so it answers in one short line and runs no Bearings.
Wakes that arrive during the swap reach the new session, and one watcher cycle carries on.
Details: [Refresh context](docs/t3code-backend.md#refresh-context).

## Current T3 Code releases

T3 Code 0.1.3 renamed some of the tools FirstMate uses and changed how model options are listed.
FirstMate accepts both the old and the new forms, so it works with 0.1.3 and later as well as earlier builds.
Details: [capability gate](docs/t3code-backend.md#capability-gate).
