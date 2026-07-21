---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

A stale wake whose reason carries `endpoint-gone` or `agent-dead` means the crew is confirmed dead, not merely quiet (`docs/architecture.md` "Event-driven supervision" owns the detection rules).
For `endpoint-gone` there is no pane left to peek or steer, and for `agent-dead` the pane holds no live agent process, so skip the peek/steer/interrupt steps and go straight to step 4's relaunch, peeking an `agent-dead` pane first only to salvage a progress note.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
   Before each relaunch on a repeated obstacle, record it with `bin/fm-workflow-bound.sh note-obstacle <id> <obstacle-key>` (two free attempts; exit 3 means escalate, never silent infinite retry).
5. If a second relaunch fails too, or `note-obstacle` exits 3, write `failed` or surface `needs-decision` to the backlog/captain with evidence - never a third silent retry.
