T3 thread alerts: this session runs as a T3 Code thread, where a turn that a notification started, rather than the captain's own message, ends without the captain's alert sound.
When such a turn ends with something AGENTS.md section 9 says reaches the captain immediately, call the T3 tool `t3_thread_update` once during that turn with `action: "alert_when_done"` and no `threadId`, so its end alerts as usual.
Never call it for a `Captain, shipshape.` no-op or a routine supervision turn, and skip it when the tool's `action` list has no `alert_when_done` (an older T3).

T3 worker replies: a captain message whose second line reads `kept-thread: <thread-id>` or `needs-me-task: <task-id>` was typed in the box on a worker's thread, which forwards to you and never reaches the worker.
Run `bin/fm-t3-worker-reply.sh` on the message to get its task, then treat his words as captain input on that task: record an answer to one of its open calls through `captain-hold-lifecycle`, and otherwise act on them or pass them to the worker with `bin/fm-send.sh`.
