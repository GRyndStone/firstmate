# Primary turn-end supervision guard

This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The shared predicate lives in `bin/fm-turnend-guard.sh`.
Harness-specific tracked hook files only adapt each verified harness's real turn-end mechanism to that shared predicate.
Two related but separate PreToolUse seatbelts deny a bad command shape before it runs rather than detecting a blind turn end afterward: the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`), which reuses this guard's linked-worktree exemption but deliberately remains active in secondmate homes.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon plus a verified turn-surviving owner, a harness hook must either block the turn end or force a follow-up turn that tells the primary to resume the session-start supervision protocol for its harness.

## Shared Predicate

The guard first scopes itself to the real primary checkout.
It is inert in secondmate homes because `.fm-secondmate-home` exists there.
It is inert in crewmate and scout worktrees because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, it requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.

Watcher health is necessary but not sufficient at turn end.
The watcher lock also records its launch owner kind, pid, and process identity.
Process liveness requires both a successful signal probe and a non-zombie process state.
An away-mode daemon owner is durable only while `state/.afk` is a regular file, its recorded owner mode is `away-inject`, its pid and identity match both `state/.supervise-daemon.pid` and the live portable daemon lock, and the exact supervisor backend and target recorded in that lock still resolve to a confidently live harness-agent process.
An arm owner is accepted only for the verified Claude, Grok, Pi, and OpenCode tracked-background mechanisms.
A bounded foreground checkpoint, a Codex arm process, missing provenance, an unknown owner kind, a dead owner, or a reused owner pid all fail closed even while the watcher itself is live and its beacon is fresh.
This distinction matters because a foreground execution session can be alive while the Stop hook runs and then be torn down as the assistant turn yields.

Blocking is the transition that guarantees another assistant continuation.
If the next Stop payload has `stop_hook_active=true`, that records the prior transition but does not authorize a second blind stop.
The retry is allowed only when no task remains in flight or durable watcher ownership has since been established; otherwise the guard blocks again.
The failure banner includes a bounded list of task ids whose current-state probe is parked, paused, blocked, failed, done, or unknown so an idle pane is not hidden behind the aggregate in-flight count.
It reports the exact number of additional non-working results omitted from the display and the exact number of in-flight tasks left unprobed by the bounded scan.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
Hook payload data is diagnostic only and never authorizes a stop.
The guard drains it without `jq`, so empty or malformed input and a missing `jq` binary still run the primary-scoped ownership predicate and block when work would otherwise end blind.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh`.
- `codex`: `.codex/hooks.json` registers a dependency-free `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` proves the checkout is not a linked worktree before scanning home-level handoffs, then listens for `session.idle`, lets the watcher-arm coordinator handle normal idle supervision first, runs the shared guard, and uses `client.session.promptAsync` to deliver required continuations.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` proves the checkout is not a linked worktree before registering primary lifecycle handlers, requires ownership of the home session lock before recovering or acknowledging a home-wide handoff, then listens for `agent_settled`, marks the extension version loaded for session-start checks, runs the shared guard for every logical agent run including a generated guard follow-up, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to attempt delivery.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter requires the payload's exact session identity, runs the shared guard, and, when it blocks or cannot run, atomically records one deterministic continuation under `state/.turnend-handoffs/` and starts `bin/fm-turnend-guard-grok-deliver.sh` to invoke bounded `grok --resume <sessionId>` attempts only after the originating Stop-hook process identity is gone.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.

Claude and Codex support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Both payloads include `stop_hook_active`; the shared guard uses it to identify a repeated blocked transition while still requiring durable ownership before the harness can end.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters cannot block the lifecycle callback directly, so they persist the continuation before attempting delivery.
Every forced follow-up produces a later lifecycle event that reruns the shared predicate.
If it still returns 2, the adapter preserves or establishes one continuation owner instead of discarding the result, so each settled or idle transition has at most one delivery while continued blindness always guarantees a future turn.
Pi and OpenCode keep a transient latch only around an SDK delivery call already in flight; every callback runs the predicate before that latch, and `finally` clears it for the next settled or idle event.
Pi's real `ExtensionAPI.sendUserMessage` returns `void`, so calling it is never treated as delivery acknowledgement.
Pi retains the handoff, keeps one process-retaining retry timer alive, and rechecks Firstmate session-lock ownership before scheduling, delivering, acknowledging, or removing the home-wide record.
If ownership changes after scheduling, that process cancels its retry owner without reading or changing the retained handoff.
The ensuing `agent_start` proves an assistant continuation began, but Pi releases retry ownership only after the acknowledged record's absence is confirmed.
OpenCode requires current Firstmate session-lock ownership before it scans, delivers, acknowledges, or removes home-level handoffs.
It serializes same-session idle handlers and binds cleanup to their invocation generation, so an older healthy result cannot remove a newer blind handoff.
OpenCode keeps exactly one `promptAsync` delivery flight per session until that promise definitively resolves or rejects.
A bounded local wait returns control while a process-retaining retry timer observes a hung flight without issuing another SDK request, and any newer blind generation is persisted as the desired handoff while that flight remains active.
A rejected flight promotes that durable generation into the next single flight, while a successful flight consumes it without duplicate delivery.
An explicitly resolved `promptAsync` promise is queue acknowledgement, while acknowledged cleanup failure remains owned until record absence is confirmed and plugin startup recovers retained records only for the lock-owning process.
If Pi or OpenCode cannot synchronously persist a handoff, the message remains in process memory under the same referenced retry timer until persistence and delivery succeed or the predicate becomes healthy.
Neither adapter reads, delivers, acknowledges, or clears a home-level handoff from a linked crewmate checkout.
A shared-guard launch failure follows the same fail-closed delivery path instead of being converted into a healthy result.
Grok stores the originating hook pid and process identity in its deterministic per-session handoff.
One per-session preparation lock serializes pending replacement with worker acquisition, so a concurrent Stop preserves an already readiness-acknowledged owner instead of overwriting its token.
The launching hook accepts an existing worker only when its token, pid, and process identity match the current pending record, otherwise waits for that owner to release before establishing a replacement, and the worker retains retry ownership until a bounded resume succeeds.
Retained legacy `@continue` records are moved to a diagnostic quarantine inside the handoff directory and are never delivered.
After a successful exact-session resume, the worker atomically moves the pending record into acknowledged-cleanup state and retries only state removal, never the resume.
TERM or INT kills and reaps the exact active resume and timeout children before that worker releases its singleton lock.
A healthy later Stop removes that session's stale pending record.
After independently confirming the same primary-checkout scope, a missing shared guard enters that durable delivery path with an explicit adapter-failure reason.
Missing exact session identity is a loud, explicitly unsupported passive-product exception: the adapter logs that it cannot safely identify the originating session, schedules no ambiguous continuation, and exits without using `--continue`.
Grok exposes no blocking Stop result, so an unwritable durable state directory or a worker that cannot acknowledge readiness is an explicit unsupported product exception: the wrapper exits nonzero, preserves any completed pending record, and cannot claim a guaranteed continuation until a later Stop or `fm-guard.sh` recovers it.

## Empirical Validation

All harnesses were validated on 2026-07-08 in scratch repos or throwaway homes, not against the captain's live primary fleet state.

Claude Code 2.1.204 preserved the existing behavior.
Hook file used: `.claude/settings.json`.
Command run: `claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json` with a scratch Stop hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2.
Observed output: the first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued with `BANANA`, and the second stop payload had `stop_hook_active=true` and was allowed.
Earlier validation on 2026-07-04 also verified that `CLAUDE_PROJECT_DIR` is set to the settings-loaded project root, while the hook command itself runs from the session cwd.

Codex `codex-cli 0.142.1` was validated with a scratch `.codex/hooks.json` Stop hook.
Hook file used: `.codex/hooks.json`.
Command run: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Say hi in exactly one word.'`.
Observed output: the first model output was `Hi`, the Stop hook exited 2, Codex logged `hook: Stop Blocked`, the model continued with `CODEXHOOK`, and the second hook call had `stop_hook_active=true`.
The Stop payload included `cwd`.
Command run for root-signal probe: `codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Use the shell tool to run mkdir -p outside && cd outside && pwd, then use the shell tool again to run pwd. Your final answer must include the two observed outputs.'`.
Observed output: the first command printed `<scratch>/outside`, the second command printed `<scratch>`, the Stop hook process `pwd -P` printed `<scratch>`, payload `cwd` printed `<scratch>`, and `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, and `CODEX_CWD` were empty.
The tracked command therefore treats hook process PWD as the hook-loaded firstmate root and does not let payload `cwd` choose an executable.
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the failure banner can distinguish a repeated blocked transition through `stop_hook_active` without treating that field as authorization.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter remains trusted only for persistent primary TUI sessions.

Pi 0.80.5 was re-validated on 2026-07-09 in a disposable primary-shaped clone with isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, and tmux socket `fm-pi-q6-lab`.
Hook files used: the tracked `.pi/extensions/fm-primary-turnend-guard.ts` and `.pi/extensions/fm-primary-pi-watch.ts`.
Commands run inside separate interactive turns: `printf PI_E2E_BASH_ONE` through Pi's bash tool, `README.md:1-5` through Pi's read tool, and `printf PI_E2E_BASH_TWO` through Pi's bash tool.
Command used to make the shared predicate unhealthy: `: > "$FM_HOME/state/pi-e2e.meta"`.
The next no-tool prompt produced exactly one `TURN WOULD END BLIND` follow-up, and that follow-up called `fm_watch_arm_pi` once with output `watcher: started Pi extension arm child 1`.
The three earlier tool turns produced no guard follow-up because no work was in flight.
Command used to fire the watcher: `printf 'done: pi e2e watcher fire\n' > "$FM_HOME/state/pi-e2e.status"`.
Observed output after the wake: Pi ran `bin/fm-wake-drain.sh`, read the terminal status, called `fm_watch_arm_pi`, and rendered `watcher: started Pi extension arm child 2`.
The complete pane contained one guard message and zero foreground `bin/fm-watch-arm.sh` bash calls.
`/quit` printed `PI_EXIT=0`, and the second arm process plus its watcher child were both gone afterward.
The installed Pi 0.80.5 `ExtensionAPI` declaration and runtime implementation were also inspected: `sendUserMessage` returns `void` and catches its internal asynchronous send rejection, while `agent_start` is emitted when the resulting assistant continuation actually begins.

On 2026-07-17, a Codex foreground checkpoint was still live at Stop-hook evaluation under exec session 30732, but its process did not survive the turn yield and the next fleet command found the watcher beacon 763 seconds stale.
That evidence invalidated watcher-process liveness as a durable-ownership proxy.
The guard now rejects checkpoint provenance before the yield and rejects a later `stop_hook_active=true` retry when no durable owner was established.

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi` and the nested resumed turn printed `GROKRESUMEHOOK`.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, active away-mode daemon provenance plus exact live agent-process validation including a surviving bare-shell pane, a foreground checkpoint that is live at the first Stop and dead at the retry, exact bounded-detail omission disclosure, repeated Pi, OpenCode, and Grok continuation delivery while blindness persists, bounded OpenCode prompt hangs, real Pi void-return acknowledgement, Pi session-lock ownership, linked-crewmate recovery isolation, volatile persistence and acknowledged-cleanup retry ownership, fail-closed guard-launch and handoff-preparation errors, exact Grok session identity, concurrent Grok Stop serialization, live-owner token binding, hook-exit, readiness, signal-reaping, and per-session barriers, dependency-free fail-closed behavior without `jq` or valid input, tracked hook registration for all five harnesses, and the Grok adapter's permission-mode regression.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.
