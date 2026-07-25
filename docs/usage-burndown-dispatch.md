# Usage-burndown dispatch engine

Design note for the routine agent-routing decision path.
This document is the full statement of the policy; script headers own flags and wire shapes; `AGENTS.md` section 4 keeps only the intake trigger and a pointer here.

Date: 2026-07-25.
Captain commission: route agents by remaining usage per remaining window time, with a modifier that prefers burning capacity that would otherwise expire unused at reset; modular across providers; supersede the prior selection layer.

## Why this replaces the prior layer

The prior selector (`quota-balanced` in `bin/fm-dispatch-select.sh`) ranked candidates by maximum general-window `percentRemaining` and attached a 60/80/90 posture band for admission.
That is a static ordering on a single snapshot ratio.
It does not ask whether a source can actually consume its remaining budget before the window resets, so a source with high remaining and low feasible burn near expiry looks "healthy" and is under-used while the unused slice expires.

The burndown engine scores each eligible source from fresh observations at decision time using remaining usage, time to reset, and a learned feasible burn rate.
It chooses so that usage projected to expire unused is minimized, with pressure that grows as a window nears reset while surplus remains.
Posture bands remain observational admission signals (including freeze refusal for an explicit pin); they no longer decide multi-candidate routing.

## Objective (single owner: `bin/fm-usage-burndown-lib.sh`)

For each eligible source at decision time, from adapter evidence:

| Symbol | Meaning |
| --- | --- |
| `R` | Remaining usage of the binding window (percent of that window, 0-100) |
| `T` | Seconds until that window resets |
| `W` | Nominal window length in seconds |
| `B` | Feasible burn rate in percent-per-second (learned; never a static table of providers) |
| `S` | Projected expiry surplus: `max(0, R - B*T)` |

`S` is the slice of remaining usage the source is not expected to consume before reset if burn continues only at rate `B`.
A single dispatch choice cannot zero every source's surplus; it assigns the next unit of work to the source whose weighted surplus most justifies preferential consumption.

**Score** (higher wins among multi-candidate selects):

```
urgency = clamp(1 - T/W, 0, 1)
pressure = 1 + K * urgency^2    when S > 0
pressure = 1                    when S == 0
score = S * pressure
```

`K` defaults to 4 (`FM_BURNDOWN_PRESSURE_K`).
As `T` shrinks while `S > 0`, pressure rises and the engine prefers that source even if another has slightly higher raw `R`.
When every known source has `S = 0` (feasible burn covers remaining), fall back to higher `R`, then lower profile index (deterministic).

Freeze (`percent used >= 90` on the binding general windows) is admission, not score:
- Multi-candidate select excludes freeze-level sources when any non-freeze known source exists, so work still ships on capacity that is not frozen.
- If every known candidate is freeze, admission refuses (exit 75) with an actionable reason, same as an explicit pin.
- An explicit single-profile `--admit` or `--resume-meta` pin still freezes in place and never substitutes another provider.

Unknown or unusable evidence for a recognized provider never fabricates `R`/`T`/`B`.
That source stays selectable with `provider_recognition=recognized` and `quota_posture=unknown`, scores as non-competing for surplus minimization, and wins only when no known competitor remains (stable first-index tie-break among unknowns).
Missing `quota-axi` or malformed JSON cannot prove freeze for a recognized provider.
An unrecognized provider token is caller input failure rather than evidence absence.
It emits a machine-distinct profile with `provider_recognition=unrecognized` and `dispatch_error=unrecognized-provider`, names the bad token and recognized set on stderr, and exits 64.

## Feasible burn rate `B` (dynamic, not assumed)

`B` is never a hard-coded per-provider constant.

1. **History** (preferred): `data/usage-burn-history.json` under the active home (override with `FM_USAGE_BURN_HISTORY`).
   Each successful scored decision appends a sample `{provider, window_id, remaining, at}`.
   For the same provider+window, the latest pair with decreasing remaining yields `B = (R_prev - R_now) / (t_now - t_prev)`.
   Multiple recent positive samples average (bounded window).
2. **Prior from this snapshot**: if the window reports elapsed time and percent already used, `B_prior = percentUsed / max(elapsed, 1)`.
3. **Zero prior**: no history and no usable elapsed → `B = 0`, so `S = R` (honest "all remaining is at-risk until we learn burn").

Projections therefore move after every dispatch that records a sample.
There is no static ranking table and no single fixed remaining/time ratio used as the only score.

## Modular source adapters (single owner: `bin/fm-usage-source-lib.sh`)

Every usage source implements one plug surface.
Adapters emit a uniform observation JSON; the optimizer never parses provider-specific quota shapes.

### Plug surface (observation object)

```json
{
  "source_id": "claude",
  "class": "anthropic-class",
  "provider": "claude",
  "evidence": "fresh|stale|unknown",
  "unit": "percent",
  "windows": [
    {
      "id": "five_hour",
      "kind": "session",
      "remaining": 66.0,
      "resets_at_epoch": 1710000000,
      "window_seconds": 18000
    }
  ],
  "binding": {
    "id": "five_hour",
    "remaining": 66.0,
    "T": 3600,
    "window_seconds": 18000
  },
  "diagnostics": []
}
```

`binding` is the tightest general window (minimum remaining; soonest reset on ties).
`evidence=unknown` means the adapter could not produce a usable binding; `windows` may be empty.

### Provider registry

`fm_usage_source_registry` is the single owner of recognized provider identities, adapter classes, and meter kinds.
Both `fm-dispatch-select.sh` and `fm-spawn.sh` ask this registry whether a provider token is recognized.
Each row declares the quota identity, adapter class, and either `quota-axi` or `unmetered` as its meter kind.
The executable registry is the only current recognized-provider list.
An `unmetered` row always emits honest `evidence=unknown` until its meter kind and observation path are wired.

Provider is the quota identity; harness remains the launch adapter (`provider` may differ from `harness`, e.g. Claude via opencode).
Adapter class tokens such as `openai` are not provider aliases.
The selector refuses them instead of mapping them because a convenience mapping would hide a caller bug and could route against the wrong quota identity.

### Recipe: add a new agentic source

1. Choose a stable `provider` string (quota identity) and a `class` name (`*-class`).
2. Add one row to `fm_usage_source_registry` with meter kind `unmetered` until evidence is wired.
3. Implement a branch in `fm_usage_source_observe` (or a sourced sibling) that, given raw quota JSON or another meter, fills the plug surface.
   Prefer real remaining + `resetsAt` + window length; never invent numbers when the meter is missing.
4. Change that same registry row to the wired meter kind.
5. If the source is not in `quota-axi`, document the external meter command and wire it behind the same observation shape (optional env override for the command).
6. Add a unit test that fixtures the meter output and asserts binding + unknown degradation.
7. Optionally add a crew-dispatch example profile using the new `provider` with a verified harness.

No optimizer change is required when the plug surface is honored.
No selector or spawn refusal-path change is required when the registry row is added.

## Supersession and `config/crew-dispatch.json`

### What the engine owns

`bin/fm-dispatch-select.sh` is the routine decision path for multi-candidate selection and for admission observation.
Strategy name: `usage-burndown`.
Legacy alias: `quota-balanced` (same engine; kept so existing local configs and tests keep working without a forced rewrite).

Stdout remains one compact profile JSON for `fm-spawn.sh`:
`provider`, `harness`, `model`, `effort`, `provider_recognition`, `quota_posture`, optional `quota_percent_used`, plus `dispatch_strategy` and `dispatch_explain` for inspectability.
Stderr carries human-readable decision logs (inputs, per-candidate scores, chosen source, why).
An unrecognized-token error profile additionally carries `dispatch_error`, `unrecognized_providers`, and `recognized_providers`.

### What natural-language rules become

`config/crew-dispatch.json` is no longer a rival numeric selector.
Firstmate still uses judgment to pick the best-fit rule (`when` / `why`).
That rule supplies:

- the **eligible set** (`use` profiles: harness/model/effort/provider constraints and preferences);
- optional `select: "usage-burndown"` (or the legacy alias) when multiple profiles may run;
- single-object `use` or array-without-select as an explicit preference order (first profile), still admitted through the same observation path.

So rules are optional constraints and preferences consumed by the engine, not a second optimizer.
Captain per-task instructions still outrank everything (precedence in `AGENTS.md` section 4): when firstmate pins one profile from a captain instruction, that pin is admitted in place (`dispatch_explain` records `captain-or-explicit-pin`); the engine does not re-open multi-source selection.

### Freeze and posture

Posture thresholds remain observational (normal / conserve / protect / freeze at 60 / 80 / 90 percent used inclusive).
They annotate the admitted profile for fleet visibility and still gate freeze refusal for pins.
They do not rank multi-candidate winners.

## Compatibility

- `fm-spawn.sh` flags `--provider`, `--harness`, `--model`, `--effort`, `--quota-posture`, `--quota-used` keep working; spawn still re-admits through `fm-dispatch-select.sh --admit`.
- Missing/stale quota evidence for recognized providers: unknown posture, no silent freeze, no silent provider switch on explicit pins.
- Unrecognized provider token: distinct error profile and exit 64 before quota observation.
- Crewmate and scout spawn: explicit, dispatch-managed, and inherited provider pins are checked against the same usage-source registry before launch.
- Tests: colocated `tests/fm-usage-burndown-lib.test.sh`, `tests/fm-usage-source-lib.test.sh`, and updated `tests/fm-dispatch-select.test.sh`.
- Bootstrap accepts `usage-burndown` and the `quota-balanced` alias for `select`.

## Inspectability

Every multi-candidate decision logs:

1. candidate index, provider, harness, R, T, B, S, pressure, score, evidence, posture;
2. chosen index and one-line why (e.g. `highest expiry-weighted surplus`);
3. strategy name and whether history or prior supplied `B`.

Single-profile admit logs observation-only posture without claiming a multi-source optimization.

## Module map

| Path | Role |
| --- | --- |
| `bin/fm-usage-source-lib.sh` | Adapter plug surface + shipped classes |
| `bin/fm-usage-burndown-lib.sh` | Objective, scoring, history, explanation builder |
| `bin/fm-dispatch-select.sh` | CLI: resolve rule/profiles, call engine, admit, freeze |
| `docs/usage-burndown-dispatch.md` | This design note (policy owner for rationale) |
| `docs/configuration.md` | Schema pointer + short semantics |
| `AGENTS.md` §4 | Intake trigger + pointer only |
