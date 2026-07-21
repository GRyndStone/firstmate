# Firstmate as a KURU orchestration organ (T-e.2)

Under the KURU unified-Brain architecture, Firstmate is a **bounded orchestration organ**.
It executes crew work and returns **evidence only**.
KURU owns goals, acceptance criteria, routing decisions (harness / model / effort), and criterion outcomes.

This document is the Firstmate-side contract.
The Brain-side seam lives on the kuru repo: `docs/seams/orchestration.md`, `adapters/orchestration/`, `bin/orch`.

## Authority boundary

| Concern | Owner | Firstmate organ may |
| --- | --- | --- |
| Goal graph, criteria, `outcome` | KURU Brain | never write goal outcome or claim attainment |
| Harness / model / effort | KURU Brain router | execute a Brain-supplied profile; never choose one |
| Task / PR / run / validator status | Firstmate (local) | report as **evidence** only |
| Optional task-local validator | skill/hook behind the seam | return evidence Brain may accept or reject |
| End-to-end ship pipeline (no-mistakes) | optional validator only | must not be ported into KURU as a global gate |

Hard rules:

1. `done:`, PR open/merged, green CI, and organ `result: ok` are **evidence**, never criterion `outcome: attained`.
2. Attainment is only via Brain `bin/goals set-outcome` with criterion evidence ids (REQ-18).
3. No second router: organ calls refuse `route` / `choose_model` / `pick_harness` / similar verbs.
4. No initiative arm from this organ surface.
5. Existing spawn / watch / teardown machinery is preserved for execution; this organ does not replace it.

## Goal ↔ task linkage

Dual-write during M1 coexistence:

| Direction | Field / record | Writer |
| --- | --- | --- |
| FM task → KURU goal | `kuru_goal=<goal-slug>` on `state/<task-id>.meta` | `bin/fm-kuru-organ.sh link` or organ `call spawn` |
| FM task → KURU dispatch | optional `kuru_dispatch=<dispatch-id>` on the same meta | same |
| KURU dispatch → FM task | `organ_ref` on the Brain dispatch record | KURU `bin/orch` / adapter |
| Inverse lookup (FM home) | `data/kuru-goal-index/<goal-slug>` (task ids, one per line) plus live meta scan | link / unlink |

Labels alone never complete a goal.
A backlog checkmark or status `done:` only updates local execution state; Brain criteria stay unproven until verified.

### Commands

```sh
bin/fm-kuru-organ.sh link <task-id> --goal <goal-slug> [--dispatch <dispatch-id>]
bin/fm-kuru-organ.sh unlink <task-id>
bin/fm-kuru-organ.sh show-link <task-id>
bin/fm-kuru-organ.sh find-goal <goal-slug>
```

## Organ call surface

Supported verbs: `spawn`, `status`, `teardown`, `collect_evidence`.

```sh
bin/fm-kuru-organ.sh call spawn --dispatch-file path/to/dispatch.json [--task-id <id>]
bin/fm-kuru-organ.sh call status --dispatch-file ... [--task-id <id>]
bin/fm-kuru-organ.sh call teardown --dispatch-file ... [--task-id <id>]
bin/fm-kuru-organ.sh call collect_evidence --dispatch-file ... [--task-id <id>] [--result ok]
```

`call spawn` is **bind-only** in this slice: it links the goal, records organ binding on task meta, and returns evidence.
It does **not** launch a crewmate or arm initiative.
Live work still uses `bin/fm-spawn.sh` and the normal supervise path after binding (or as Firstmate already runs during coexistence).

Evidence shape matches the KURU seam (`type: evidence`, surfaces, results).
Forbidden keys include `outcome`, `attained`, `criterion_outcome`, `goal_outcome`, and routing choice fields.
Helpers:

```sh
bin/fm-kuru-organ.sh make-evidence --id ev-… --dispatch-id d-… --goal slug \
  --surface task --result ok --summary "…" --task-id <id>
bin/fm-kuru-organ.sh validate-evidence path.json
bin/fm-kuru-organ.sh validate-dispatch path.json
```

## Coexistence modes (reference)

| Mode | Captain door | Role of Firstmate |
| --- | --- | --- |
| M0 Current | Firstmate | Sole liaison (default for non-KURU fleets) |
| M1 Shadow | KURU records goals; FM still executes | Dual-write organ; this slice |
| M2 Brain-primary | KURU intake default | Organ only; FM state is execution cache |
| M3 Sole door | KURU only (FM break-glass) | Organ only |

This Firstmate PR implements **linkage + organ boundary + AGENTS organ clause** for M1.
It does **not** implement M2 cutover or sole-door chat.
Usage admission lives in `bin/fm-dispatch-select.sh`; primary session compact/rotate controls live in `bin/fm-session-lifecycle.sh`.

## Tests

```sh
bash tests/fm-kuru-organ.test.sh
```

Covers goal↔task link/unlink/inverse, refused routing verbs, evidence-only emission (no outcome keys), and bind-only spawn without initiative.
