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
When tasks are in flight, a harness hook must block the turn end or keep forcing bounded follow-ups unless queued wakes are drained and a live identity-matched watcher has a verified owner that survives turn yield.
Codex normal supervision uses the same local sub-supervisor daemon as away mode without creating `state/.afk`.

## Shared Predicate

The guard first scopes itself to the real primary checkout.
It is inert in secondmate homes because `.fm-secondmate-home` exists there.
It is inert in crewmate and scout worktrees because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, the durable wake queue must be empty and `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh` must succeed.
Queue emptiness is the existing mechanical receipt that wake handling reached `bin/fm-wake-drain.sh`.
The live watcher lock must also name a live identity-matched owner declared by its wrapper.
A `daemon` or `checkpoint` owner is declared through the environment and recorded by `bin/fm-watch.sh` from its own parent.
An `arm` owner is recorded into the lock by `bin/fm-watch-arm.sh` itself, because that watcher is deliberately not the arm's child (see "Detached supervision watcher" below) and so cannot derive the arm from its own `PPID`.
Claude and Grok normal supervision require an `arm` owner.
Codex normal supervision requires a `daemon` owner with mode `normal-inject`; that owner remains valid if `.afk` later appears, while an `away-inject` owner is accepted only while `.afk` is active.
Both daemon modes must match `state/.supervise-daemon.pid` and the live identity recorded in `state/.supervise-daemon.lock`.
The daemon owns one watcher child and one singleton lock per `FM_HOME`; a dead or identity-mismatched daemon invalidates ownership even if an orphaned watcher and fresh beacon remain.
In normal mode routine wakes, unchanged declared pauses, and scheduled unchanged-pause rechecks stay in shell and consume no model turns.
One deduplicated actionable batch may inject one marked wake, after which queue emptiness requires `bin/fm-wake-drain.sh` before turn end.
Direct activity or a status transition in a formerly paused endpoint is actionable in normal mode rather than silently clearing pause tracking.
Its dedupe latch is bound to the paused status, turn receipt, and endpoint activity state; draining any wake queue does not re-arm unchanged activity.
An authoritative status or turn change, an endpoint transition back to idle, or an explicit recorded disposition resolves that event and permits a later distinct event to wake once.
If `.afk` appears under a normal daemon, the existing away-mode classification and pause re-surface behavior take precedence until away mode exits.
An `arm` owner is valid only while both the wrapper and its identity-matched harness tracker remain live.
A foreground `checkpoint` owner never authorizes turn end because that owner cannot survive turn yield.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.
It also blocks after an actionable watcher exit until queued wakes are drained and a new turn-surviving owner is verifiably live.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
Hook input and `stop_hook_active` are diagnostic only.
Missing `jq`, malformed input, empty input, or a forced-continuation retry cannot bypass the shared predicate.

## Detached supervision watcher

This guard is push-based and fires at turn end.
The mid-turn window it does not cover was the one that hurt: on 2026-07-25, between 08:45 and 08:55, the harness stopped the background task running `bin/fm-watch-arm.sh` four times, and each stop took the real watcher process down with it, so the fleet ran unsupervised until firstmate happened to see the kill notification and re-arm by hand.
A kill whose notification does not arrive during a long turn leaves crewmates working with nobody watching.
The arm's `watcher: started pid=NNNNN (beacon fresh)` line is not evidence against this, because it describes a moment already past by the time the kill lands.

### How the harness actually kills a background task

Measured on macOS (Darwin 27.0.0) on 2026-07-25, before any fix existed, by launching one background task that forked three differently-isolated children and then stopping that task through the harness's own stop path.

The launcher and its three children:

```
launcher pid=42840 ppid=42835 pgid=42835
DD       pid=42865 ppid=1     pgid=42865   # double-forked: reparented to init
EE       pid=42866 ppid=42840 pgid=42866   # own process group AND own session
```

An earlier run of the same probe also covered a plain child sharing the launcher's process group, and a child in its own process group but the launcher's session.

After the harness stop, with beat files written every 0.5s:

```
launcher pid=42840 DEAD  beat=1784995474
DD       pid=42865 ALIVE beat=1784995482   # still beating 8s after the kill
EE       pid=42866 DEAD  beat=1784995474
```

Every child that was still a descendant of the launcher at kill time died, including the one in its own session, and only the process that had been reparented off the launcher survived.
So the harness stop is a **descendant-tree walk**, not a process-group or session signal.
`setsid` alone is therefore not a fix, and a test that kills only a process group would pass while production still failed.

### What the fix is

`bin/fm-detach.sh` starts the watcher with a double fork, so the intermediate exits at once and the watcher is reparented to init before the walk could ever enumerate it.
It also calls `POSIX::setsid()` when perl is available, as defence against a harness that signals a process group instead, and rebinds stdin/stdout/stderr away from the launcher's pipes so a dying harness pipe cannot deliver SIGPIPE to the survivor.
`bin/fm-watch-arm.sh` no longer kills the watcher on `HUP`/`TERM`/`INT`; it just stops reporting for it.
Nothing is lost by that, because every wake reason is appended to `state/.wake-queue` before the watcher prints it.

The second-order hazard is duplicates: once watchers outlive their launchers, a careless re-arm strands two.
Three things prevent that, and none of them identify a watcher by process name, because sibling firstmate homes run the same `bin/fm-watch.sh`.
A re-arm that finds a live identity-matched holder attaches to it and re-points the ownership record at itself rather than starting a second watcher.
An arm that fails to confirm its own watcher stops the exact pid it launched, and only after checking that pid is not the lock holder.
`--restart` still signals only the pid recorded in this home's own `state/.watch.lock`.

### Detecting the absence from durable state

`fm_watcher_state` in `bin/fm-wake-lib.sh` classifies the watcher from the singleton lock and the beacon alone, so no kill notification has to be delivered for the absence to be seen.
`bin/fm-guard.sh` and this guard both read it through `fm_supervision_status`.

- `dead`: the lock names a pid that is provably gone, or recycled onto an unrelated process. Reported immediately, because a dead pid is proof rather than a timeout, where beacon age alone stays silent for the whole `FM_GUARD_GRACE` window.
- `wedged`: the lock names a live, identity-matched watcher whose beacon stopped advancing. Named separately because a liveness check on the pid alone calls this healthy, and because only `bin/fm-watch-arm.sh --restart` can displace a live lock holder.
- `absent`: no lock names a watcher, including the sub-second window where one is still furnishing a lock it just took.
- `live`: live, identity-matched, and beating inside the grace window.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh`.
- `codex`: `.codex/hooks.json` registers a `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`, lets the watcher-arm coordinator run first, rechecks the shared guard on every real idle event, and uses `client.session.promptAsync` to force another follow-up prompt whenever the guard returns 2.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` listens for `agent_settled`, marks the extension version loaded for session-start checks, rechecks the shared guard on every logical agent run, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force another follow-up prompt whenever the guard returns 2.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter runs the shared guard and, when it returns 2, invokes `grok --resume <sessionId> -p <guard-reason>` with `GROK_TURNEND_GUARD_ACTIVE=1`.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.

Claude and Codex support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Both payloads include `stop_hook_active`; when it is true, the shared guard reports that the prior continuation did not restore durable supervision and keeps blocking until the predicate passes.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters fail open at the hook boundary to avoid corrupting a user session, but every real lifecycle callback rechecks the shared predicate and forces another follow-up while it remains blocked.
Each adapter suppresses only callback reentrancy while it is dispatching a follow-up; it never skips the next completed follow-up's predicate check.
Grok's outer adapter rechecks after each resumed process exits, while the nested Stop hook stays inert to avoid recursive adapter processes.
If a passive adapter cannot call its SDK method, cannot find `grok`, or cannot recover the Grok session id, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the active harness protocol instead of hardcoding one background-arm command.

## Empirical Validation

On 2026-07-18, the focused supervision-substrate regression reproduced a real foreground checkpoint receiving an actionable signal and exiting while its beacon remained fresh.
It also reproduced a live Herdr `idle` verdict masked by stale `working` status history.
The regression now requires the live idle verdict to surface, hard-bounds a TERM-resistant Herdr state probe, rejects a foreground checkpoint and a shell-backgrounded arm, rejects queued wakes while a durable owner is live, then permits turn end only after wake drain.

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
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the shared loop guard reads `stop_hook_active`.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter is trusted for primary TUI sessions and documented as passive/fail-open in headless mode.

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

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi`, the nested resumed turn printed `GROKRESUMEHOOK`, and the nested Stop hook saw `GROK_TURNEND_GUARD_ACTIVE=1` and did not recurse.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, durable owner provenance, primary scoping, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, Pi logical-run latch behavior for no-tool and multi-tool runs, fail-closed behavior without `jq`, tracked hook registration for all five harnesses, and the Grok adapter's forced-resume loop guard and permission-mode regression.
`tests/fm-supervision-substrate-hotfix.test.sh` is the bounded live-Herdr end-to-end regression for the 2026-07-18 incident sequence.
`tests/fm-watch-detach.test.sh` is the regression for the 2026-07-25 incident: it kills a real arm the way the harness does, by walking the arm's descendant tree, then requires the watcher to still be alive and to RECREATE a deleted `state/.last-watcher-beat`, so a surviving-but-wedged process cannot pass it.
It also covers the durable-state `dead` and `wedged` classifications behind deliberately misleading beacons, and the idempotent re-arm that adopts an orphaned watcher rather than racing a second one.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.
