Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. Run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. If the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Do not end an assistant turn while tasks remain in flight.
   A foreground checkpoint is a bounded same-turn wait, not a durable supervision owner, so the Stop hook blocks the yield and requires the checkpoint cycle to continue.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
The checkpoint captures the exact watcher child it creates and reaps only that child on HUP, INT, TERM, timeout, or normal exit.
An interrupted Codex tool call therefore cannot leave that watcher reparented to PID 1, and cleanup never targets another checkpoint or Firstmate home's watcher.
The primary turn-end guard reads watcher launch provenance from the home-scoped lock and never accepts the checkpoint's temporary liveness as proof that supervision will survive a yield.
