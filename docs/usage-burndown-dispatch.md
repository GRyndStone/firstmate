# Usage-burndown dispatch engine

Design note for the routine agent-routing decision path.
This document is the full statement of the policy.
Script headers own flags and wire shapes.
`AGENTS.md` section 4 keeps only the operating trigger and a pointer here.

Date: 2026-07-26 (formula revision).
Captain commission: route agents by remaining durable budget per remaining reset time, preferentially burn capacity that would otherwise expire unused, and make the mechanism run without an agent remembering to invoke it.

Captain formula (2026-07-26, amended to keep the near-expiry amplifier):

1. Default target for known providers is 5 percent remaining (safe minimum); claude is 10 percent.
2. Score each provider as `(remaining usage % - target %) / remaining time`.
3. Codex gets a 1.5x multiplier per available rate-limit reset, compounding.
4. Highest result is the routing target unless manually specified.
5. **Amendment:** retain the squared-urgency near-expiry amplifier exactly as today
   (`1 + K*urgency^2`, `K=4`, `urgency=clamp(1-T/W,0,1)`). Only the `B*T` burn-rate
   subtraction is removed.

## Two window roles

A short rate window and a durable budget window are not interchangeable.
A short window is an eligibility gate only.
When a short window has no meaningful capacity, the provider cannot accept work now and is removed from the candidate set.
When the gate has capacity, its remaining amount and reset time have no effect on score.

The durable budget window is the only scored window.
Its remaining capacity is genuinely lost at reset, and spending from a short window also consumes this longer budget.
The per-provider target floor applies to this budget, not to the rate gate.

`bin/fm-usage-source-lib.sh` stores role classification and target floors as provider-registry data:

| Provider | Gate windows | Scored budget | Target floor | Ignored windows |
| --- | --- | --- | ---: | --- |
| `claude` | `five_hour` | `seven_day` | **10** | none |
| `codex` | `five_hour` | `weekly` | 5 | none |
| `grok` | `grokbuild` or `product:grokbuild` when reported | `credits` | 5 | `api`, `grokimagine`, `chat`, `voice`, and their `product:` forms |
| `gemini` | (unmetered) | — | 5 | — |
| `openrouter` | (unmetered) | — | 5 | — |
| `cursor` | (policy empty until wired) | — | 5 | — |
| `copilot` | (policy empty until wired) | — | 5 | — |

Targets are registry column data next to window-role policy, not a special-case branch inside the scoring expression.
A known provider without an explicit numeric target falls back to 5 (never 0 or 10 by invention).
Unrecognized provider tokens are caller input failure, not a fabricated target.

The Grok `credits` pool is weekly, and the meter contract reports its true `windowSeconds` as `604800`.
Older observations that omit the field and observations that report explicit `null` remain unknown rather than inheriting that number from provider identity.
The engine learns an unknown period only after distinct observed `resetsAt` values establish it.
The Grok Build product pool gates whether the Grok coding harness can accept work, while API, image, chat, and voice product pools are irrelevant to that harness and are ignored.
A new window not named by a configured provider policy is recorded as `unclassified` rather than silently treated as ignored.

A provider with exactly one usable non-model window and no configured role policy treats that window as both gate and budget.
A provider with multiple unclassified windows degrades to `evidence=unknown` because choosing a durable budget would be a guess.
Missing gate evidence cannot prove that a provider is rate-limited.

## Objective

For each eligible provider, the budget window and registry supply:

| Symbol | Meaning |
| --- | --- |
| `R` | Budget percent remaining |
| `T` | Seconds until the budget resets |
| `W` | Observed or reset-history-derived budget period in seconds |
| `F` | Per-provider target floor (percent remaining) |
| `H` | Headroom above target: `max(0, R - F)` |
| `score_base` | `H / T` when `T > 0`, else 0 |
| `urgency` | `clamp(1 - T/W, 0, 1)` when `W` is known, else null |
| `K` | Urgency amplifier coefficient (default 4) |
| `base_pressure` | `1 + K*urgency^2` when `H > 0` and `W` known, else 1 |
| `N` | Available Codex rate-limit resets (codex only) |
| `C` | Codex reset factor base (default 1.5) |
| `reset_factor` | `C^N` for codex; `1` for every other provider |
| `pressure` | `base_pressure * reset_factor` |
| `score` | `score_base * pressure` |

The equations are:

```text
H = max(0, R - F)
score_base = H / T                 when T > 0, else 0
urgency = clamp(1 - T/W, 0, 1)     when W is known
base_pressure = 1 + K*urgency^2    when H > 0 and W is known
base_pressure = 1                  otherwise
reset_factor = C^N                 provider=codex only; N available rate-limit resets
reset_factor = 1                   every other provider
pressure = base_pressure * reset_factor
score = score_base * pressure
```

Net change from the prior engine:

1. Per-provider target floors replace the single global floor (`F`).
2. The `B*T` burn-rate subtraction is gone; the numerator is exactly `R - F`.
3. The `1 + K*urgency^2` amplifier is **retained unchanged**.
4. The codex `1.5^N` reset factor is retained unchanged.
5. Highest score wins unless explicitly pinned.

**Removed from the score path** (do not reintroduce as a second opinion, tiebreak, or env-gated alternate mode):

- `B*T` counterfactual burn-rate subtraction

Burn-history samples may still be recorded for observational analysis; they never multiply or subtract on the score path.

`K` defaults to 4 and is configurable with `FM_BURNDOWN_PRESSURE_K`.
`C` defaults to 1.5 and is configurable with `FM_BURNDOWN_CODEX_RESET_PRESSURE_FACTOR`.
The rate-gate boundary defaults to 0 and is configurable with `FM_BURNDOWN_RATE_FLOOR`.
Only the registry provider id `codex` receives the reset factor (not class tokens such as `openai`).

Higher score wins.
The complete deterministic order is score descending, headroom (`H`/`S`) descending, `R` descending, `T` ascending, then configured profile index ascending.
The last step is a total tie-break because every candidate has one unique index.

Posture remains observational.
Budget usage at 60 percent is `conserve`, usage at 80 percent is `protect`, and budget remaining at or below that provider's target `F` is `freeze`.
Multi-candidate routing excludes a frozen budget when any live candidate exists.
An explicit pin at the floor refuses in place with exit 75 and never substitutes another provider.
An exhausted rate gate also refuses an explicit pin in place with exit 75.

## What `W` means

`W` is accepted from a meter only when the meter actually reports a positive `windowSeconds`; the updated `quota-axi` contract reports Grok's real weekly value as `604800`.
An explicit `null` is unknown, and an absent field from an older meter is also unknown.
There are no provider or window-id duration constants.
In particular, `credits` never implies 24 hours.

When the meter omits `W`, the engine compares distinct recorded `resetsAt` values for the same provider and window id.
A positive change supplies `W` with source `history-reset-period`.
Until a period is observed, `W` and urgency remain null and `base_pressure` stays neutral at 1.
The provider may still compete on the directly observed `R`, `T`, and `F`; the engine never fabricates urgency.

## Codex rate-limit reset multiplier

ChatGPT/Codex accounts can hold **rate-limit reset credits**: free one-shot grants that fully refill Codex rate limits.
They are a wasting asset: each credit expires if the account never burns enough Codex usage to need it.
The captain's rule therefore multiplies **codex score only** by `C^N` for each genuinely available reset (`C=1.5` by default, compounding).

### Observed source shape (live)

`quota-axi` does **not** surface this field today.
Its Codex normalizer keeps only `credits.balance` / `credits.unlimited` and discards every other credits-adjacent field, including the reset grant list.
The raw Codex app-server RPC `account/rateLimits/read` (cli-rpc) does carry it:

```text
rateLimitResetCredits: {
  availableCount: <int>,
  credits: [
    {
      resetType: "codexRateLimits",
      status: "available" | ...,
      grantedAt: <epoch seconds>,
      expiresAt: <epoch seconds>,
      title: ...,
      description: ...
    }
  ]
}
```

The OAuth HTTP usage endpoint exposes a thinner shape under `rate_limit_reset_credits` with `available_count` / `applicable_available_count` and no per-credit expiry list.
Firstmate's live path observes the app-server object read-only (never redeems or consumes a reset), attaches it onto the codex provider blob before scoring, and never prints credentials, tokens, account ids, or credit ids.

### Counting rules

| Observation | `N` | Factor | Notes |
| --- | --- | --- | --- |
| credits array present | count of items with `status=available` and (`expiresAt` absent or `expiresAt > now`) | `C^N` | per-item filter is authoritative over `availableCount` |
| only `availableCount` / `available_count` present | that non-negative integer | `C^N` | HTTP shape; no per-item expiry filter possible |
| successful read, section absent | `0` | `1` | genuine zero |
| all credits expired or consumed | `0` | `1` | source `credits-array-all-expired` is distinct from absent |
| malformed count / probe failure | unreadable (`null`) | `1` (neutral) | ERROR on stderr; **not** a silent zero; windows stay scorable |

Unreadable reset evidence for `codex` is a **loud named error**, never a silent zero: stderr prints `error: unreadable rate-limit reset credits for provider 'codex': <cause>`, `pressure_source` includes `codex-reset-unreadable`, and `reset_available_count` stays null so it cannot be mistaken for a genuine zero.
It does **not** poison otherwise-valid window evidence: the budget/gate windows remain scorable with neutral reset factor 1, and the provider is not added to `unreadable_providers` / `dispatch_error=usage-evidence-unreadable` solely because the reset probe failed.
Window-level unreadable usage (missing meters, exhausted evidence) is unchanged and still uses that stricter path.

### Worked example

Two live candidates, same `T` and `W`, `K=4`, `C=1.5` (identical base pressure):

| Provider | `R` | `F` | headroom | `score_base` | base pressure | `N` | `reset_factor` | pressure | wins? |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| claude | 90 | 10 | 80 | 80/T | ~1.64 | n/a | 1 | ~1.64 | no |
| codex | 60 | 5 | 55 | 55/T | ~1.64 | 2 | 2.25 | ~3.69 | **yes** |

Without the reset rule, claude's higher headroom would win on `score_base * base_pressure`.
With two available Codex resets, codex pressure is multiplied by `1.5^2 = 2.25`, so the decision prefers burning Codex while the wasting resets still exist.
The selection explanation and each candidate line surface `target`, `headroom`, `score_base`, `urgency`, `base_pressure`, `reset_factor`, `resets=N/source`, and `score` so a surprising ranking is auditable six months later.

## Missing evidence and loud errors

Unknown or unusable evidence for a recognized provider never fabricates `R`, `T`, `F`, freeze, rate exhaustion, or a Codex reset count.
A known scorable candidate outranks an unknown candidate during normal scoring.

Metered providers (adapter meter kind `quota-axi`) must yield readable usage.
When they do not, that is an ERROR, not a silent degradation:

- stderr prints `error: unreadable usage evidence for provider '<name>': <reason>` so an operator sees it without inspecting JSON
- the profile carries `dispatch_error=usage-evidence-unreadable` and `unreadable_providers`
- when at least one live scorable candidate remains, the engine still selects among live candidates so one down provider does not strand the fleet, but the decision is marked with the error fields and cannot look like clean success
- when no live scorable candidate remains, the selector refuses with exit 70

Missing `quota-axi`, malformed meter JSON, and total meter failure refuse the same way (exit 70).
They never silently retain the first configured profile.

Unmetered recognized providers (no meter wired yet, such as `gemini` and `openrouter`) may still report honest `evidence=unknown` and remain admissible with `quota_posture=unknown`.
That path is distinct from a metered read failure.

Stale-but-current general-window numbers remain scorable under adapter rules, and the selector always logs a stderr warning naming the provider and that a cached snapshot is being used, so cached-vs-live cannot pass unnoticed.

An unrecognized provider token is caller input failure rather than missing evidence.
It emits `provider_recognition=unrecognized`, `dispatch_error=unrecognized-provider`, the bad and recognized provider sets, and exits 64.

### Live meter fetch

`bin/fm-usage-source-lib.sh` owns `fm_usage_source_fetch_quota_json`.
It is the only path that invokes the live meter for dispatch, and it always passes `--allow-keychain-prompt` so macOS Claude (and other Keychain-backed providers) refresh from Keychain rather than a broken file credential store.
On non-macOS hosts the flag is accepted and is a no-op when no Keychain exists.
Fixtures use `--quota-json` and never call the live meter.

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

`dispatch_candidates_json` includes evidence, eligibility, window roles, binding reason, `R`, `T`, `W` and its source, `target_percent`, `headroom`, `score_base`, urgency, base_pressure, `reset_pressure_factor`, `reset_available_count`, score, posture, and floors.
A reader can reconstruct `score = ((R - target_percent) / T) * base_pressure * reset_pressure_factor` from those fields alone.
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
Each line includes provider, harness, evidence, gate eligibility, posture, budget id and binding reason, window roles, `R`, `T`, `W`, target, headroom, score_base, urgency, base_pressure, pressure, codex reset factor when applicable, score, and the formula label `((R-target)/T)*(1+K*urgency^2)` (plus `*C^N` for codex).
The selected profile carries the same candidate array in `dispatch_candidates`.
Spawn persists that array in task metadata.

## Module map

| Path | Role |
| --- | --- |
| `bin/fm-usage-source-lib.sh` | Provider registry (window roles + per-provider targets) and observation adapter |
| `bin/fm-usage-burndown-lib.sh` | Target-rate scoring, selection, explanation, observational history |
| `bin/fm-dispatch-select.sh` | Selector and admission CLI |
| `bin/fm-spawn.sh` | Automatic default routing, explicit override boundary, and metadata record |
| `docs/configuration.md` | Config schema and operational flags |
| `docs/examples/crew-dispatch.json` | Default candidate-set example |
