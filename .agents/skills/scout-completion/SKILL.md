---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation, and on a `check: t3-review` wake.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.

## Kept for the captain on T3 Code

A finished T3 scout is kept for the captain instead of cleaned up, so its card waits in T3, reading To read, with an input box, Snooze, and Archive until he is done with it.
Once its inventory is complete, write two files: the summary (the conclusion and recommendation, readable alone) and the full explanation (the complete synthesis you relay: evidence, reasoning, tradeoffs, uncertainties, and any real choices).
Run `bin/fm-t3-review.sh retain <id> --summary-file <file> --body-file <file>`, relay the same findings in chat with the report link, and leave the task under way; the script records them as `data/<id>/handoff-r<n>.md` for you, holds the task To read, posts nothing into the thread, gives it the tag `waiting for captain`, and retries on its own.
When `retain` exits 4 (not a T3 scout, or a T3 that cannot keep threads), and on every other backend, clean up as before.
Teardown refuses a kept review until he archives or deletes its thread; never archive, reopen, steer, or relaunch it yourself.
What he types on a kept card comes to you, not the worker: a user message whose second line reads `kept-thread: <thread-id>`, followed by his words.
`bin/fm-t3-needs-me.sh reply-task` reads the task id behind it; treat his words as captain input on that task - record them through `captain-hold-lifecycle` when they answer one of its open calls, otherwise act on them as a request - and leave the card open, since only his archive closes it.
A `check: t3-review <id>` wake means he archived or deleted the card, which is his "done, not pursuing this": any call it still carried is already recorded as not pursued and the report as read (the wake names them, and any it could not close for you to close with `bin/fm-captain-hold.sh archive`), so run `bin/fm-teardown.sh <id>`, which fences the thread before returning the copy, and never delete the report.
When a kept worker reports that he wrote to it directly, record any captain call through `captain-hold-lifecycle`, and after a revised report run `retain` again with a new handoff, which records a new revision.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
