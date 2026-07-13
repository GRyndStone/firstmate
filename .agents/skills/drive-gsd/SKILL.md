---
name: drive-gsd
description: >-
  Agent-only reference for GSD-driving crewmates: standing managers that drive an external GSD.Pi project headless.
  Use before scaffolding (fm-brief.sh --gsd), spawning, steering, or recovering such a crewmate.
  Covers when to choose the GSD-driving shape, the scaffold and spawn recipe, supervision specifics for long headless runs, the decision-routing contract, the recovery pattern, and known GSD 1.9.0 gotchas.
user-invocable: false
metadata:
  internal: true
---

# drive-gsd

Load this before scaffolding, spawning, steering, or recovering a crewmate that drives an external GSD.Pi project headless.

## When to use this shape

Use the GSD-driving shape when the captain asks for work that an external GSD.Pi project manages: a long, multi-milestone objective where GSD's own units do the research, planning, and execution, and the crewmate's job is to stand the project up or resume it and drive the GSD process, not to do the work.
The deliverable is driven external project state plus reports, never a PR, so this is neither a ship nor a scout task; it is its own brief contract.
Everything project-specific - the GSD project path, the objective or specification to hand GSD, the milestone(s) that define done, any machine profile or operating guide to read first, and any hard constraints such as pinned tokens, read-only rules, or no-push rules - belongs in the `{TASK}` text, never in tracked material.

## Scaffold and spawn

1. Scaffold with `bin/fm-brief.sh <id> <repo-name> --gsd`; the flag is mutually exclusive with `--scout` and `--secondmate`.
2. Replace `{TASK}` with the GSD project path, the objective, the milestone(s) that define done, the operating-guide path when one exists, and the constraints above.
3. Spawn with `bin/fm-spawn.sh <id> projects/<repo> --scout`: the worktree is scratch and the deliverable is driven external state plus the report, so scout's meta kind gives teardown the correct carve-out - the worktree is released once `data/<id>/report.md` exists.
4. The repo argument only decides where the crewmate's scratch worktree sits; pick the cloned project most related to the task.
5. Add the task to the backlog as usual.

## Supervision specifics

GSD auto runs are long: treat long quiet as normal, not a wedge.
The brief requires the crewmate to keep a `paused: driving GSD ...` line as the LAST status line while idle-waiting with no open decision or blocker, so the watcher already classifies the quiet pane as a declared external wait.
While a keyed `needs-decision:` or `blocked:` line is open, the brief forbids any further status append, so the open line stays the last line and keeps surfacing until the crewmate closes it with the keyed `resolved:`.
When you need current GSD progress, steer the crewmate to run `gsd headless status` and report back; never run `gsd` against the external project yourself and never peek the project's files for state - the crewmate is the single driver of that project.
Milestone completions arrive as keyed `needs-decision [key=milestone-<id>]: milestone <id> complete - <question>` boundary events, so they surface immediately instead of being absorbed behind the `paused:` last line; `working:` lines are only rare mid-milestone progress.
Relay each completed milestone to the captain as an outcome together with its proceed/UAT question.
The brief's context self-preservation rule can surface `paused: context handoff written, requesting relaunch`; treat that as a healthy rotation request, not a failure, and recover per the pattern below with `data/<id>/handoff.md` as the starting state.

## Decision routing

The brief routes every NEEDS-HUMAN gate, milestone-boundary decision, and substantive GSD question to you as `needs-decision:`, with milestone boundaries carrying a `[key=milestone-<id>]` key.
Relay anything about the captain's intent, scope, or dispositions to the captain; answer purely procedural questions yourself from the brief's task text.
Send the answer back with `fm-send`, and expect the crewmate's `resolved:` line - carrying the same `[key=...]` when one opened the decision - once it feeds the decision to GSD and resumes.
At a milestone boundary the task did not name as final, the crewmate reports and waits; decide with the captain whether to continue, extend the task, or stand the manager down.

## Recovery

GSD persists all project state in the external project's SQLite-authoritative `.gsd/` database, so a dead or rotated manager loses nothing durable; recovery is reconcile-then-resume, never re-do.
Recover per `stuck-crewmate-recovery`'s relaunch step - relaunch with the same brief plus an appended recovery addendum - where the addendum says:

1. A predecessor died or was rotated mid-supervision; every goal, rule, and constraint in the sections above still binds in full.
2. Reconcile GSD's view FIRST: `gsd headless status` and `gsd headless query` to confirm milestone state, queued units, and anything left half-finished or locked; `gsd sessions` lists resumable sessions.
3. Repair any crash-stale unit or lock through GSD's own tooling; never delete or rewrite GSD state wholesale.
4. Resume execution with `gsd headless auto` and a sane `--timeout`, keeping the brief's status discipline.
5. When the predecessor left `data/<id>/handoff.md`, read it as the starting state.

## Known GSD 1.9.0 gotchas

- Headless shutdown process leak: a headless invocation can print a valid result while leaving a `gsd` process alive.
  The brief has the crewmate check for and kill leftover `gsd` processes after every headless invocation; when supervising, a lingering `gsd` process after a finished run is this bug, not new work.
- `gsd headless extensions list` is a known leaky path; inspection should use the interactive form.
- Give every `gsd headless auto` run an explicit sane `--timeout`; an unbounded run can sit on a stuck unit indefinitely.
- An enabled strict-acceptance extension blocks a UAT `PASS` while any check is `NEEDS-HUMAN`; those gates are exactly what the decision-routing contract exists for and must reach the captain, never be auto-resolved.
