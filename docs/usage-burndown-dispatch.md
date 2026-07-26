# Usage-burndown dispatch engine

Design note for the routine agent-routing decision path.
This document is the full statement of the policy.
Script headers own flags and wire shapes.
`AGENTS.md` section 4 keeps only the operating trigger and a pointer here.

Date: 2026-07-25.
Captain commission: route agents by remaining durable budget per remaining reset time, preferentially burn capacity that would otherwise expire unused, and make the mechanism run without an agent remembering to invoke it.

## Two window roles

A short rate window and a durable budget window are not interchangeable.
A short window is an eligibility gate only.
When a short window has no meaningful capacity, the provider cannot accept work now and is removed from the candidate set.
When the gate has capacity, its remaining amount and reset time have no effect on score.

The durable budget window is the only scored window.
Its remaining capacity is genuinely lost at reset, and spending from a short window also consumes this longer budget.
The spend floor applies to this budget, not to the rate gate.

`bin/fm-usage-source-lib.sh` stores role classification as provider-registry data:

| Provider | Gate windows | Scored budget | Ignored windows |
| --- | --- | --- | --- |
| `claude` | `five_hour` | `seven_day` | none |
| `codex` | `five_hour` | `weekly` | none |
| `grok` | `grokbuild` or `product:grokbuild` when reported | `credits` | `api`, `grokimagine`, `chat`, `voice`, and their `product:` forms |

The Grok `credits` pool is weekly, and the meter contract reports its true `windowSeconds` as `604800`.
Older observations that omit the field and observations that report explicit `null` remain unknown rather than inheriting that number from provider identity.
The engine learns an unknown period only after distinct observed `resetsAt` values establish it.
The Grok Build product pool gates whether the Grok coding harness can accept work, while API, image, chat, and voice product pools are irrelevant to that harness and are ignored.
A new window not named by a configured provider policy is recorded as `unclassified` rather than silently treated as ignored.

A provider with exactly one usable non-model window and no configured role policy treats that window as both gate and budget.
A provider with multiple unclassified windows degrades to `evidence=unknown` because choosing a durable budget would be a guess.
Missing gate evidence cannot prove that a provider is rate-limited.

## Objective

For each eligible provider, the budget window supplies:

| Symbol | Meaning |
| --- | --- |
| `R` | Budget percent remaining |
| `T` | Seconds until the budget resets |
| `W` | Observed or reset-history-derived budget period in seconds |
| `B` | Counterfactual non-preferential burn rate in percent per second |
| `F` | Protected budget floor in percent remaining |
| `S` | Spendable capacity projected to expire without preferential routing |

The equations are:

```text
spendable = max(0, R - F)
S = max(0, spendable - B*T)
required_rate = S/T
urgency = clamp(1 - T/W, 0, 1)       when W is known
pressure = 1 + K*urgency^2            when S > 0 and W is known
pressure = 1                          otherwise
score = required_rate * pressure
```

`required_rate` implements "most remaining usage per remaining time."
`pressure` is a modifier that makes a nearly ended budget window more urgent when its true period is known.
`K` defaults to 4 and is configurable with `FM_BURNDOWN_PRESSURE_K`.
`F` defaults to 5 and is configurable with `FM_BURNDOWN_SPEND_FLOOR`.
The rate-gate boundary defaults to 0 and is configurable with `FM_BURNDOWN_RATE_FLOOR`.

Higher score wins.
The complete deterministic order is score descending, `S` descending, `R` descending, `T` ascending, then configured profile index ascending.
The last step is a total tie-break because every candidate has one unique index.

Posture remains observational.
Budget usage at 60 percent is `conserve`, usage at 80 percent is `protect`, and budget remaining at or below `F` is `freeze`.
Multi-candidate routing excludes a frozen budget when any live candidate exists.
An explicit pin at the floor refuses in place with exit 75 and never substitutes another provider.
An exhausted rate gate also refuses an explicit pin in place with exit 75.

## What `B` means

`B` means how much budget is expected to be consumed before reset if the next dispatch does not preferentially route to this provider.
It is a counterfactual baseline, not an extrapolation of consumption that routing itself caused.

The previous implementation used `percentUsed / elapsed`.
That snapshot prior was circular because a routed burst increased projected future burn, collapsed that provider's surplus to zero, and caused routing to stop using the budget that needed burn-down.
The same problem affected history because only selected-provider samples were recorded.

Every scored decision now records a sample for every candidate with an explicit `selected` boolean.
For one provider and reset window, `B` divides total positive depletion by total time across intervals whose opening decision did not select that provider.
Qualifying zero-depletion intervals count as zero background demand rather than disappearing from the estimate.
Intervals opened by selecting the provider and legacy samples without `selected` are ignored.
If no qualifying interval exists, `B=0` with source `counterfactual-zero`.

The available evidence cannot identify a perfect causal counterfactual.
An already-running task can continue consuming after a later decision routes elsewhere, and unrelated clients can consume the same quota.
The estimate assumes consumption observed after a non-selection decision is the best available proxy for background demand that does not require the next preferential route.
This is deliberately conservative: when that evidence is absent, all spendable budget is treated as at risk.

History lives at `data/usage-burn-history.json` under the active home.
`FM_USAGE_BURN_HISTORY` overrides the path for fixtures.

## What `W` means

`W` is accepted from a meter only when the meter actually reports a positive `windowSeconds`; the updated `quota-axi` contract reports Grok's real weekly value as `604800`.
An explicit `null` is unknown, and an absent field from an older meter is also unknown.
There are no provider or window-id duration constants.
In particular, `credits` never implies 24 hours.

When the meter omits `W`, the engine compares distinct recorded `resetsAt` values for the same provider and window id.
A positive change supplies `W` with source `history-reset-period`.
This assumes the two recorded reset boundaries are successive; a missed whole period can make the learned period too large, and the explanation exposes the source so that assumption is auditable.
Until a period is observed, `W` and urgency remain null and pressure stays neutral at 1.
The provider may still compete on the directly observed `R`, `T`, and counterfactual `B`; the engine never fabricates urgency.

## Missing evidence and fail-safe dispatch

Unknown or unusable evidence for a recognized provider never fabricates `R`, `T`, `W`, `B`, freeze, or rate exhaustion.
A known candidate outranks an unknown candidate during normal scoring.
When no known live candidate remains, the first unknown candidate is retained with `quota_posture=unknown`.
Missing `quota-axi`, malformed JSON, an unwired recognized provider, and an unclassifiable window shape therefore do not refuse routine work.
The emitted profile still carries one unknown row for every configured candidate.

An unrecognized provider token is caller input failure rather than missing evidence.
It emits `provider_recognition=unrecognized`, `dispatch_error=unrecognized-provider`, the bad and recognized provider sets, and exits 64.

## Self-routing spawn and overrides

`bin/fm-spawn.sh` is the routine mechanism.
When `config/crew-dispatch.json` exists and a new crewmate or scout receives no routing axes, spawn reads the configured `default`, invokes `usage-burndown`, and launches the returned provider, harness, model, and effort.
The default may be one profile or a dispatch object with `use` candidates and `select:"usage-burndown"`.
The documented example uses a candidate set.
Batch spawns re-enter the same single-task path, so every unpinned task obtains its own deterministic decision.

Caller-supplied provider, harness, model, or effort is an intentional override.
A new override under active dispatch config requires `--override-reason` and a concrete provider plus harness.
The exact profile is admitted in place and never reopened as a multi-provider choice.
Existing task pins and bounded child inheritance remain stable without being mislabeled as a new human override.

Task metadata distinguishes the paths:

```text
dispatch_origin=algorithm|override|inherited|resume
dispatch_override_reason=<one line, override only>
dispatch_strategy=usage-burndown
dispatch_explain=<chosen calculation>
dispatch_candidates_json=<compact array of every candidate and every score input>
dispatch_selected_index=<configured candidate index>
dispatch_tie_break=profile-order
dispatch_order=score-desc,S-desc,R-desc,T-asc,index-asc
```

`dispatch_candidates_json` includes evidence, eligibility, window roles, binding reason, `R`, `T`, `W` and its source, `B` and its source, `S`, required rate, urgency, pressure, score, posture, and floors.
This record makes "the algorithm chose this" distinguishable from "a human overrode it for this reason" without reconstructing logs.

## Configuration and compatibility

`config/crew-dispatch.json` remains local and human-editable.
Natural-language rules can still constrain unusual task classes, but routine no-argument spawn does not require an agent to choose a provider or remember to invoke the selector.
`docs/examples/crew-dispatch.json` is the starting point.

Strategy name is `usage-burndown`.
The legacy alias `quota-balanced` invokes the same engine.
`--admit` and `--resume-meta` remain single-profile paths.
Recognized providers without a meter remain admissible with unknown posture.
Bootstrap validates both rule candidate sets and default candidate sets.

## Inspectability

Every decision prints one stderr line per candidate.
Each line includes provider, harness, evidence, gate eligibility, posture, budget id and binding reason, window roles, `R`, `T`, `W` and source, `B` and source, `S`, required rate, urgency, pressure, and score.
The selected profile carries the same candidate array in `dispatch_candidates`.
Spawn persists that array in task metadata.

## Module map

| Path | Role |
| --- | --- |
| `bin/fm-usage-source-lib.sh` | Provider registry, role classification, and observation adapter |
| `bin/fm-usage-burndown-lib.sh` | Counterfactual history, period learning, scoring, selection, and explanation |
| `bin/fm-dispatch-select.sh` | Selector and admission CLI |
| `bin/fm-spawn.sh` | Automatic default routing, explicit override boundary, and metadata record |
| `docs/configuration.md` | Config schema and operational flags |
| `docs/examples/crew-dispatch.json` | Default candidate-set example |
