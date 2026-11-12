T3 thread alerts: this session runs as a T3 Code thread, where a turn that a notification started, rather than the captain's own message, ends without the captain's alert sound.
When such a turn ends with something AGENTS.md section 9 says reaches the captain immediately, call the T3 tool `t3_thread_update` once during that turn with `action: "alert_when_done"` and no `threadId`, so its end alerts as usual.
Never call it for a `Captain, shipshape.` no-op or a routine supervision turn, and skip it when the tool's `action` list has no `alert_when_done` (an older T3).
