# No-mistakes generation routing and agent selection

## Two separate axes

| Axis | Owner | Mechanism |
| --- | --- | --- |
| Runtime generation (binary + state root / daemon) | Firstmate | `config/no-mistakes-generation` resolved at spawn, snapshotted into task meta, exported into the worker pane |
| Validation agents for a run | no-mistakes | Fresh quota evidence inside that generation (`axi select-agents` / generation-local policy) |

Firstmate must not derive or export `NO_MISTAKES_RUN_AGENTS` from the crewmate harness or model.
Those are unrelated axes: a worker may run on grok while no-mistakes still scores codex/claude/grok for review agents from quota.

## Generation contract

[`bin/fm-nm-generation-lib.sh`](../bin/fm-nm-generation-lib.sh) owns parse, health, resolve, meta lines, and export lines.
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh) applies that pin only to ship tasks whose delivery mode is explicitly `no-mistakes`.
Canonical operator docs live in [`docs/configuration.md`](configuration.md) ("Delivery mode defaults" and "No-mistakes generation").

On each explicit no-mistakes ship spawn:

1. Prefer an existing task meta pin (`nm_generation=`, `nm_binary=`, `nm_home=`) for recovery continuity.
2. Otherwise resolve `config/no-mistakes-generation` when present.
3. Validate absolute paths, executable binary, existing home directory, and a running daemon for that home.
4. Snapshot the pin into meta and export `NM_HOME` plus a `PATH` prefix for the binary's directory into the worker pane only.
5. Absent config keeps ambient PATH/`NM_HOME` for that opted-in task.
6. Invalid or unhealthy configured generations fail closed with an actionable diagnostic and never fall back to the ambient install.
7. `direct-PR`, `local-only`, scout, and secondmate spawns never resolve or inject generation routing.

A configuration change affects only future tasks.
Live task metadata is never rewritten by a config edit, and no process is force-restarted to pick up a new generation.

[`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh) reads `nm_binary=` / `nm_home=` from meta when present so run-step status queries the same generation the worker uses.

Secondmate launches do not pin a generation for the secondmate agent itself.
The generation config is inherited into secondmate homes so their crewmates resolve the same selection.

## Agent selection

No-mistakes chooses validation agents from its own evidence inside the pinned generation.
Quota trouble follows no-mistakes' documented degradation contract; Firstmate does not recreate a quota selector for pipeline agents.

An explicit `NO_MISTAKES_RUN_AGENTS` override is not a Firstmate spawn contract.
Do not reintroduce harness-parity exports.

## Historical incident (why the axes split)

On 2026-07-16 a Codex-assigned worker still hit Claude-first auto selection under a shared no-mistakes home because agent selection was not generation-local and Firstmate coupled it to the crew harness.
That coupling is retired.
Generation routing and in-generation agent scoring are independent.

## Regression coverage

`tests/fm-nm-generation.test.sh` covers absent-config compatibility, exact env/meta pinning, invalid config rejection, old/new generation coexistence, recovery continuity, and the absence of implicit harness-parity export.
`tests/fm-spawn-dispatch-profile.test.sh` covers harness/model/effort launch construction without no-mistakes agent export.
