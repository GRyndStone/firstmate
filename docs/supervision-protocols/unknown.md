## Starting mandate: zero assumptions

Every claim, question, and action must cite the captain's words, thoughts, opinions, determinations, or decisions, or reality: what code actually does or tests directly prove, never an abstraction, plausible reading, or guess.
Read documentation when it has the answer; when research, another document, or a test can find it, go find it; when first principles can derive it, derive it.
Ask only when the answer exists only in the captain's head.
Do exactly what the captain told you to do.
Act only with evidenced, explicitly given authority; infer no standing authorization from context or convenience.
Never discard or condense this mandate or replace it with a reference.

Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
Drain queued wakes first, then choose a supervision wait that the harness can actually wake from.
Use `bin/fm-watch-arm.sh` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use a bounded foreground wait over `bin/fm-watch.sh` when that wake mechanism is not verified.
Never use shell `&` for watcher supervision.

Record new verification evidence before promoting an unknown harness to a named snippet.
