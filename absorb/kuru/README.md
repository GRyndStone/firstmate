# Absorption candidate: usage-evidence contract (for KURU)

This directory holds work **destined for KURU**, staged here because
`/Users/cal/kuru` is read-only to this lane and no repository may be created.
Nothing here is wired into firstmate at runtime.

## What this is, and why it is not what was originally asked for

The brief asked to prove native absorption of **usage/quota evidence** into KURU.
Reading KURU's own specification first changed the answer, and the evidence is
worth stating plainly because it saved building the wrong thing.

> **Premise update (captain decision, authoritative):** KURU unifies on
> **TypeScript running on Bun**. The original framing of this work was
> Python-plus-PyYAML. The conclusion below is unchanged, but one of its two
> supporting arguments is void under the new destination. See
> "Re-derivation under the Bun/TypeScript destination" at the end of this file
> before relying on it.

**KURU already has the capability.** `tools/usage-burndown` is ~1,028 lines with
no third-party imports, carrying registered adapters for anthropic-class,
openai-class, grok-class, gemini-class, and openrouter-class through one plug
surface. Absorbing quota-axi's routing would re-implement working code. (It is
Python today, behind a `#!/bin/sh` polyglot entrypoint added in `0b315e6`, and is
therefore itself a port item under the Bun/TypeScript decision.)

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

Both are **dependency-free**: no third-party imports at all. Tests assert that
property rather than trusting it, and assert the no-subprocess prohibition from
0028 against the source. The mechanism is Python and runs on 3.9+ (verified in a
clean `env -i` shell), but under the Bun/TypeScript decision it is a reference
implementation to port, not the shipping form — see the re-derivation below.

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

## Re-derivation under the Bun/TypeScript destination

The captain's decision that KURU unifies on TypeScript running on Bun changes one
of the two arguments above. Stating plainly which:

**Void: the idiom argument.** "Never vendor TypeScript into a Python base" was a
real constraint and it is gone. The axi family is already TypeScript and now
shares the destination runtime, so absorbing quota-axi wholesale is no longer
blocked by language, and `axi-sdk-js` would be absorbed once for five dependents
rather than five times. This was the stronger of the two arguments.

**Holds: the architectural argument.** `docs/specification/product.md` line 713 —
"The Brain owns routing; organs report windows only" — is language-independent.
It still forbids KURU base from decoding vendor quota APIs, in TypeScript exactly
as in Python. That clause, and only that clause, is now what separates "absorb the
contract" from "absorb quota-axi entirely."

**So the recommendation stands on a narrower base than it did.** It is now a
single architectural decision the captain can revisit, not a language constraint
that decides itself. If the captain rules that the Brain may decode vendor
evidence directly, absorbing quota-axi's decoders becomes the cheaper answer and
this contract becomes an internal invariant of that code rather than a boundary
check between two systems. Either way the *rules* below are what is worth keeping.

### Specification items this creates

Named rather than worked around:

1. **`docs/specification/decisions/0028-usage-burndown-routing.md`, lines 64-65**
   prohibits "**no subprocess call at all** (no external-organ-dispatch shell-out,
   no quota-axi shell-out)". Once both sides share one runtime, the natural
   integration is an in-process import, which this text does not address. Not
   contradicted — bypassed. 0028 should state its position on in-process import.
2. **`docs/specification/product.md`, line 713** is the clause that would actually
   have to change for KURU to absorb the decoders. A genuine architectural
   decision, so it is the captain's.
3. **`tools/usage-burndown` and its `python-entrypoint` shim need a TypeScript/Bun
   target.** Not this lane's work; recorded because the absorption question sits
   directly on top of that file.

### What ports, and what does not

| Piece | Under Bun/TS |
|---|---|
| `usage-evidence-contract.json` (the pins) | **ports unchanged** — it is data |
| `tests/fixtures/usage-evidence/*.json` | **port unchanged** — captured evidence |
| the rules (drift, partial rename, window length, fresh-but-empty) | **port unchanged** — logic, not syntax |
| `usage_evidence_contract.py` | **needs rewriting in TypeScript** — ~250 lines |

The valuable part — which regressions to catch, which identifiers to pin, and why
a partial rename defeats a naive check — is idiom-neutral. Only the file it is
spelled in changes.
