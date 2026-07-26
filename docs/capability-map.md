# Capability map: what survives firstmate's retirement

Firstmate is transitional. It is scheduled for retirement once KURU handles everything,
so the question about its third-party tools is **not** "where should these live".
It is:

> What capabilities must KURU have natively for firstmate to become unnecessary,
> and which of these tools are merely standing in for those capabilities today?

A tool that dies with firstmate should not be folded, absorbed, or maintained at all.
That is the cheapest possible outcome, and this map is written looking for it.

Every count below was measured, not assumed. Method is stated per row so a later
reader can re-run it rather than trust it.

## Measurement method

KURU reference counts are tracked files on `origin/main` of the KURU repository:

```sh
cd projects/kuru && git grep -Il -- "<tool>" origin/main | wc -l
```

Counting the working tree instead inflates every number with untracked corpus and
run artifacts; counting only `tools/` misses specification and decision records.
Both mistakes were made during this lane before the method above was settled.

## The map

| Tool | Capability it stands for | KURU files | Where those references are | Survives retirement? |
|---|---|---:|---|---|
| `treehouse` | isolated workspace leasing for parallel work | 28 | 20 `docs/evidence`, 7 `agent/work`, 1 `docs/history` — **no code, no specification** | **Capability yes, tool no** |
| `quota-axi` | usage evidence for routing | 14 | 9 `docs/history`, **2 `docs/specification`**, 1 `tools`, 1 `tests`, 1 `docs/evidence` | **Split — see below** |
| `no-mistakes` | change validation gate | 7 | 6 `docs/history`, 1 `docs/specification` | Open product question |
| `lavish-axi` | rich human review surface | 2 | 2 `docs/history` — no code, no specification | Probably, but unevidenced |
| `tasks-axi` | durable work queue with dependencies | 0 | — | **No — KURU already has a work graph** |
| `gh-axi` | delivering change to a code host | 0 | — | Only if KURU delivers to hosts |
| `chrome-devtools-axi` | browser operation | 0 | — | Unevidenced |
| `gnhf` | nothing | 0 | zero references in KURU **and zero in firstmate** | **No — drop it** |

### Correction to the earlier estimate

An earlier pass reported `treehouse` = 7 and `quota-axi` = 1. Both were undercounts
(the real figures are 28 and 14). The **conclusions** drawn from them nevertheless
held, and the `quota-axi` case is *stronger* than that pass argued: its references
are not merely a tool, they reach `docs/specification/product.md` and
`docs/specification/decisions/0028-usage-burndown-routing.md`. Wrong numbers, right
direction — worth recording because the next person to run this should trust the
method, not the memory.

## Row by row

### `treehouse` — capability survives, tool does not

Work has to run somewhere isolated, so "lease an isolated workspace" is a real
capability that outlives firstmate. But every one of KURU's 28 references is a
historical worktree path in evidence and run records. **No KURU code invokes
treehouse and no specification requires it.**

It is firstmate-shaped: it exists because firstmate spawns many crewmates into a
pooled worktree set. Whatever replaces firstmate will need workspace isolation, but
it will need it in that system's idiom, not as this Go CLI. Folding it now would be
maintaining 11,366 lines of Go for a consumer scheduled for demolition.

**Disposition: do not fold. Keep using upstream as-is until retirement.** It is the
highest-consequence dependency in the fleet today (if it breaks, nothing dispatches),
so it gets the interim custody posture in `docs/dependency-custody.md` — a pinned,
verifiable local build available if upstream breaks us — and nothing more.

### `quota-axi` — the capability is already native; the gap is elsewhere

This is the one row where the honest answer differs from what this lane was
originally asked to build, so the evidence is given in full.

KURU decision `0028-usage-burndown-routing.md` states that the selector:

> …**makes no subprocess call at all** (no external-organ-dispatch shell-out, no
> quota-axi shell-out). Usage evidence is caller-supplied organ evidence JSON only.

and:

> Usage evidence arrives through the **organ-evidence relationship**… The Brain owns
> routing; organs report windows only. The selector **must not** shell out to or wrap
> external organ dispatch scripts.

So KURU's specification already draws the line this lane was trying to find:

- **Routing on usage evidence is KURU-native and already built.** `tools/usage-burndown`
  is ~1,028 lines with no third-party imports, carrying registered adapters for
  anthropic-class, openai-class, grok-class, gemini-class, and openrouter-class
  through one plug surface. Absorbing quota-axi's routing would be re-implementing
  something that already exists. (It is Python today and therefore a port item
  under the Bun/TypeScript decision — see the re-derivation below.)
- **Vendor decoding must NOT move into KURU base.** Reading Claude OAuth files, Codex
  CLI-RPC, and Grok protobuf is organ work by design. Moving it into base would put
  credential-store reading inside the Brain and would be exactly the
  adapter/wrapper/facade shape the specification prohibits.

**The actual gap is the boundary between them.** `tools/usage-burndown` reads
`percentRemaining` from supplied windows and, when the shape does not match,
degrades to posture `unknown` — honestly, but *silently*. That is precisely the
failure this lane was commissioned over: between `0.1.5` and `0.1.13` upstream
renamed normalized product ids (`product:grokbuild` → `product:grok_build`,
`product:grokimagine` → `product:imagine`), and a consumer keyed on those names
starts reading nothing with no error and no failed exit.

A silent degrade-to-unknown is a decoder that returns nothing. What is missing is a
**contract that fails loudly**.

**Disposition: absorb the evidence contract, not the decoders.** See
`absorb/kuru/README.md`. This disposition is unchanged by the Bun/TypeScript
decision, but the *reason* for it narrows to a single architectural clause — read
"Re-derivation under the Bun/TypeScript destination" below before relying on it.

### `no-mistakes` — already the captain's own, and an open question

Already independently owned as `GRyndStone/no-mistakes` (private, **not** a fork).
It appears once in KURU's specification. Whether change-validation survives as a
KURU capability is a product question above this lane's pay grade; recorded so it is
visible rather than assumed.

### `tasks-axi` — dies with firstmate

Zero KURU references. KURU already has its own work graph, and the addendum's own
framing names the overlap. Two durable work queues is one too many.

**Disposition: do not fold. Do not absorb. It dies with firstmate.** This is the
cheapest outcome available and it should be taken deliberately.

### `gh-axi`, `chrome-devtools-axi`, `lavish-axi` — unevidenced, decide later

Zero, zero, and two (history-only) KURU references. Each *might* correspond to a
post-retirement capability — delivering change to a host, driving a browser,
reviewing rich output — but none is in KURU's specification today. Folding on a
guess is the expensive mistake this map exists to prevent.

**Disposition: no action. Re-evaluate when KURU's specification asks for the
capability.**

### `gnhf` — drop it

Zero references in KURU **and zero in firstmate** (verified: `grep -rIl gnhf` over
the firstmate repo returns nothing). It is installed on the machine and used by
nothing.

**Disposition: eliminate. Uninstalling beats folding, and a dependency nothing uses
is the cheapest one to remove.** Removal is the captain's call because it changes
what is installed on their machine.

## The shared-SDK finding

Five of the six npm tools (`quota-axi`, `tasks-axi`, `gh-axi`, `lavish-axi`,
`chrome-devtools-axi`) depend on `axi-sdk-js`, which is **also** `kunchenguid`
(`github.com/kunchenguid/axi`). Folding any one of them without also folding that
SDK would leave the upstream dependency fully intact underneath.

This matters mostly as a warning for anyone who revisits folding later: the unit of
ownership is the SDK plus its dependents, not a single CLI. It is a further argument
for letting the firstmate-shaped ones die rather than folding them one at a time.

## Accepted external dependencies

Recorded so that "trusted third party" is a visible, revisitable position rather than
an invisible one:

| Dependency | Origin | Position |
|---|---|---|
| `herdr` (442 refs) | `ogulcancelik/herdr`, Homebrew | **Captain trusts it.** Different owner from the `kunchenguid` set. Not folded by decision, not by oversight. |
| `gsd` (71 refs) | `open-gsd/gsd-pi` | External product firstmate drives; not a firstmate dependency to own. |
| `tmux`, `jq`, `git`, harness CLIs | ecosystem | Infrastructure. Folding is neither possible nor sensible. A vendor CLI can still change under us, which is what pinned contract work exists to catch. |

## Re-derivation under the Bun/TypeScript destination

**Captain decision, authoritative:** KURU unifies on **TypeScript running on Bun**.
Python-plus-PyYAML is no longer the destination idiom. Every conclusion above that
rested on an idiom mismatch has been re-derived below. Conclusions that rested on
something else are unchanged, and saying which is which is the point of this
section — a premise change should not be allowed to launder unrelated arguments.

### What dies

**The idiom objection itself.** The map above argued absorption must be "native
reimplementation in KURU's own idiom, never vendoring TypeScript." Under a
TypeScript/Bun destination the axi family *is* the destination idiom, so that
objection is void. It was the single strongest argument against absorbing the axi
tools, and it is gone.

The cost of absorbing any axi tool drops sharply as a result: same language, same
runtime, and a shared `axi-sdk-js` that would be absorbed once for all five
dependents rather than five times.

### What survives, and why

| Conclusion | Rested on | Under Bun/TS |
|---|---|---|
| `tasks-axi` dies with firstmate | zero KURU refs + KURU already has a work graph | **unchanged** — duplication, not language |
| `gnhf` drop | zero refs in KURU *and* firstmate | **unchanged** — nothing uses it |
| `gh-axi`, `lavish-axi`, `chrome-devtools-axi` unevidenced | zero/history-only KURU refs | **unchanged conclusion, lower bar** — still not in the specification, but cheap to absorb whenever it asks |
| `treehouse` — capability survives, tool does not | zero KURU code/spec refs + firstmate-shaped | **strengthened** — see below |
| `quota-axi` — absorb the contract, not the decoders | **two independent legs** | **one leg dies, one holds** — see below |

**`treehouse` is now the odd one out.** It is **Go**, not TypeScript. Under a
Python destination every candidate was an idiom mismatch, so treehouse was
unremarkable. Under a TypeScript/Bun destination it becomes the *only* one of the
seven that still is. Its "do not fold" ruling never depended on language, so the
ruling stands — but the reason it stands is now sharper: absorbing treehouse would
import a Go toolchain into a runtime that just unified away from polyglot.

**`quota-axi` had two legs and only one has broken.**

- *Leg 1, language* — "never vendor TypeScript into a Python base." **Dead.**
- *Leg 2, architecture* — decision 0028 and `product.md` put usage evidence on the
  organ-evidence relationship: the Brain routes, organs report windows. That is a
  boundary about **who decodes vendor APIs**, not about what language does it.
  **It holds unchanged**, and it is now the *only* thing standing between KURU and
  absorbing quota-axi wholesale.

So the recommendation is unchanged in substance — absorb the evidence contract,
leave vendor decoding in an organ — but it now rests entirely on an architectural
boundary the captain can revisit, rather than on a language constraint that no
longer exists. That is a materially weaker position than it was, and it should be
read that way.

### Specification items the captain decision creates

Named rather than worked around, per directive.

**1. Not a contradiction, but now largely moot — the subprocess clause.**
`docs/specification/decisions/0028-usage-burndown-routing.md`, lines 64-65:

> **makes no subprocess call at all** (no external-organ-dispatch shell-out, no
> quota-axi shell-out). Usage evidence is caller-supplied organ evidence JSON only.

This prohibits *shelling out*. Once KURU and the axi family share one runtime, the
natural integration is an in-process **import**, which this text does not address
at all. The clause is not contradicted by the captain decision; it is bypassed by
it. Left as written, it forbids the expensive integration while saying nothing
about the cheap one — which is not a coherent place for a specification to sit.
**Item: 0028 should state its position on in-process import, not only on
subprocess.**

**2. The real constraint, and the real decision.**
`docs/specification/product.md`, line 713:

> Usage evidence arrives through the **organ-evidence relationship** (for example,
> quota-axi output normalized as evidence a mechanism may read). The Brain owns
> routing; organs report windows only. The selector **must not** shell out to or
> wrap external organ dispatch scripts, and no non-KURU router is a runtime
> dependency of this engine.

"The Brain owns routing; organs report windows only" is language-independent and
still forbids KURU base decoding vendor quota APIs — in TypeScript exactly as in
Python. **This is the clause that would have to change** for KURU to absorb
quota-axi's decoders. It is a genuine architectural decision, not an artifact of
the old idiom, so it is the captain's to make rather than mine to route around.

**3. A live inconsistency the decision creates today.**
`tools/usage-burndown` is Python. As of `0b315e6` ("Preflight KURU runtime
requirements", landed while this lane ran) it is a `#!/bin/sh` polyglot that execs
a `python-entrypoint` shim. Under a Bun/TypeScript unification that file — and the
entrypoint mechanism added to support it — is a port item. **Item: the
usage-burndown selector and its Python entrypoint shim need a TypeScript/Bun
target.** Not this lane's work; recorded because the absorption question sits
directly on top of it.

### What this does to the artifact in `absorb/kuru/`

The port is explicitly not this lane's work, and the branch was not restructured
around it. What matters is how much of the artifact is idiom-bound:

| Piece | Under Bun/TS |
|---|---|
| `usage-evidence-contract.json` (the pins) | **ports unchanged** — it is data |
| `tests/fixtures/usage-evidence/*.json` | **port unchanged** — captured evidence |
| the contract *rules* (drift, partial-rename, window length, fresh-but-empty) | **port unchanged** — logic, not syntax |
| `usage_evidence_contract.py` | **needs rewriting in TypeScript** — ~250 lines |

The valuable part — which regressions to catch, which identifiers to pin, and why
a partial rename defeats a naive check — is idiom-neutral. Only the file it is
spelled in changes.

## What would have to be true to fold any of these after all

This map says "don't fold" for six of seven. That conclusion flips if any of the
following becomes true, and each is a concrete, checkable condition:

1. **Firstmate's retirement slips indefinitely.** The whole argument rests on not
   investing in a system slated for demolition. If firstmate is still the fleet's
   orchestrator a year out, the arithmetic changes.
2. **An upstream break blocks the fleet and upstream will not take the fix.** This
   already happened once for `quota-axi` (PR 43 closed unmerged), which is why the
   interim custody posture exists. A second occurrence on `treehouse` — the
   dependency that stops all dispatch — would justify folding it on its own.
3. **KURU's specification adopts one of the unevidenced capabilities** (host
   delivery, browser operation, review surfaces). Then the capability is absorbed
   in KURU's own idiom (TypeScript on Bun), and — now that the idiom matches —
   absorbing the existing implementation is a live option rather than a rewrite.
