# Dependency currency and contracts

Firstmate incorporates other people's software.
This is how it knows what it incorporates, whether each piece is current, and whether moving one of them broke something firstmate relies on.

## The failure this was built after

Firstmate ran on `quota-axi 0.1.5` while the published latest was `0.1.13`.
Seven releases of fixes never arrived, and nothing reported the gap - it was found by opening a package manifest while chasing an unrelated bug.

Then the upgrade demonstrated the second half of the problem.
Between those two versions the grok window identifiers were renamed - `product:grokbuild` became `product:grok_build`, `product:grokimagine` became `product:imagine` - and two new windows appeared.
A consumer keyed on a renamed identifier reads nothing, and reading nothing is indistinguishable from a legitimate absence: no error, a zero exit status, valid JSON.
**A version comparison would not have caught that, and neither would an exit-status check.**

So there are three questions, and they are different:

1. **Are we behind?** - needs a declared inventory and a currency check.
2. **Did moving break something we rely on?** - needs the *contract* pinned, not the version.
3. **Could we fix it at the source if we had to, and is what is installed even what it says it is?** - needs ownership recorded and identity read from the artifact rather than the version string.

The wider point, and the reason this is machinery rather than a rule: a correct rule that lives in an agent's attention is not a mechanism.
Firstmate was supposed to notice its tools were stale.
It did not, for seven releases.

## What exists

| Piece | Role |
| --- | --- |
| `deps/incorporations.conf` | the declared inventory: what firstmate incorporates, what for, and what it is relied upon to do |
| `deps/contracts/<id>.contract` | the pinned contract for the components that have one |
| `bin/fm-deps.sh` | the operator entrypoint (`list`, `check`, `report`, `upgrade`, `rollback`, `ledger`) |
| `bin/fm-deps-lib.sh` | parsing, currency lookup, contract verification, cache (owns both file formats) |
| `state/dep-currency.tsv` | per-home cache of currency answers and contract verdicts; gitignored |
| `data/dep-upgrades.md` | the append-only upgrade ledger; gitignored, and the thing `rollback` reads |
| `bin/fm-deps.sh access-check` | verifies whether a fix could actually be landed upstream; needs auth and network, so it is never on the session-start path |

## Declared, not inferred

The inventory is a file someone writes, not a scan for command names.
Inference always lags reality and it misses the piece nobody remembered - which is exactly the class of thing that goes stale for seven releases.

Declaration is enforced twice: `bin/fm-deps.sh report` prints a `DEPS: undeclared: ...` line for any tool `bin/fm-bootstrap.sh` requires without a stanza, and `tests/fm-deps.test.sh` fails on the same condition.
Adding a dependency without declaring it does not quietly succeed.

Each stanza also has to state its own opt-outs.
`currency = none:` and `contract = none:` both **require a reason**; a bare `none` is a validation error.
Deciding not to pin a contract is frequently the right call, but it is a decision, and it belongs in the file where review can see it rather than in the gap between two people's assumptions.

## Currency arrives without being asked for

`bin/fm-bootstrap.sh` calls `bin/fm-deps.sh report` on every session start, so staleness reaches the operator through the session-start digest they already read.
A command that reports staleness only when someone thinks to run it is the same discipline that produced the seven-release gap.

The other half matters just as much: **it is silent when everything is current.**
A check that speaks up when all is well gets ignored within a week, and is then worse than nothing, because it looks like coverage.
Both halves are asserted in `tests/fm-deps.test.sh`.

Three currency states, deliberately:

- **current** - silent.
- **behind** - one line naming both versions and the exact deliberate-upgrade command.
- **unchecked** - loud only after `FM_DEPS_UNCHECKED_HORIZON_DAYS` (7) without a successful lookup. A laptop off the network for an afternoon is not news; a component nothing has been able to check for a week is a real coverage hole, and "we do not know" is then a finding in its own right rather than a silence that reads like health.

A locked session refreshes before reporting, rate-limited to `FM_DEPS_REFRESH_INTERVAL` (12h) for the network half; the cheap half (reading installed versions and re-verifying any contract whose version moved) runs every time, because that is what catches an upgrade performed outside this script.
A read-only session that did not get the fleet lock reports from the cache and performs no lookup and no write, so a second concurrent session never races the lock holder.

### Offline

A failed lookup never overwrites a good cached answer with nothing.
The cache keeps the last known `latest` and the epoch it was learned at, which is precisely what lets the report distinguish a short outage (silent) from a component nobody has been able to check in a week (loud).
An entirely offline machine therefore degrades to "currency unchecked for N days" rather than to false confidence.

### A tool with no registry entry

`treehouse` is installed by a shell script from GitHub Pages and `no-mistakes` is built from an authenticated private checkout; neither has a registry to query.
Both declare `currency = none: <reason>` and are never nagged about.
For those components a capability check is not a supplement to a currency check - it is the entire guard, which is why both of them have one: `no-mistakes` through the pin in `deps/contracts/`, and `treehouse` through bootstrap's existing `treehouse_supports_lease` probe, which the inventory names as its owner.

### The captain's own sibling projects

Yes, the inventory covers them, and `quota-axi` is the reason: it is his own repository, which is exactly how it drifted.
A stanza may declare `sibling = <dir under projects/>`.
When that clone is present, `report` compares the installed version against the newest semver tag in the clone and reports `sibling ahead` when the captain's own repo has moved past what is installed.
This costs no network at all, because fleet sync already keeps those clones fresh - and it catches the case a registry check structurally cannot, where the repository is ahead of its own published release.

## Ownership: who controls it, and what happens when a fix cannot land there

Currency and contracts both assume the same thing: that when something is wrong, it can be fixed at the source.
That assumption is worth checking, and for firstmate it does not hold.

All five `-axi` tools firstmate depends on - `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - are published by one third party, `kunchenguid`, and so is `treehouse`.
Neither of the captain's GitHub accounts has push on any of them.
The projects are actively maintained with near-daily releases, but across the last twenty upstream pull requests every merged one came from the maintainer or the release bot, and every outside contributor's PR is unmerged - firstmate's #43 among them.

So the exposure is not "unmaintained upstream".
It is "actively maintained, does not take outside patches", which for a dependency in the routing critical path has the same practical consequence, and it applies to a whole tool family rather than to one package.

Each non-system stanza therefore records four more facts:

- **`control`** - who controls it: the captain, a third party, a vendor.
- **`write-access`** - whether a fix could actually be landed there, with **how and when that was verified**. A bare verdict is a validation error, because this was assumed for a long time and the assumption is what cost a merged fix. `bin/fm-deps.sh access-check` is how the answer gets checked; an unreadable answer is `unknown`, never `yes`.
- **`fallback`** - which rung of the ladder was chosen if a fix cannot land, and why: `direct`, `upstream-and-wait`, `own-build-of-fork`, `vendor`, `drop-and-degrade`.
- **`degrades-to`** - what actually breaks if this dependency is wrong or absent, recorded next to the ownership fact because the two decide each other.

### The answer is not "fork everything"

These tools reverse-engineer six vendors' billing APIs, including protobuf decoding.
Owning that permanently is a larger maintenance burden than the problem it solves, and it would duplicate work a fast-moving maintainer is already doing.

The cheap resilience is different: run our own build of the fork **only while a needed fix is actually blocked**, keep the upstream PR open, and make the dependency non-blocking so a stale or broken one costs accuracy rather than function.
That last part is the point.
An evidence source that cannot be trusted to move must degrade honestly rather than silently - which is why `quota-axi` going wrong costs dispatch quality (`quota_posture=unknown`) and never stops work.

The ladder is a per-dependency decision, and the inventory shows it being made differently for tools from the same publisher: `quota-axi` runs an own build because its blocked fix sits in the routing critical path, while `tasks-axi` waits upstream because hand-editing `data/backlog.md` is a first-class degraded mode, and `treehouse` would simply be dropped.

## A version number is not identity

The installed `quota-axi` on the captain's machine is no longer the published package.
It is a local build packed from his fork carrying the unmerged fix, and **it reports `0.1.13`, the same string as the published release, while containing different code.**

A currency system that compares version strings calls that install current and identical to upstream, and is wrong about what is actually running.
It is the same class of defect as the identifier rename: the signal everyone looks at is intact while the thing underneath has moved.

So identity is read from the artifact, not from the version string, two independent ways:

- **Divergence** - the installed tree's file count and byte total against the registry's own `dist` metadata for that exact version. One cheap metadata call, no download. On the captain's machine this reads 76 files / 397,795 bytes installed against 76 / 392,427 published: **5,368 bytes of different code under an identical version string.** Matching sizes are not proof of identity; differing sizes are proof of difference, which is the direction that matters.
- **Continuity** - a fingerprint of the installed tree against the one recorded for the same version. Needs no network at all, and catches the code moving under an unchanged version in either direction.

The inventory declares what should be there (`provenance = published` or `local-build: <what and why>`), and only a mismatch is reported.
A declared local build is the known truth and says nothing.
Three findings come out of this:

1. An install that is **not** the published artifact while claiming to be - declare it or reinstall.
2. A declared local build that has been **replaced by the published package** - a plain `npm install -g` does this, the version string does not move, and the fix it carried is silently gone. Nothing else would have noticed.
3. The artifact **changing under an unchanged version**, caught offline.

Currency for a declared local build is also reported differently: it says what upstream released without offering an upgrade command that would silently discard the local build.

## Contract pinning, not version pinning

For a pinned component, `deps/contracts/<id>.contract` records what firstmate actually reads: the fields it parses, the identifiers it keys on, the shape it expects, the flags it passes.
`bin/fm-deps.sh` runs the component's declared probes and evaluates each assertion against the real output.

Assertion kinds are deliberately few:

```
probe json = quota-axi --json

#: this comment becomes the label in failure output
json  json  (.providers | type) == "array"
text  help  --some-flag
min-version version  1.31.2
```

A contract verdict is cached against the installed version it was produced against.
When the installed version moves, the verdict is stale by construction and the contract is re-verified.
That is what makes an upgrade re-check its own contract automatically instead of relying on anyone remembering to, and it is also why an unchanged install costs nothing.

An unrunnable check reports `unknown`, never `ok` and never `broken`.
A check that could not run has proven nothing, and recording it as a pass is the exact failure mode this system exists to prevent.

### What got a pinned contract, and what did not

Pinning every field of everything is not maintainable.
Two components carry contracts and the rest declare why they do not - and the most common reason is not "it does not matter" but "something already owns this".

Firstmate already had three hand-written capability probes before any of this existed: `treehouse get --lease`, the `no-mistakes` version floor, and the `tasks-axi` compatibility check.
They are the same instinct as a pinned contract, and the right answer was not to replace them: two of them gate runtime behavior, not just reporting, and all three are already surfaced by bootstrap's `MISSING:` lines.
So they stay as the single owner of their facts, the inventory records that as their stated reason, and the new machinery covers what nothing was covering.

| Component | Pinned? | Why |
| --- | --- | --- |
| `quota-axi` | yes | the observed failure. Firstmate parses a provider/window document; a renamed identifier or a restyled field is read as a legitimate absence and silently degrades dispatch to `quota_posture=unknown` |
| `no-mistakes` | yes, in part | `bin/fm-crew-state.sh` judges a validating crewmate by the `axi status` run step; if that surface were renamed it would fall back to pane liveness and silently reinstate the stale reading the run-step read exists to replace. Its version floor is **not** pinned here, because bootstrap already owns it |
| `tasks-axi`, `treehouse` | no | already owned. `bin/fm-tasks-axi-lib.sh`'s compatibility probe and `bin/fm-bootstrap.sh`'s `treehouse_supports_lease` already check exactly what firstmate relies on, every session, and report it as `MISSING:`. They gate runtime behavior as well as reporting, so they stay; a second pin would give one fact two owners and report it twice |
| `gh-axi`, `chrome-devtools-axi`, `lavish-axi` | no | `AGENTS.md` section 3 explicitly forbids memorizing their flags and declares their session hooks and `--help` the source of truth. A pinned flag list would be a second owner of a contract firstmate has decided not to hold |
| `tmux`, `orca` | no | the backend suites already exercise the exact surface the adapters use against the real binary, which is a stronger check than a flag list and would duplicate its ownership |
| `git`, `gh`, `node` | no | long-stable surfaces on the operator's own upgrade cadence; `gh`'s one relied-upon behavior is already covered by bootstrap's `NEEDS_GH_AUTH` probe |

A small number of well-chosen pins that catch real breakage beats an exhaustive scheme nobody maintains.
Note also what the `quota-axi` contract deliberately does *not* pin: the full window inventory.
Windows come and go with the upstream provider's own plan changes - codex genuinely lost its `five_hour` window - so pinning the inventory would be a permanent false alarm.
What is pinned is the field vocabulary and the guarantee that a fresh metered provider still yields something firstmate's own filter accepts.

## Upgrading: deliberate, recorded, recoverable

Never silent, never automatic.
The captain authorized one `quota-axi` upgrade explicitly, and that is the model.

```sh
bin/fm-deps.sh upgrade quota-axi --approve
```

- Without `--approve` it refuses (exit 2), printing exactly what it declined to do.
- With `--approve` but with tasks in flight it refuses again (exit 2), naming the work, because changing a tool under running crewmates can break them mid-task. `--despite-fleet` overrides that, explicitly.
- It re-reads what is actually installed afterwards rather than trusting the requested version, then re-verifies the contract.
- Every move is appended to `data/dep-upgrades.md` with the version it came from.

When the contract breaks, the upgrade exits 3 - not 0 - and hands over the recovery command:

```
fm-deps: widget-axi upgraded 1.4.0 -> 3.0.0 but its PINNED CONTRACT BROKE:
fm-deps:   the widgets array firstmate parses is still there
fm-deps: nothing else consumed the new version yet. Recover with:
fm-deps:   bin/fm-deps.sh rollback widget-axi --approve
```

`rollback` reads the `from` version out of the ledger, which is what makes the ledger a recovery path rather than a record.
It refuses without `--approve` too, and it re-verifies the contract after restoring.
The whole sequence - break, report, recover, silence - is exercised end to end in `tests/fm-deps.test.sh`; a recovery path that is described but never run is not a recovery path.

## Reuse elsewhere

The portable core is `bin/fm-deps-lib.sh` plus the two file formats: nothing in it knows anything about firstmate except where the inventory lives (`FM_DEPS_DIR`) and where to cache (`FM_DEPS_CACHE`).
Currency adapters, contract probes, and the cache are all keyed off the declared inventory, and the probe layer is command-line-shaped rather than tied to any particular tool.

To reuse it in another system, that system needs exactly two things it must supply itself: a declared inventory of what it incorporates, and a decision about which of those deserve pinned contracts.
The second is the harder one, and it cannot be inherited - the pins have to name what *that* system reads.
The currency, caching, cadence, silence discipline, upgrade gating, ledger, and rollback all transfer unchanged.
