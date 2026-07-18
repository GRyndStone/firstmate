# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each crewmate its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, Orca, or cmux) - it is the fully verified reference path for secondmate homes, while Orca and cmux are the backends that do not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- The universal firstmate prerequisites: a verified crew harness plus the required toolchain, detected at session start and installed only after you approve; [`docs/configuration.md`](configuration.md) owns both lists ("Harness support", "Toolchain").

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the first mate in chat to use tmux also works.
This mainly matters as an opt-out of herdr or cmux runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md) and [`docs/cmux-backend.md`](cmux-backend.md)).

## First run

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, crewmate windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

## Strict window-existence probe

`fm_backend_target_exists`'s tmux arm (`fm_backend_tmux_target_exists`, `bin/backends/tmux.sh`) answers "does the recorded endpoint still exist" by exact match against the server's own window/pane inventory, never by probing tmux's target resolution.
That distinction matters because tmux's target resolution is lenient: `tmux display-message -p -t <target>` exits 0 for a killed window whose session survives (it silently resolves the target to another window) and even for a nonexistent session - it only fails when no server is running on the socket.
The old probe used exactly that command, so the watcher's endpoint-gone corroboration read a dead task window as alive and silently absorbed the most common tmux death mode; only whole-server death was detected.
The strict probe recognizes these target shapes and matches each exactly against the inventory: a pane id (`%N`, the away-mode daemon's `TMUX_PANE` supervisor target), a window id (`@N`, fm-spawn's stable recorded handle, with the expected `fm-<id>` label also required as the window name when given), `session:name` or `session:index` (supported explicit or legacy targets, including the daemon's `firstmate:0` default), a bare window name, a session-qualified pane id (`session:%N`), and a pane-qualified window (`session:window.pane`, the window by exact name or index and the pane by index or `%id`, matched as one composite inventory line so a window name containing dots still matches whole).
A downed server still fails the listing and reads gone.
Any target shape the strict parser does not recognize - session ids (`$N`), `=exact` prefixes, `{marker}` pane specifiers, an empty session or window part, a dotted bare name that could be tmux's sessionless `window.pane` shorthand - falls back to the old lenient resolution probe (`fm_backend_tmux_probe_lenient`, `tmux display-message -p -t <target> '#{pane_id}'`) instead of reading gone.
That fallback is deliberately fail-open for the two entry points that pass arbitrary explicit user-supplied targets, `bin/fm-send.sh` explicit backend targets and the away-mode daemon's `FM_SUPERVISOR_TARGET` override, so an exotic-but-valid tmux target can never false-read as a dead endpoint, while task-shaped endpoints keep the strict death detection above.
Two further rules close the same fail-open contract for shapes that parse as `session:name` but are not literal names.
A window part containing a glob metacharacter (`*`, `?`, `[`) is fnmatch pattern syntax tmux resolves itself, never a literal `fm-<id>` task window name, so it routes straight to the lenient probe instead of inventory-matching the pattern text.
And strictness on a literal `session:name` or `session:index` miss is label-aware: only the task-shaped call sites (the watcher's `handle_gone_endpoint`, the session-start and recovery digests, the fleet snapshot) pass the recorded `fm-<id>` as the probe's expected-label argument, and recorded `window=` metas are always literal, so a labeled miss reads gone while a label-less miss (an fm-send explicit target, an `FM_SUPERVISOR_TARGET` override) retries the lenient probe, because tmux also resolves unique name prefixes the inventory match cannot model.
Pane-id (`%N`) and window-id (`@N`) shapes stay strict regardless of label - they are exact identifiers, never patterns or prefixes.
The label-aware retry means a label-less `session:name` probe of a killed window whose session survives reads alive through the lenient resolution - the same deliberate fail-open direction the explicit-target entry points already chose, and the labeled task-shaped path is unaffected.

Verified empirically with real tmux 3.7b on macOS (Darwin 27.0.0), 2026-07-12, on a pristine private-socket server:

```sh
$ tmux new-session -d -s probeses
$ tmux new-window -dP -F '#{window_id}' -t probeses: -n fm-victim   # -> @1, pane %1
$ tmux display-message -p -t probeses:fm-victim '#{pane_id}'; echo rc=$?
%1
rc=0
$ fm_backend_target_exists tmux probeses:fm-victim fm-victim; echo rc=$?   # and @1, %1, probeses:1
rc=0
$ tmux kill-window -t @1                                            # session survives
$ tmux display-message -p -t probeses:fm-victim '#{pane_id}' >/dev/null 2>&1; echo rc=$?
rc=0
$ fm_backend_target_exists tmux probeses:fm-victim fm-victim; echo rc=$?   # likewise @1 and %1
rc=1
$ fm_backend_target_exists tmux noses:fm-victim; echo rc=$?
rc=1
$ tmux kill-server
$ fm_backend_target_exists tmux probeses:fm-victim fm-victim; echo rc=$?
rc=1
```

The raw `display-message` probe still reports the killed window alive (`rc=0`), while the strict probe reads it gone in every target shape, keeps a live window alive in every shape, and reads a gone session and a downed server as gone.
With this, the watcher's endpoint-gone wake fires within one poll for a killed tmux task window whose session survives, not just for whole-server death; `tests/fm-backend-tmux-smoke.test.sh` keeps both directions covered against a real server.

Pane-qualified shapes and the lenient fallback verified empirically with real tmux 3.7b on macOS (Darwin 27.0.0), 2026-07-12, on the same pristine private-socket layout (`probeses:fm-victim` window `@1`, pane `%1` at pane index 0, window index 1):

```sh
$ fm_backend_target_exists tmux probeses:fm-victim.0; echo rc=$?   # and probeses:fm-victim.%1, probeses:1.0, probeses:%1
rc=0
$ fm_backend_target_exists tmux probeses:fm-victim.99; echo rc=$?  # recognized shape, strictly absent pane
rc=1
$ fm_backend_target_exists tmux '=probeses:fm-victim'; echo rc=$?  # unrecognized shape -> lenient resolution
rc=0
$ fm_backend_target_exists tmux 'probeses:fm-victim.{top-left}'; echo rc=$?   # unrecognized pane specifier -> lenient resolution
rc=0
$ tmux kill-window -t @1                                           # session survives
$ fm_backend_target_exists tmux probeses:fm-victim.0; echo rc=$?   # and probeses:%1
rc=1
```

A recognized pane-qualified target stays on strict inventory matching in both directions, and an unrecognized explicit shape resolves leniently instead of false-reading as gone; `tests/fm-backend-tmux-smoke.test.sh` keeps these shapes covered against a real server too.

Glob routing and label-aware strictness verified empirically with real tmux 3.7b on macOS (Darwin 27.0.0), 2026-07-12, on the same pristine private-socket layout (`probeses:fm-victim`, window `@1`):

```sh
$ fm_backend_target_exists tmux 'probeses:fm-victi*'; echo rc=$?          # glob window part -> lenient resolution
rc=0
$ fm_backend_target_exists tmux probeses:fm-victi; echo rc=$?             # label-less unique name prefix -> lenient retry
rc=0
$ fm_backend_target_exists tmux probeses:fm-victi fm-victim; echo rc=$?   # labeled strict miss -> confident gone
rc=1
$ tmux kill-window -t probeses:fm-victim                                  # session survives
$ fm_backend_target_exists tmux probeses:fm-victim fm-victim; echo rc=$?  # labeled task shape: strict death detection intact
rc=1
$ fm_backend_target_exists tmux probeses:fm-victim; echo rc=$?            # label-less: deliberate fail-open via lenient resolution
rc=0
$ tmux kill-server
$ fm_backend_target_exists tmux probeses:fm-victim; echo rc=$?            # downed server also fails the lenient fallback
rc=1
```

A resolvable glob or prefix target never false-reads as gone from the explicit-target entry points, the labeled task-shaped miss stays a confident gone, and a downed server reads gone on both paths; `tests/fm-backend-tmux-smoke.test.sh` keeps all three rules covered against a real server.

Unlike `display-message`, `tmux capture-pane` does NOT resolve a gone target leniently: it fails outright on a killed window whose session survives, so the watcher's capture-failure trigger for `handle_gone_endpoint` (`bin/fm-watch.sh`) genuinely fires for ordinary tmux ship/scout crews and the strict probe then corroborates the death.
Verified empirically with real tmux 3.7b on macOS (Darwin 27.0.0), 2026-07-12, on a pristine private-socket server:

```sh
$ tmux new-session -d -s probe -n keepwin
$ tmux new-window -t probe -n taskwin
$ tmux kill-window -t probe:taskwin                                  # session survives
$ tmux capture-pane -p -t probe:taskwin -S -40; echo rc=$?
can't find window: taskwin
rc=1
$ tmux display-message -p -t probe:taskwin '#{pane_id} #{window_name}'; echo rc=$?   # lenient, for contrast
%0 keepwin
rc=0
```

`tests/fm-backend-tmux-smoke.test.sh` pins this against a real server: after the kill-window step it asserts `fm_backend_tmux_capture` fails on the killed window, so a future tmux release quietly making capture-pane resolution lenient would surface as a smoke failure instead of silently re-opening the endpoint-gone blind spot.

## Agent liveness probe

`fm_backend_target_exists` (`bin/fm-backend.sh`) only checks that a window's pane still exists, strictly per the section above.
A secondmate agent that exits leaves its pane alive as a bare idle shell, which passes that check as "alive" - the gap `bin/fm-bootstrap.sh`'s session-start secondmate-liveness sweep exists to close (evidence 2026-07-07: every secondmate in one fleet was found sitting at a dead `zsh` shell, invisible to that check).

`fm_backend_tmux_agent_alive` (`bin/backends/tmux.sh`) answers a deeper question: is a real harness-agent *process* running in the pane right now, not just whether the pane exists?
The watcher's bounded paused-recheck death probe reuses the same classifier for paused crew endpoints, surfacing a confident `dead` verdict as an `agent-dead` stale wake (`docs/architecture.md` "Event-driven supervision" owns those rules).
It reads tmux's own `#{pane_current_command}`, which reports the pane's live foreground process name - already resolved by tmux from the pty's controlling process group, not something this adapter derives itself.

Agent liveness and composer safety are separate checks.
During away-mode escalation delivery, `fm_tmux_composer_state` sends a bare shell glyph on an unbordered row to the shared composer classifier as `unknown`, and the daemon injects only into an affirmatively `empty` composer; see [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-five-backends).

Verified empirically with real tmux 3.6a on macOS (Darwin 25.5.0), 2026-07-07:

```sh
$ tmux new-session -d -s fmtest -n testwin
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
$ tmux send-keys -t fmtest:testwin 'sleep 30' Enter
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
sleep
$ tmux send-keys -t fmtest:testwin C-c
$ tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
zsh
```

An idle pane reports the shell's own name; a live foreground process reports its own name; the pane reverts to the shell's name the moment that process exits - exactly the alive/dead signal the probe needs.

A second case matters for a harness that shells out to subcommands while it runs (git, npm, no-mistakes, ...): does `pane_current_command` report the harness or the subcommand?
Verified the same session: a persisting parent process running a child command (`bash -c 'echo start; sleep 30; echo end'`, where the parent bash stays alive waiting on its own child) reports the PARENT's own name (`bash`) throughout, not the child's (`sleep`) - so a harness that survives while it shells out stays correctly classified as alive.
(A single-simple-command `bash -c "sleep 30"` is a different, unrelated case: bash execs directly into `sleep`, replacing itself, so the reported name changes because the process itself became `sleep` - not because tmux "saw through" to a child.)

The classifier (`fm_backend_tmux_agent_alive`) maps the observed name to `alive`, `dead`, or `unknown`:

- `alive` - the name contains `claude`, `codex`, `opencode`, or `grok`. All four were confirmed to run as their own literal process name (`ps -ef`, 2026-07-07): `claude` and `codex` and `opencode` are each a native compiled binary (`file` reports Mach-O), so their `comm` is their own binary name with no interpreter wrapper to hide behind.
- `dead` - the name is a bare shell (`zsh`, `bash`, `sh`, `dash`, `ash`, `ksh`, `mksh`, `tcsh`, `csh`, `fish`).
- `unknown` - anything else, including an unreadable pane.

### Known gap: `pi` cannot be confidently classified

`pi` is a `#!/usr/bin/env node` script (confirmed via its shebang and installed path, 2026-07-07), so a live `pi` agent's pane reports `node` as its `pane_current_command`, not `pi` - verified by running a long-lived `node -e` script in a pane and confirming its foreground process is a genuine child reachable via `pgrep -P <pane_pid>` with an inspectable `ps -o args=` (the same technique `bin/fm-harness.sh`'s own self-detection uses when walking UP its ancestry), while `pi --version` itself was observed to exit too quickly under the same pane to reliably capture its live foreground state - real `pi` invocations were not available to test.
Since `node` is also the generic name for a plain interpreter session, any future JS-based harness, or someone's unrelated node script, there is no way to attribute a bare `node` foreground process back to `pi` specifically from outside the pane without deeper (and fragile) argument introspection.
The classifier deliberately reports `unknown` for `node`/`python`/`python3` rather than guess - per the secondmate-liveness sweep's correctness bar, a wrong `alive` is harmless but a wrong `dead` spins up a duplicate agent, so an unresolvable case must never be treated as confidently dead.
Practical effect: a dead `pi` secondmate is not auto-healed by the liveness sweep today; it is reported as `skipped: liveness probe inconclusive` instead, which still surfaces it for a human to act on.
Resolving this would need either a `pi`-specific env marker inspectable from outside the process (mirroring `PI_CODING_AGENT=true`, which `bin/fm-harness.sh` already uses for self-detection but which is not readable from a different process without deeper introspection) or accepting the argument-inspection fragility - not attempted here.

## Limitations

None specific to tmux for the reference path itself - it is the fully verified reference backend, while Orca and cmux are the backends without secondmate support.
The agent-liveness probe above has one known gap (`pi`'s generic `node` process name, see above).
