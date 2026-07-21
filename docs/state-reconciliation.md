# Durable orchestration-state reconciliation

`state/<id>.status` is append-only event evidence and is never the authoritative current state.
The runtime owner is `bin/fm-watch.sh`, which invokes `fm_reconcile_observe` from `bin/fm-reconcile-lib.sh` for every task in one bounded parallel batch at the start of every classification cycle.
The library header owns the exact `state/<id>.reconciled` and `state/<id>.wait` schemas and transition mechanics.

## Runtime contract

Each cycle records repository identity, lifecycle generation, endpoint, current state, source evidence, observation time, status-event sequence and signature, preceding distinct state, external-wait result, versioned pending action, and the exact consumer-acknowledged action version.
Observation and acknowledgement updates are serialized by a per-task portable lock, and teardown takes that lock before publishing its tombstone.
The watcher writes an actionable wake to `state/.wake-queue` and advances sparse-event suppressors only to the exact status/turn-end signatures in that observation.
The durable daemon replays any queued reconciled action not yet accepted into its persistent escalation buffer, while a direct queue drain acknowledges only after printing the wake, so a producer or supervisor restart cannot strand delivery.
A prior positive `working` observation from a run-step, busy pane, or progressing task-owned command losing that positive source or changing to any non-working observation emits one `reconciled-transition` wake immediately.
That positive baseline crosses an endpoint replacement only when the persisted repository identity still matches the task metadata.
The wake reason includes the observed status-event sequence and last event, so a claimed append that never happened remains mechanically visible when the endpoint stops.
The watcher advances only the exact status and turn-end signatures already represented by that reconciled wake, preserving later turn-end delivery while preventing a second wake for the same transition.
The durable daemon escalates reconciled transition, external-wait completion, and observer-failure verdicts directly instead of sending them back through stale status prose.

Normal `bin/fm-crew-state.sh <id>` reads prefer a fresh endpoint-matched reconciled observation, while the watcher requests a live-only read to discover the next edge.
The structured snapshot exposes `current_state` with evidence and freshness, `prior_observed_state`, `last_status_event` with both the live file sequence and the supervisor-observed sequence/freshness, and `external_wait` as separate objects.
Fleet view and bearings consume that snapshot, and bearings never substitutes the last status event as current activity prose.

## Observable external waits

Register an observer before appending `paused:`, `blocked:`, or a parked wait and parking foreground work.
A predicate is an executable with no shell evaluation: exit 0 with a non-empty stdout completion signal means complete, exit 0 without one or exit 1 means pending, and any other exit or a timeout is an actionable failure.
A process registration captures both the pid and its operating-system identity, so process exit or pid reuse is completion while the identical live process remains pending.

```sh
bin/fm-external-wait.sh register-predicate <task-id> <executable> [description]
bin/fm-external-wait.sh register-process <task-id> <pid> [description]
bin/fm-external-wait.sh register-command <task-id> <pid> [description]
bin/fm-external-wait.sh register-background-probe <task-id> <pid> <predicate> [description]
bin/fm-external-wait.sh arm-background-probe-pulse <task-id> <pid>
bin/fm-external-wait.sh clear <task-id>
```

OAuth callbacks, CI or API polls, filesystem conditions, and other deterministic conditions should use predicates.
Tracked background helpers should use process registration unless their backend already produces a completion signal.
A command that continues doing task work after the foreground harness turn ends should use command registration.
Registration refuses a command whose current directory is outside the task's recorded physical worktree or task temp root.
The reconciler follows only descendants of the exact registered pid and compares their pid, start-time, and CPU-time shape with the last persisted observation; process names never select or classify the work, and no cross-home discovery occurs.
Fresh descendant progress is `working` evidence with source `owned-command`, while a live but unchanged tree ages out after the registered grace instead of masking a wedge forever.
The exact process exit or identity change remains an immediate model-free completion signal.
A paused task whose task-owned child can trigger a foreground progress probe must opt in with `register-background-probe`, which binds the exact live child identity, its task-scoped cwd, and an executable ledger predicate that is still pending at registration.
The static registration only establishes an eligible paused baseline and never owns foreground activity by itself.
Immediately before each one-shot foreground probe, the registered child must call `arm-background-probe-pulse` with its exact pid.
That durable pulse binds the registration id, lifecycle, endpoint, child identity, predicate evidence, paused status sequence and signatures, freshness deadline, and the pre-pulse Herdr working-edge marker.
Absorption requires the same pulse to remain current and a new Herdr `working` edge after the pulse was armed, then consumes the pulse atomically before committing the identical-pause return.
Any blocked edge without that exact pulse, a second use of a consumed pulse, pending composer input, expiry, or a changed bound value is fail-closed.
The reconciled record persists a `background-probe-invalidated` action before delivery whenever the armed baseline or pulse changes, including status/event/freshness, endpoint, task state, registration, child identity/liveness, predicate result/evidence, or push-time composer state.
An invalidated registration cannot re-arm until its action is acknowledged and a replacement registration establishes a new paused baseline.
The reconciler arms that opt-in only after it durably records an explicit paused status baseline containing the endpoint, status-event sequence, content signature, freshness signature, and pending predicate evidence.
An owned pulse may return to `idle` or the same explicit pause without waking only while the registration remains lifecycle-current, the child identity and cwd remain valid, the composer is empty, and every baseline field and pending predicate evidence remain byte-identical.
The baseline survives watcher restarts and repeated pulses, but any status change, predicate evidence change, predicate completion or failure, child exit or identity change, endpoint change, terminal state, non-empty or unreadable composer, or unacknowledged action fails closed to a wake.
An ordinary paused endpoint has no push exemption and wakes once on direct activity.
A `paused`, `blocked`, or `parked` task with no registration or legacy per-task check emits one `external-wait-unobservable` wake, including an existing task first observed after supervisor rollout, and a missing, non-executable, timed-out, or failed predicate emits one `external-wait-failed` wake.
An unchanged pending registration stays quiet, changed pending predicate evidence wakes immediately, and acknowledged completion or failure stays deduplicated across watcher and daemon restarts.
An unacknowledged transition token cannot be replaced by a newer observation during crash recovery; the wake retains the original event evidence, folds in any newer actionable condition, and persists the newer live state separately as current truth.
Newer status and turn-end evidence is folded into that pending wake before its exact suppressor signatures advance.
An unchanged pane remains quiet at every stale threshold while the reconciled reader still reports positive run-step, busy-pane, or progressing owned-command evidence; the watcher revalidates that evidence instead of converting elapsed time alone into a possible-wedge alarm.
Observer crashes, malformed results, and outer timeouts persist one `observer-failure` action, while watcher shutdown terminates and waits for every active batch worker before releasing singleton ownership.

## Task identity boundary

`bin/fm-spawn.sh` validates an existing ship/scout task id before it creates a backend endpoint or worktree.
`bin/fm-task-identity-lib.sh` persists a random repository-instance id in the git common directory and records it in `state/<id>.identity` before endpoint creation, so linked worktrees share a durable identity without relying on recyclable filesystem coordinates.
It refuses an unrelated repository and directs the caller to create a new linked task instead of overwriting the existing identity.
Successful teardown preserves that binding after volatile metadata and reconciliation state are removed.
Persistent secondmates remain bound to their configured home through the existing home/registry validators and are intentionally outside this repository guard because their metadata has no `project=` identity.

## Regression evidence

Before this repair, no durable per-cycle observation owner existed, and the no-run fallback could repeat a stale `paused:` or `blocked:` event after a newer live transition.
The pre-fix baseline has no `bin/fm-reconcile-lib.sh`, and the new regression suite requires that owner before running any scenario.

- `tests/fm-reconcile-lib.test.sh` covers working-to-parked review, same-repository endpoint replacement, positive-source loss behind stale working prose, stopped-without-`done`, OAuth completion, signaled predicates, failed and absent observers, busy absorption, acknowledgement, and restart recovery.
- `tests/fm-reconcile-watch-e2e.test.sh` runs the real durable watcher with heartbeat and stale cadences disabled, proves each production failure wakes within the classification poll, drains exactly one queued wake, restarts quietly, and observes a fleet in one bounded parallel batch.
- The stopped-endpoint canary touches the existing turn-end file without appending `done`, then asserts the wake reports status-event sequence 1 and the old pause as historical evidence rather than current truth.
- `tests/fm-crew-state-reconciled.test.sh` proves wake-time readers consume the fresh stopped state while the watcher retains a live-only evidence path.
- `tests/fm-external-wait.test.sh` covers predicate disappearance and evidence changes, tracked-process completion, task-scope refusal, owned-command progress/completion, durable one-shot background-probe pulses, invalidation, and exact child failure.
- `tests/fm-reconcile-watch-e2e.test.sh` drives the production watcher and Herdr event adapter across restart, proving generic paused activity wakes, explicitly owned pulses stay quiet without a stale wedge, unrelated blocked activity invalidates, and child/predicate failure wakes once.
- `tests/fm-daemon.test.sh` proves the durable daemon cannot re-absorb reconciled verdicts behind stale pause prose, replays an unaccepted queue handoff exactly once, and signals only the identity-matched daemon during restart.
- `tests/fm-fleet-snapshot-view.test.sh` proves snapshot, fleet view, and bearings keep reconciled truth, prior state, status event, and observer separate.
- `tests/fm-task-identity.test.sh` proves same-repository recovery and cross-repository refusal.

The stopped-endpoint canary pins the production evidence shape of a delivered turn-end, an absent claimed `done` append, a stopped endpoint, and an older pause event without weakening turn-end delivery.

## Post-merge rollout and live canary

1. Fast-forward the primary Firstmate checkout to the merged default-branch commit through the normal `/updatefirstmate` path, then record `git rev-parse HEAD`.
2. From that updated checkout, run `tests/fm-reconcile-watch-e2e.test.sh` and require every canary line to pass, including unchanged busy-pane suppression and idle-harness plus advancing-owned-command suppression, before touching the live owner.
3. In Codex normal mode, run `bin/fm-supervisor-start.sh --restart` as its own tracked background task, never with shell `&` or `nohup`.
4. Require the restart output to name the old identity-matched pid and then report that the normal daemon is starting.
5. Verify `state/.supervise-daemon.lock/pid` names a process whose command is the updated checkout's `bin/fm-supervise-daemon.sh` and whose start time is after the recorded update.
6. Verify `state/.watch.lock/owner-kind` is `daemon`, `state/.watch.lock/owner-pid` matches the daemon pid, `state/.watch.lock/watcher-path` names the updated checkout's `bin/fm-watch.sh`, and `state/.last-watcher-beat` is fresh.
7. Run `bin/fm-fleet-snapshot.sh --json` and inspect one live task to confirm `current_state.persisted` is true and the reconciled, prior, event, and wait objects are independently present.
8. Register a short task-worktree command through `register-command`, let its foreground harness read idle while the command advances past `FM_STALE_ESCALATE_SECS`, and confirm no stale/wedge queue record appears.
9. Stop that exact command, require one queue record containing `external-wait-complete`, then re-arm and confirm the unchanged completed state produces no second record.
10. Run one active-run to parked transition and one stopped-endpoint transition with no new `done` event, and require exactly one `reconciled-transition` queue record for each without waiting for heartbeat or stale cadence.
11. On a disposable paused Grok task, register a live task-worktree child and still-pending ledger predicate through `register-background-probe`, confirm the structured fleet snapshot reports an armed baseline, call `arm-background-probe-pulse` from that exact child immediately before each notification-driven foreground check, and trigger at least two pulses across one supervisor restart.
12. Require both pulses to return to the identical pause with no captain wake and no 255-second stale-wedge alarm, then change the predicate evidence and require one immediate wake.
13. Re-register the canary, stop the exact child while its predicate remains pending, require one `external-wait-failed` wake, and confirm the unchanged failure does not wake twice.
14. On a separate ordinary paused task with no background-probe registration, trigger direct endpoint activity and require exactly one immediate wake.

For non-Codex supervision protocols, run their documented home-scoped watcher restart after the same merged-code canary and verify `state/.watch.lock/watcher-path` and the fresh beacon in the same way.
