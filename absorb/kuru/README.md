# Absorption candidate: usage-evidence contract (for KURU)

This directory holds work **destined for KURU**, staged here because
`/Users/cal/kuru` is read-only to this lane and no repository may be created.
Nothing here is wired into firstmate at runtime.

## What this is, and why it is not what was originally asked for

The brief asked to prove native Python absorption of **usage/quota evidence** into
KURU. Reading KURU's own specification first changed the answer, and the evidence
is worth stating plainly because it saved building the wrong thing.

**KURU already has the capability.** `tools/usage-burndown` is 1,028 lines of
native Python 3 with no third-party imports, carrying registered adapters for
anthropic-class, openai-class, grok-class, gemini-class, and openrouter-class
through one plug surface. Absorbing quota-axi's routing would re-implement working
code.

**And the specification forbids absorbing the rest.** Decision
`0028-usage-burndown-routing.md` states the selector:

> …**makes no subprocess call at all** (no external-organ-dispatch shell-out, no
> quota-axi shell-out). Usage evidence is caller-supplied organ evidence JSON only.

with the Brain owning routing and organs reporting windows only. Vendor decoding —
Claude OAuth files, Codex CLI-RPC, Grok protobuf — is organ work by design. Moving
it into base would put credential-store reading inside the Brain and take exactly
the adapter/wrapper/facade shape the specification prohibits.

**So the gap is neither half. It is the boundary between them.**
`tools/usage-burndown` reads `percentRemaining` from supplied windows and, when
the shape does not match, degrades to posture `unknown` — honestly, but silently.
Downstream, silent degradation is indistinguishable from "this provider has no
quota pressure."

That is not hypothetical. It is the failure this lane was commissioned over.

## The two realized regressions, reproduced

Both were reproduced by building genuine upstream `main` (`a9ca3e1`, published as
`0.1.13`) and capturing its real output — not by writing a strawman fixture:

```
{"provider":"grok","status":"fresh","ids":[
  {"id":"credits","ws":null},
  {"id":"product:grok_build","ws":null},
  {"id":"product:api","ws":null},
  {"id":"product:imagine","ws":null},
  {"id":"product:chat","ws":null},
  {"id":"product:voice","ws":null}]}
```

1. **Identifier drift.** `product:grokbuild` → `product:grok_build` and
   `product:grokimagine` → `product:imagine`, with no major version bump and no
   deprecation. A consumer keyed on the published names reads nothing.
2. **Discarded window length.** Every `windowSeconds` is `null`: the adapter
   decoded each billing period, validated with it, then dropped it. A router
   without a window length cannot compute time-to-reset.

That capture is frozen, scrubbed to structural fields only, as
`tests/fixtures/usage-evidence/upstream-0.1.13-regressed.json`.

## What is here

| File | Role |
|---|---|
| `usage_evidence_contract.py` | the mechanism: judges organ evidence against a pinned contract, exits 12 on violation |
| `usage-evidence-contract.json` | the pinned contract; every id observed from live output, none invented |

Both are **stdlib-only Python 3**, so absorbing them adds nothing to KURU's
measured minimum of Python 3.10 plus PyYAML. Tests assert that property rather
than trusting it, and assert the no-subprocess prohibition from 0028 against the
source.

```sh
python3 absorb/kuru/usage_evidence_contract.py check \
  --evidence <organ-evidence.json> \
  --contract absorb/kuru/usage-evidence-contract.json
```

Exit codes follow the `tools/` convention: 0 ok, 2 usage, 11 malformed input,
**12 contract violation**.

## What it catches

| Code | Catches |
|---|---|
| `identifier-drift` | a pinned window id renamed or dropped — including a **partial** rename |
| `vocabulary-drift` | the whole identifier vocabulary replaced |
| `window-field-missing` / `window-seconds-invalid` | a window with no usable length, the realized Grok regression |
| `percent-out-of-range` | a remaining value outside [0, 100] |
| `fresh-but-empty` | a decoder reporting `fresh` while emitting nothing |
| `provider-absent` | a required provider silently disappearing |
| `state-missing` | evidence whose freshness is unknowable |

### The partial-rename lesson

The first implementation asked "did any pinned id survive?" — and **passed the
real regression**, because four of the six Grok ids were untouched. Ids whose
disappearance must fail are now pinned individually as `requiredWindowIds`. This
is the kind of detail a later repetition gets wrong, so it is recorded here and in
`docs/dependency-custody.md`.

## Landing it in KURU

Captain-gated; nothing here assumes it has happened.

1. Copy both files into KURU's `tools/` alongside `usage-burndown`, renaming to
   the tool's own convention.
2. Wire it wherever organ evidence enters — a check before `usage-burndown score`
   consumes it — so a violation is a red check rather than a quiet `unknown`.
3. Move `tests/fixtures/usage-evidence/` into KURU's test fixtures and port
   `tests/fm-usage-evidence-contract.test.sh` to KURU's test idiom. The
   assertions transfer directly; only the harness changes.
4. Keep the pins current: a rename is a **reviewed edit** to the contract, in the
   same commit that updates every consumer. That cost is the entire point.

## The honest limit

This makes a decoder regression loud; it cannot make it not happen. Vendor API
decoding is irreducible maintenance — Grok will change its protobuf again, and no
contract prevents that. What a contract changes is *when you find out*: on the day
it ships, as a red check naming the field, instead of months later as routing that
was quietly wrong. That is the whole claim, and it is worth being precise that it
is the only one being made.
