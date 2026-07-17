# No-mistakes worker agent handoff

## Contract

[`bin/fm-spawn.sh`](../bin/fm-spawn.sh) is the single owner of the concrete harness assigned to a worker and its validation-agent handoff.
After static crew-harness resolution, an explicit captain or dispatch override, batch re-execution, or secondmate recovery resolution has produced `HARNESS`, the script exports `NO_MISTAKES_RUN_AGENTS` into that worker's pane before launching the harness.
The value is an explicit one-element order containing the exact assigned harness, so no fallback can silently precede or replace it.
Firstmate never rewrites shared no-mistakes configuration for a task.
Each worker receives its own pane-local export, so concurrent workers with different assignments do not share mutable selection state.
Batch launches re-enter the same single-task spawn path for every pair, and secondmate recovery re-enters that path after re-resolving its configured harness.

The private no-mistakes registry supports Firstmate's `claude`, `codex`, `opencode`, and `pi` harnesses directly.
For an unsupported Firstmate harness such as `grok`, or an unverified raw launch command, `fm-spawn.sh` exports the literal assigned name and warns that validation will fail closed.
The private runner rejects that unsupported value instead of falling back to `auto` or selecting another first agent.

## Required private runner

This handoff requires the private no-mistakes capability at commit `e8d7e4ae9ace7f6b4322b7fe03fe33138dfb44f3`, based on upstream tag `v1.37.0` at commit `78e4dcb234274199717acafa90abca5cf7013993`.
The private capability captures `NO_MISTAKES_RUN_AGENTS` from the invoking process, transports it with the run request, persists it with the run, reapplies it after trusted configuration merge, and preserves it across daemon recovery.
The private source and its update procedure are maintained outside this repository, and no public upstream push or contact is part of this contract.

## Incident evidence

The failure was reproduced on 2026-07-16 with an installed Codex worker assignment and global no-mistakes auto-selection.

```text
$ rg '^harness=' /Users/cal/firstmate/state/forex-engine-fix-v5.meta
harness=codex
$ rg '^agent:' ~/.no-mistakes/config.yaml
agent: auto
$ no-mistakes --version
no-mistakes version v1.34.0 (dc5a800) 2026-07-07T06:29:57Z
```

The exact failed review log command showed Claude selected before Codex and then stopped on Claude's session limit.

```text
$ no-mistakes axi logs --run 01KXPJZTW29K0X2JCD1CWEZ48Z --step review --full
claude started pid=50683
You've hit your session limit · resets 5pm (America/Los_Angeles)
claude exited pid=50683 error=claude exited: exit status 1:
```

The inspected upstream and private commits were verified with these commands.

```text
$ git -C private-no-mistakes describe --tags --exact-match 78e4dcb234274199717acafa90abca5cf7013993
v1.37.0
$ git -C private-no-mistakes show -s --format='%H %s' 78e4dcb234274199717acafa90abca5cf7013993
78e4dcb234274199717acafa90abca5cf7013993 chore(main): release 1.37.0 (#458)
$ git -C private-no-mistakes show -s --format='%H %s' e8d7e4ae9ace7f6b4322b7fe03fe33138dfb44f3
e8d7e4ae9ace7f6b4322b7fe03fe33138dfb44f3 feat: add run-scoped agent override
```

## Regression coverage

`tests/fm-spawn-dispatch-profile.test.sh` covers static resolution, explicit dispatch axes, batch re-execution, unsupported-harness behavior, and concurrent workers with distinct pane-local values.
`tests/fm-secondmate-liveness.test.sh` proves a bootstrap recovery respawn reconstructs the resolved validation assignment through the same spawn owner.
