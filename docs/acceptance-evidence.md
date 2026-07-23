# Criterion-to-evidence acceptance

This document, together with [`bin/fm-acceptance-lib.sh`](../bin/fm-acceptance-lib.sh) and [`bin/fm-acceptance-check.sh`](../bin/fm-acceptance-check.sh), is the **single owner** of Firstmate's ship-task acceptance gate.
`AGENTS.md` carries only the run trigger; do not restate the class matrix or handoff schema there.

## Why

Briefs can list concrete acceptance criteria, but completion used to advance from unstructured worker claims.
That allowed the Gryndstone Grok incident: provider-catalog, active-config, inference, and restart evidence were accepted where the criterion required **user-facing model-chooser** evidence.
The gate fails closed on missing maps, incomplete fields, and cross-class proxy substitutions.

## Stable criterion identity

When Firstmate fills a ship brief's `{TASK}`, every concrete acceptance criterion gets a stable id in the Task section:

```markdown
## Acceptance
- AC-1: Grok 4.5 appears in the user-facing model chooser and is selectable
- AC-2: focused tests and lint pass on the branch
```

Routine tasks with no concrete criteria need no ids.
Ids are extracted only from the `# Task` section so the scaffold's own instructions never invent criteria.

## Completion handoff

Path: `data/<id>/acceptance.md` under the active firstmate home.

### With concrete criteria

```markdown
# Acceptance evidence

## AC-1
- statement: Grok 4.5 appears in the user-facing model chooser and is selectable
- surface: Hermes Telegram model switcher (user-facing)
- class: ui
- command: open existing model chooser; list selectable entries
- result: xai-oauth / grok-4.5 listed and selectable
- head: <git-sha or observation timestamp>
- relevance: blocks-ideal
```

Required fields per `## AC-N` entry: `surface`, `class`, `command`, `result`, `relevance`.
`head` (or `freshness`) is required when the required class is `ui` or `live`.
Optional: `statement`, `required_class` (overrides keyword inference).

### Relevance classification

`relevance` records what the finding means against the captain-approved ideal state.
It is required because truth and relevance are separate axes: a criterion whose evidence is verified true still has to be weighed against the ideal before it can close, or a true-but-out-of-model finding silently sets the agenda.

| Value | Meaning |
| --- | --- |
| `blocks-ideal` | The ideal state is not reached until this is addressed. |
| `later-scope` | Real and correctly scoped, but belongs to later work, not this task. |
| `out-of-model` | True, but outside the operating model this work runs in; it is informational only. |

A missing value or any value outside that set fails closed with a `repair:` line, exactly like an incomplete evidence mapping.
The proportional `none:` path carries no `## AC-N` entries, so it needs no `relevance` and is unchanged.

### Proportional (no concrete criteria)

```markdown
# Acceptance evidence
none: no concrete acceptance criteria
```

## Evidence classes and proxy rejection

| Required class (inferred or explicit) | Acceptable offered `class` |
| --- | --- |
| `ui` | `ui` only |
| `live` | `live` only |
| `catalog` | `catalog` only |
| `config` | `config`, or `code` that embeds the same value |
| `api` | `api` only |
| `unit` | `unit` only |
| `code` | `code`, `unit`, `config`, `process`, `api` |
| `process` | `process`, `live` |
| `inference` | `inference`, `live`, `ui` |

`status`, `claim`, `prose`, `authority`, and `done` are **never** evidence.

Keyword inference (first match) from criterion statement text:

- user-facing / chooser / switcher / menu / Telegram → `ui`
- security / destructive / live server / production → `live`
- unit test / focused test → `unit`
- catalog / provider list → `catalog`
- config / configuration → `config`
- api / endpoint → `api`
- otherwise → `code`

Hard rule examples:

- config ≠ UI; catalog ≠ UI; API listing ≠ chooser menu
- unit tests ≠ live server
- current selection ≠ alternatives still selectable (that needs UI/live evidence of the chooser options)

## Firstmate workflow

On any ship-task `done:` (all delivery modes), before validation, PR-ready, merge recommendation, or captain-facing completion:

```sh
bin/fm-acceptance-check.sh <id>
```

- Exit 0: advance according to delivery mode.
- Exit 1: do **not** advance.
  Steer the existing worker with the script's `repair ...` lines.
  Do not escalate incomplete mappings to the captain as product questions.
- A status `done:` alone never satisfies the gate.

Scout, GSD-driving, and secondmate charters are out of scope for this ship gate.

## Regression: Gryndstone chooser

Fixture intent (see `tests/fm-acceptance-check.test.sh`):

- Criterion requires user-facing chooser evidence for Grok.
- Handoff offering only catalog + active config + inference while the chooser lacks Grok → **FAIL**.
- Handoff with direct UI-surface evidence that Grok is listed and selectable → **PASS**.

## CLI

```sh
bin/fm-acceptance-check.sh <task-id>
bin/fm-acceptance-check.sh --brief path/to/brief.md --evidence path/to/acceptance.md
bin/fm-acceptance-check.sh --extract-ids --brief path/to/brief.md
```

## Brief scaffold

`bin/fm-brief.sh` embeds a short Acceptance-evidence section in ship briefs only.
It does not force hand-written schema boilerplate into routine tasks: workers either map `AC-N` entries or write the one-line `none:` declaration.
