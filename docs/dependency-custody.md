# Dependency custody: the interim posture

Firstmate is transitional and scheduled for retirement once KURU handles
everything. `docs/capability-map.md` decides, per tool, whether the capability it
stands for survives that retirement. This document covers the other half: **how
firstmate survives until then without investing in a foundation slated for
demolition.**

The posture in one line: **keep using upstream, be able to run our own build when
a fix is genuinely blocked, and fold nothing into firstmate.**

## Why not fold

An earlier plan in this lane was to fold `treehouse` and `quota-axi` into
firstmate-owned repositories with renamed commands and a swept surface. That plan
was correct for a permanent system and wrong for this one. Folding buys ownership
and costs maintenance forever; firstmate does not have forever. The machinery
built for it (`bin/fm-fold*.sh`, `vendor/*/fold.json`) survives in a deliberately
narrower role, described below: **custody, not ownership.**

The one thing that plan got right and this posture keeps: **an identity that an
ordinary install cannot silently overwrite.** That problem is live today.

## The live problem this posture solves

The captain's machine currently runs a locally built `quota-axi` that reports
version `0.1.13` — byte-for-byte the same string the published npm release
reports — carrying different code. Measured:

```
published npm 0.1.13 dist sha256: 65f7a483142eb0328244c9d124eea50d2d26412c9be28bcf2553e70f3907c50a
locally built 0.1.13 dist sha256: 18088837e9e9726c8d24a5de6dcd19e9747d6b5dc106207521dda2603cb75db9
```

One ordinary `npm i -g quota-axi` reverts it, silently, and **any check comparing
version strings calls the reverted install current** — including
`bin/fm-tasks-axi-lib.sh`-style version probes elsewhere in this repo.

That is why custody records a **content digest**, never a version string.

## The custody machinery

| Command | Role |
|---|---|
| `bin/fm-fold.sh list` | declared custody records and their install state |
| `bin/fm-fold.sh build <id> --source <checkout>` | build our artifact from a source tree |
| `bin/fm-fold.sh install <id> --artifact <path>` | install it and record its sha256 identity |
| `bin/fm-fold.sh verify <id>` | assert the artifact on disk is still the one we installed |
| `bin/fm-fold-divergence.sh <id>` | regenerate the upstream-divergence report from git |
| `bin/fm-fold-sweep.sh [--strict]` | enumerate every firstmate surface that can reach an upstream name |

`vendor/<id>/fold.json` is the single source of each record: our command name, the
upstream repo and the exact base commit, the build kind, and the trim and declined
ledgers. Nothing else re-spells those facts.

`FM_FOLD_PREFIX` redirects every install to an isolated prefix, which is how the
anti-replacement proof runs without touching the captain's real `~/.local/bin`.

### Identity is a digest, not a version

`install` records `sha256` of the installed artifact in a sidecar under
`<prefix>/.gs-fold/<id>.identity.json`. `verify` re-digests the file on disk and
fails loudly on mismatch. An upstream package that lands on our path — or a
"same version" rebuild — fails verification. A version comparison would not.

The stronger guard is naming: a custody artifact installs as `gs-<tool>` into
`~/.local/bin`, so an ordinary `npm install -g <upstream>` writes a *different*
path in a *different* prefix and cannot reach it at all. `verify` is the backstop.

### Divergence is regenerated, never remembered

`bin/fm-fold-divergence.sh` computes, from git:

- **Carried** — what we hold that upstream does not
- **Upstream since base** — every commit landed after our pinned base
- **Declined** — those with a recorded ruling and reason in `fold.json`
- **Untriaged** — the actionable remainder

The `GRyndStone/no-mistakes` precedent keeps its equivalent as a prose
"customization ledger" in `PRIVATE_FIRSTMATE.md`. That ledger is only as current
as the last person who remembered to edit it. This is the same idea made
regenerable, which is the one place this work deliberately improves on the
precedent it was told to match.

## How a blocked fix gets carried

This is the whole interim workflow. It has already run once, for the Grok window
fix that upstream closed unmerged (PR 43).

1. **Try upstream first.** Open the PR. If it merges, there is nothing to carry.
2. **When it is refused or ignored**, keep the change on a branch in the local
   clone under `projects/<tool>` and record it in `vendor/<id>/fold.json`
   `carriedFixes[]` with what it fixes and why it matters.
3. **Build and install under our own name** with `bin/fm-fold.sh build` and
   `install`, so the fixed build cannot be silently reverted by a routine
   `npm i -g`.
4. **Re-run `bin/fm-fold-divergence.sh`** after any upstream release and rule on
   each untriaged commit — take it or record a decline with a reason.
5. **Do not grow the carry.** Every carried fix is maintenance that follows
   firstmate to its grave. Carry what unblocks the fleet; nothing else.

## The destination question, and why forking is off the table

`GRyndStone/firstmate` and `GRyndStone/quota-axi` are both **public forks** of
`kunchenguid` repositories. GitHub refuses `private=true` on a public fork
("Public forks can't be made private", HTTP 422). So a fork cannot become a
private owned copy, and forking is not a route to ownership at all.

The captain's own `GRyndStone/no-mistakes` is the shape that actually works:
**an independent private repository, not a fork**, installed to `~/.local/bin`
rather than a public registry, with `upstream` added as a fetch-only remote whose
push URL is the deliberately invalid literal `DISABLED`.

### Open captain decisions (outward-facing; nothing was done here)

Presented as options with consequences, per the constraint that naming,
visibility, publication, repository creation, and detachment are the captain's
calls.

**1. `GRyndStone/quota-axi` — a public fork carrying 17 `fm/*` branches**

Verified: public, fork of `kunchenguid/quota-axi`, 17 `fm/*` branches pushed. It
is listed on upstream's fork list and the work on it is publicly visible.

| Option | Consequence |
|---|---|
| **Leave it** | Zero effort. Work stays public and attributed on upstream's fork list. Fine if nothing there is sensitive. |
| **Detach the fork relationship** (GitHub Support request) | Removes it from upstream's fork list and permits later privacy. Support-gated, not self-serve, and it keeps the history. |
| **Delete it and re-create as an independent private repo** | Matches the `no-mistakes` precedent exactly. Loses the public branch history and any external links to it. Cleanest end state. |
| **Delete it outright** | Cheapest. Correct if the capability map's "do not fold `quota-axi`" ruling holds and the carried fix lives in the local clone instead. |

Given the capability map rules that `quota-axi` should **not** be folded, the last
two are the coherent options; leaving a public fork advertising abandoned work is
the weakest.

**2. `GRyndStone/firstmate` is itself a public fork.** The same 422 applies. If
firstmate should be private before retirement, it needs the same
detach-or-recreate decision. Recorded, not acted on.

**3. `gnhf` — zero references in KURU and zero in firstmate.** Removal changes
what is installed on the captain's machine, so it is theirs to run:
`npm uninstall -g gnhf`.

## Procedure for the remaining tools

Per `docs/capability-map.md`, the answer for most of them is *do nothing*, which
is the cheapest correct outcome. Written as a procedure so the reasoning does not
have to be re-derived.

For each tool, in order:

1. **Count its KURU references properly.**
   `cd projects/kuru && git grep -Il -- "<tool>" origin/main | wc -l`, then
   classify the hits by area. Counting the working tree inflates the number with
   untracked corpus; counting only `tools/` misses the specification. Both
   mistakes were made in this lane before the method was settled.
2. **Ask what capability it stands for**, not whether the tool is useful.
3. **Rule on survival.**
   - *Zero KURU references and firstmate-shaped* → **it dies with firstmate.** Do
     not fold, absorb, or maintain it. (`tasks-axi`, and `gnhf` which should just
     be removed.)
   - *Capability survives but the tool is firstmate-shaped* → **do not fold.** The
     successor implements the capability in its own idiom. (`treehouse`.)
   - *Capability is already in KURU's specification* → **absorb the capability
     natively in Python**, never vendor the TypeScript. Check first whether KURU
     already implements it: for usage/quota routing it already did, and the real
     gap was the contract at the boundary. (`quota-axi`.)
   - *Unevidenced* → **no action; re-evaluate when KURU's specification asks.**
     (`gh-axi`, `lavish-axi`, `chrome-devtools-axi`.)
4. **If and only if the fleet is blocked**, apply the carry workflow above. A
   blocked fleet is the only justification for new custody work.
5. **Never fork.** See above.

### The judgment calls this lane actually had to make

Recorded because these are the steps a later repetition gets wrong:

- **Measure against tracked `origin/main`, not the working tree.** The first pass
  reported `treehouse` = 7 and `quota-axi` = 1; both were undercounts (28 and 14).
  The conclusions survived, the numbers did not.
- **Check whether the capability already exists before absorbing it.** KURU's
  `tools/usage-burndown` is 1,028 lines of native Python with registered adapters.
  Absorbing quota-axi's routing would have re-implemented working code.
- **Read the specification for prohibitions, not just requirements.** Decision
  0028 forbids the selector from shelling out to quota-axi and puts evidence on
  the organ relationship. That prohibition, not a preference, is what makes
  "absorb the decoders" the wrong move.
- **Pin the identity of a partial rename, not just a total one.** The realized
  Grok rename changed 2 of 6 ids. A drift check asking "did any pinned id
  survive" passes it. Ids whose disappearance must fail have to be pinned
  individually.
- **A shared upstream SDK moves the unit of ownership.** Five of the six npm
  tools depend on `axi-sdk-js`, which is also `kunchenguid`. Folding one without
  it leaves the dependency fully intact underneath.
- **Language matters for absorption cost.** `treehouse` is Go (49 files, 11,366
  lines), not TypeScript as an earlier pass assumed. Folding it into a Node-shaped
  plan would have imported a Go toolchain requirement.
