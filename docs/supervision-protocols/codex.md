Mode: Codex durable local supervisor.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run `bin/fm-supervisor-start.sh` as its own Codex tracked background task.
4. After it reports a live daemon and watcher, end the turn; quiet classification and bounded unchanged-pause rechecks stay in shell and schedule no model continuation.
5. A marked actionable digest wakes the primary once; drain queued wakes before inspecting or acting, then leave the same daemon running.
6. Never use shell `&`, `nohup`, or `bin/fm-watch-arm.sh` for Codex's normal supervision.

The normal daemon never creates `state/.afk`.
If away mode is entered while it is live, the existing away-mode presence gate and classification policy take precedence.
`docs/turnend-guard.md` owns the durable-owner and fail-closed state machine.
