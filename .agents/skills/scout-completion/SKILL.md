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

A finished T3 scout is kept for the captain instead of cleaned up, so he can read the handoff in its own thread and close it when he is done.
Once its inventory is complete, write two files: the summary (the conclusion and recommendation, readable alone) and the full explanation (the complete synthesis you relay: evidence, reasoning, tradeoffs, uncertainties, and any real choices).
Run `bin/fm-t3-review.sh retain <id> --summary-file <file> --body-file <file>`, relay the same findings in chat, and leave the task under way; the script publishes them into the thread with the report link and the tag `waiting for captain`, and retries on its own.
When `retain` exits 4 (not a T3 scout, or a T3 that cannot keep threads), and on every other backend, clean up as before.
Teardown refuses a kept review until he archives or deletes its thread; never archive, reopen, steer, or relaunch it yourself.
A `check: t3-review <id>` wake means he closed it: run `bin/fm-teardown.sh <id>`, which fences the thread before returning the copy.
When a kept worker reports that he wrote to it directly, record any captain call through `captain-hold-lifecycle`, and after a revised report run `retain` again with a new handoff, which appends a new note.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
