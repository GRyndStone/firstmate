# Criterion-to-evidence acceptance

This document, together with [`bin/fm-acceptance-lib.sh`](../bin/fm-acceptance-lib.sh) and [`bin/fm-acceptance-check.sh`](../bin/fm-acceptance-check.sh), is the **single owner** of Firstmate's ship-task acceptance gate.
`AGENTS.md` carries only the run trigger; do not restate the class matrix or handoff schema there.

## Why

Briefs can list concrete acceptance criteria, but completion used to advance from unstructured worker claims.
That allowed the Gryndstone Grok incident: provider-catalog, active-config, inference, and restart evidence were accepted where the criterion required **user-facing model-chooser** evidence.
The gate also once accepted a `result` that explicitly declared partial completion and named still-failing checks because it validated only evidence shape.
The gate now fails closed on missing maps, incomplete fields, cross-class proxy substitutions, ambiguous verdicts, and declared nonpassing verdicts.

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
- result: PASS - xai-oauth / grok-4.5 listed and selectable
- head: <git-sha or observation timestamp>
```

Required fields per `## AC-N` entry: `surface`, `class`, `command`, `result`.
Fields must be markdown bullets (`- surface: ...`); a present `## AC-N` heading with bare `key: value` lines is diagnosed as unparsed fields, not as a missing section.
`head` (or `freshness`) is required when the required class is `ui` or `live`.
Optional: `statement`, `required_class` (overrides keyword inference).
`class` must be a known vocabulary token (`ui`, `live`, `unit`, `catalog`, `config`, `api`, `code`, `process`, `inference`); unknown tokens fail as unrecognised, not as proxy rejections.

### Result verdicts

The `result` field starts with exactly one declared verdict: `PASS`, `FAIL`, `PARTIAL`, or `UNKNOWN`.
The verdict may stand alone or be followed by `: ` or ` - ` and a concise observed-output summary.
Existing handoffs that place another punctuation separator after the exact verdict token remain readable.
Only `PASS` advances a criterion.
`FAIL`, `PARTIAL`, and `UNKNOWN` report that the criterion was not achieved and produce a verdict-specific repair message.
A `result` without a declared verdict fails as ambiguous.
The checker never guesses a verdict from free-form wording, so new phrases cannot silently become success.
This protocol constrains the existing required field instead of adding another field to the handoff.
Shape, completeness, and surface compatibility are checked first so their existing repair messages remain distinguishable from verdict failures.

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

Keyword inference (first match) from criterion statement text uses **whole tokens only** after non-alphanumeric runs are treated as separators.
Substring hits inside ordinary English words do not count: `configured` is not `config`, and incidental vocabulary must not invent a stricter required class.

- user-facing / chooser / switcher / menu / Telegram / ui → `ui`
- security / destructive / live server / production → `live`
- unit test / focused test / regression test → `unit`
- catalog / provider list / model list → `catalog`
- config / configs / configuration / yaml / ini / json (not configured/configuring) → `config`
- api / endpoint / http / https → `api`
- no strong token match → `code` (honest default when inference is uncertain; stronger offered surfaces still satisfy `code`)

Text inference cannot be made fully reliable for free-form English.
When a criterion's required surface is high-stakes or the wording is ambiguous, set explicit `required_class` on the evidence entry (or on the criterion itself when authoring) so the worker cannot dilute it and incidental vocabulary cannot redirect the gate.

Hard rule examples:

- config ≠ UI; catalog ≠ UI; API listing ≠ chooser menu
- unit tests ≠ live server
- current selection ≠ alternatives still selectable (that needs UI/live evidence of the chooser options)

## Firstmate workflow

On any ship-task `done:` (all delivery modes), before validation, PR-ready, merge recommendation, or captain-facing completion:

```sh
bin/fm-acceptance-check.sh <id>
```

- Exit 0: every mapped result declared `PASS`; advance according to delivery mode.
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
