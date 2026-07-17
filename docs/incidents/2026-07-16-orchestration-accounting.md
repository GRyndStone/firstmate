# Firstmate orchestration accounting incident, 2026-07-16 to 2026-07-17

## Scope and evidence policy

This incident belongs to Firstmate's orchestration layer.
Forex activity is evidence only, and the corrective changes do not modify `forex-autoresearch` code, issues, or project artifacts.
The investigation used the primary Firstmate home at `/Users/cal/firstmate` read-only and made no attempt to repair, rewrite, or discard its operational records.
The primary transcript was `/Users/cal/.codex/sessions/2026/07/16/rollout-2026-07-16T15-46-44-019f6d1c-6198-75b2-90fd-be0aa229d99f.jsonl`.
Transcript timestamps below are UTC.
The captain did not cause this incident.
User interruption is a normal foreground-tool event that the checkpoint wrapper must handle safely, and the failure to clean up its child process was Firstmate's defect.

## Evidence-backed timeline

At 2026-07-16 22:54:31, Firstmate's captain-facing fleet account listed three Forex tasks and said `billables-extract` was untouched and out of commission.
That account omitted queued and held work, did not inventory duplicate recovery panes, and treated the visible backlog as the effective commissioned program.
At 2026-07-16 23:04:54, Firstmate created recovery pane `default:wD:p1K` with label `fm-forex-corpus-seed` for the existing corpus worktree.
At 2026-07-16 23:05:07, it rewrote `state/forex-corpus-seed.meta` from the prior endpoint to `p1K`, leaving the prior endpoint outside the sole meta record.
At 2026-07-16 23:09:43, Firstmate created another recovery pane, `default:wD:p1M`, with the same label and worktree.
At 2026-07-16 23:09:55, it rewrote the same meta from `p1K` to `p1M`, again preserving only the latest endpoint in normal accounting.
The older live panes `p1F` and `p1K` therefore escaped meta-based recovery until the captain asked for a complete pane-to-task map.
At 2026-07-17 04:57:16, Firstmate submitted `tasks-axi update forex-datafix-q4 ... --archive-body --pr ... --json` and `tasks-axi hold forex-datafix-q4 ... --kind captain --json` concurrently in one `Promise.all`.
Both commands were last-writer mutations of the same task in the same Markdown backend file.
At 2026-07-17 05:35:19, Firstmate ran `tasks-axi done billables-extract --note "Closed as superseded..." --json` before resolving the owned scout lifecycle.
At 2026-07-17 05:39:03, direct evidence printed `REPORT_ABSENT` for `/Users/cal/firstmate/data/billables-extract/report.md`.
The primary home still held `state/billables-extract.meta`, its recorded endpoint was dead, and no successful teardown had occurred.
The existing teardown contract would have refused that scout because the report was absent.
At 2026-07-17 05:38:38, Firstmate found the two extra corpus panes and stated that only `p1M` was recorded.
At 2026-07-17 05:40:55, Firstmate admitted that its earlier answer had omitted the duplicate panes and held tasks.
At 2026-07-17 05:42:06, it compared the sparse queue with `/Users/cal/firstmate/data/forex-program.md` instead of assuming the queue was complete.
At 2026-07-17 05:42:44, it found that only one Forex successor was explicitly blocked on corpus even though the durable program required three parallel lines.
At 2026-07-17 05:43:17, it concluded that multiple ready engine-trust, grid, MT5, and preparation obligations had never been materialized as backlog tasks.
At 2026-07-17 05:46:54, Firstmate correctly classified the event as an orchestration failure rather than only a reporting omission.
At 2026-07-17 05:52:23, another interrupted Codex foreground checkpoint returned `watcher: already running pid 37616` and `checkpoint: watcher is already running outside this foreground checkpoint`.
At 2026-07-17 05:52:29, the exact process check returned `37616     1 03:59 S    bash /Users/cal/firstmate/bin/fm-watch.sh`.
PID 37616 had been reparented to PPID 1 after the foreground checkpoint was interrupted.
At 2026-07-17 05:52:38, Firstmate terminated only PID 37616 after verifying it with `ps`.
The recurrence made the watcher signal-cleanup defect reproducible rather than hypothetical.

## Root causes

### Missing mechanical invariants

The backlog backend had no shared per-home lock, so two correct-looking mutation commands could race one Markdown file.
Task completion and owned lifecycle teardown were separate commands, and the completion command did not inspect meta, teardown state, or the scout report.
Task meta represented one current endpoint but recovery reporting had no same-home live-inventory comparison, so overwriting `window=` hid earlier recovery endpoints.
The Codex checkpoint delegated timeout behavior to generic wrappers and never captured, terminated, and reaped the exact `fm-watch.sh` child it created.
Fleet reporting parsed the backlog but carried no durable-program source pointers or explicit decomposition-judgment state.
These gaps allowed stale success, duplicate ownership, orphaned watchers, concurrent writers, and an empty-queue false conclusion to remain mechanically plausible.

### Ambiguous operating contracts

The backlog was both a dispatch queue and an informal proxy for the broader program, but no reporting surface stated that a queue can be fully accounted while the durable program is still under-decomposed.
Recovery correctly prohibited broad cross-home sweeps, but it did not provide a bounded same-home duplicate inventory to use instead.
Teardown printed a follow-up `tasks-axi done` reminder, which left the required ordering dependent on operator memory and made premature completion appear like a normal two-step variation.
Manual backlog mode cannot be mechanically serialized by the tasks-axi wrapper, so its remaining single-writer and post-teardown ordering boundary must be explicit.

### Direct violations of already-correct contracts

Firstmate marked a scout record Done even though the existing scout contract required a report and the existing teardown script would have refused without it.
Firstmate manually launched repeated recovery panes for one task and worktree after the normal spawn path's duplicate-label refusal, then overwrote the only endpoint reference instead of reconciling the prior endpoint.
Firstmate intentionally issued two mutating `tasks-axi` commands for one task concurrently even though no operation required concurrency.
Firstmate initially reported an incomplete fleet account despite the existing duty to report outcomes faithfully and the available held, queued, and pane evidence.
These were Firstmate operator violations, not captain error and not failures in the Forex project.

## Guardrails

`bin/fm-backlog.sh` is now the supported home-scoped tasks-axi entry point.
It serializes mutations with `state/.backlog.lock`, refuses file/backend overrides, refuses `done` while meta or teardown state remains, and validates the exact scout report path and file.
`bin/fm-teardown.sh` now records completion only from a durable finalizing phase after successful cleanup, retaining owned lifecycle state until the serialized mutation succeeds.
Herdr and Zellij teardown first refuse any duplicate or replacement same-home task endpoint reported by the audit, so a hidden earlier recovery endpoint blocks clean completion until explicitly reconciled.
cmux read-only audit emits a structured unavailable finding because its CLI cannot query an exact-home inventory without enumerating app-global windows, and teardown refuses that finding before endpoint closure.
Forced secondmate retirement audits every supported child-home endpoint before closing children and refuses the whole retirement on an anomaly or unknown inventory.
If artifact information or the Done mutation is unavailable after teardown, it leaves the task outside Done and reports the reconciliation action instead of fabricating completion.
`bin/fm-backlog-handoff.sh` now holds both homes' backlog locks in deterministic path order through classification and the atomic move.
`bin/fm-endpoint-audit.sh` compares Herdr live tabs only in sessions and exact workspace ids named by this home's meta, and compares Zellij tabs only in the recorded session under the exact home-scoped title.
It emits stable duplicate task, worktree, recorded endpoint, and live endpoint data to session-start recovery, fleet view, and bearings, and it contains no close path.
For cmux it emits `inventory_unavailable` without issuing any global inventory command, preserving the anomaly for read-only fleet accounting while teardown fails closed.
`bin/fm-watch-checkpoint.sh` now captures one watcher PID and one timer PID, and its signal and exit cleanup terminates and reaps only those owned children.
`bin/fm-fleet-snapshot.sh` now parses structured holds, counts runnable candidates separately from held and blocked work, and points to convention-named durable program files.
When program sources exist, decomposition remains `requires_supervisor_judgment` because code cannot safely infer every obligation from prose.
`bin/fm-bearings-snapshot.sh` now includes held work, duplicate endpoint anomalies, and that program boundary in its default captain-facing projection.
`AGENTS.md` contains only the universal triggers: use the serialized backlog wrapper, let teardown own completion order, treat endpoint alerts as inspect-only, and never equate an empty runnable queue with program completion.
Detailed contracts remain with the owning scripts, configuration documentation, recovery skill, bearings skill, and this incident record.

## Regression evidence

Before the fix, an interrupted checkpoint left PID 37616 with PPID 1 and the next checkpoint refused because the live watcher was outside its foreground owner.
After the fix, `tests/fm-watch-checkpoint.test.sh` sends TERM to the checkpoint parent, verifies the watcher was its direct child, verifies that watcher no longer exists, verifies the lock is gone, and verifies an unrelated process remains alive.
Before the fix, `tasks-axi done billables-extract` succeeded while meta remained and the required report was absent.
After the fix, `tests/fm-backlog.test.sh` proves `done` cannot reach tasks-axi with unresolved meta, a scout cannot complete through either `--note` or `--report` without its exact owned report, and a valid post-cleanup report completion is scoped to the owned backlog.
`tests/fm-teardown.test.sh` proves Done observes the exact finalizing stage, interrupted finalization remains idempotently retryable, and lifecycle state disappears only after backlog recording succeeds.
Before the fix, `update` and `hold` ran concurrently against `forex-datafix-q4`.
After the fix, `tests/fm-backlog.test.sh` launches update and hold concurrently and proves their critical sections never overlap.
Before the fix, panes `p1F`, `p1K`, and `p1M` accumulated while only `p1M` remained recorded.
After the fix, `tests/fm-endpoint-audit.test.sh` models two live same-label endpoints, proves deterministic reporting, proves only the active home's workspace was queried, and proves no close operation was issued.
`tests/fm-teardown.test.sh` also proves those duplicates block teardown, preserve task meta, and trigger no endpoint closure.
It additionally proves forced secondmate retirement surfaces a child-home duplicate before closure and that interrupted cleanup never reuses a replacement worktree after its random task-owned marker disappears.
Before the fix, captain-facing accounting omitted held tasks and treated a sparse queue as the whole program.
After the fix, `tests/fm-fleet-snapshot-view.test.sh` and `tests/fm-bearings-snapshot.test.sh` prove held work remains visible and a zero-candidate queue with a durable program source reports `requires_supervisor_judgment`.

## Validation

The exact full-suite command `rc=0; for t in tests/*.test.sh; do bash "$t" || rc=1; done; exit "$rc"` exited 0 after the guardrails and regressions were in place.
The exact lint command `bin/fm-lint.sh` exited 0 with the repository-pinned ShellCheck 0.11.0.
The suite reported its existing environment-dependent skips for the opt-in interactive Pi live test, Pi typechecking when `tsc` is absent, and the Zellij smoke test when Zellij is absent.
All other test scripts, including real Herdr and tmux backend smoke and safety coverage, passed.

## Residual boundary

Mechanical reporting can identify known durable program files, structured queue rows, holds, blockers, and duplicate same-home Herdr or Zellij labels.
cmux remains fail-closed because it has no exact-home inventory query.
Only a supervisor can decide whether prose obligations have been decomposed completely, whether two endpoints contain unique state, or whether a manual-backend edit is semantically correct.
The guardrails therefore fail closed or report loudly at those boundaries rather than closing endpoints, inventing tasks, or interpreting plans automatically.
