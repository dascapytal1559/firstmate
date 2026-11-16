T3 thread alerts: this session runs as a T3 Code thread, where a turn ends with the captain's alert sound only when the captain's own message started it or was sent into it, so a turn that a notification, a background wake, or another agent's message started ends quietly.
When such a turn ends with something AGENTS.md section 9 says reaches the captain immediately, call the T3 tool `t3_thread_update` once during that turn with `action: "alert_when_done"` and no `threadId`, so its end alerts as usual.
Never call it for a `Captain, shipshape.` no-op or a routine supervision turn, and skip it when the tool's `action` list has no `alert_when_done` (an older T3).

T3 worker replies: a captain message whose second line reads `kept-thread: <thread-id>` or `needs-me-task: <task-id>` was typed in the box on a worker's thread, which forwards to you and never reaches the worker.
Run `bin/fm-t3-worker-reply.sh` on the message to get its task, then treat his words as captain input on that task: record an answer to one of its open calls through `captain-hold-lifecycle`, and otherwise act on them or pass them to the worker with `bin/fm-send.sh`.

T3 thread actions: when he settles, un-settles, snoozes, or un-snoozes a worker's thread, T3 sends the same kind of message with a `thread-action:` line, and the reader prints that action on a second line after the task.
Bring the records in line with it:
- `settled`: he is done with the thread.
  If its worker has finished, its work has landed, and nothing on it waits on him, clean the worker up through the usual landing or scout-completion path, then add the note `Settled in T3 on <date>` to the closed item with `bin/fm-tasks-axi.sh done <id> --note`.
  If it has an open captain call, ask him in one line whether settling answers it, and never close the call without his words.
  If the worker is still working, or its PR or branch still waits on him, tell him and leave it running.
- `unsettled`: he wants it back.
  Reopen the item with `bin/fm-tasks-axi.sh reopen <id>` only when its `Settled in T3` note shows a settle closed it; otherwise take no action.
- `snoozed`: park the item as when he says "snooze" in chat, with `bin/fm-tasks-axi.sh hold <id> --kind parked --reason "Snoozed in T3"`, adding `--until` the UTC date of its time when it has one.
  An item held for an open captain call keeps that hold and takes the date through `bin/fm-captain-hold.sh hold <id> --reason <its reason> --until <date>` instead.
- `unsnoozed`: lift that park with `bin/fm-tasks-axi.sh unhold <id>`, or re-hold a captain call without a date.
- A thread action whose thread no task records, where the reader exits 1, is acknowledged without action.

Your own snooze and archive calls on a thread send no such message back.
