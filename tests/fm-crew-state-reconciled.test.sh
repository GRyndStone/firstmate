#!/usr/bin/env bash
# Point-in-time crew-state reads prefer a fresh durable reconciled observation,
# while the watcher's explicit live-only path still reaches underlying evidence.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state-reconciled)
dir=$(make_case reconciled)
state="$dir/state"
fakebin="$dir/fakebin"
wt="$dir/worktree"
window='session:fm-task'
mkdir -p "$wt"
fm_write_meta "$state/task.meta" \
  "window=$window" \
  "worktree=$wt" \
  "project=$dir/project" \
  'kind=ship'
printf 'paused: stale old-head event\n' > "$state/task.status"
printf 'idle pane\n' > "$dir/pane.txt"
now=$(date +%s)
fm_write_meta "$state/task.reconciled" \
  'schema=fm-reconciled.v1' \
  'task=task' \
  "endpoint=$window" \
  'state=unknown' \
  'source=none' \
  'detail=backend target stopped without claimed done event' \
  'evidence=state: unknown · source: none · backend target stopped' \
  "observed_at=$now"

out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
  FM_STATE_OVERRIDE="$state" "$CREW_STATE" task)
assert_contains "$out" 'state: unknown · source: none' \
  "point-in-time crew state repeated the stale paused event instead of reconciled truth"
assert_contains "$out" 'reconciled' "point-in-time crew state did not identify persisted freshness"

live=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
  FM_CREW_STATE_LIVE_ONLY=1 FM_STATE_OVERRIDE="$state" "$CREW_STATE" task)
assert_contains "$live" 'state: paused · source: status-log' \
  "live-only watcher read did not bypass the persisted observation"
pass "crew-state readers see fresh reconciled truth while the watcher retains a live-only evidence path"

echo "# fm-crew-state-reconciled.test.sh: all assertions passed"
