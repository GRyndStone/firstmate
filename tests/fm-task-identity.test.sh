#!/usr/bin/env bash
# Task identity lifecycle tests: same-repository recovery is allowed and
# cross-repository reuse is refused with linked-task guidance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-identity-lib.sh
. "$ROOT/bin/fm-task-identity-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-identity)
state="$TMP_ROOT/state"
repo="$TMP_ROOT/repo"
same_wt="$TMP_ROOT/same-worktree"
other="$TMP_ROOT/other"
mkdir -p "$state"
fm_git_init_commit "$repo"
git -C "$repo" worktree add --quiet -b recovery "$same_wt"
fm_git_init_commit "$other"
fm_write_meta "$state/task.meta" \
  'window=session:fm-task' \
  "project=$repo" \
  "worktree=$same_wt" \
  'kind=ship'

fm_task_identity_validate "$state" task "$repo" \
  || fail "exact-project recovery should remain valid"
fm_task_identity_validate "$state" task "$same_wt" \
  || fail "same-repository linked-worktree recovery should remain valid"
pass "task identity accepts exact and linked-worktree recovery in the same repository"

err="$TMP_ROOT/cross.err"
if fm_task_identity_validate "$state" task "$other" 2> "$err"; then
  fail "task identity silently migrated across unrelated repositories"
fi
grep -F "task id 'task' is already bound" "$err" >/dev/null \
  || fail "cross-repository refusal did not identify the bound task id"
grep -F 'Create a new task id' "$err" >/dev/null \
  || fail "cross-repository refusal did not guide the caller to a linked task"
pass "task identity refuses cross-repository reuse with linked-task guidance"

mkdir -p "$TMP_ROOT/data/task" "$TMP_ROOT/config" "$TMP_ROOT/projects"
printf 'brief\n' > "$TMP_ROOT/data/task/brief.md"
spawn_before=$(cksum "$state/task.meta")
if FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT" \
  FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$TMP_ROOT/data" \
  FM_CONFIG_OVERRIDE="$TMP_ROOT/config" FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" \
  FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
  "$ROOT/bin/fm-spawn.sh" task "$other" --harness codex 2> "$err"; then
  fail "spawn lifecycle boundary accepted cross-repository task-id reuse"
fi
grep -F 'Create a new task id' "$err" >/dev/null \
  || fail "spawn lifecycle refusal lost linked-task guidance"
[ "$(cksum "$state/task.meta")" = "$spawn_before" ] \
  || fail "spawn lifecycle refusal rewrote the existing task metadata"
pass "spawn refuses cross-repository reuse before endpoint creation or metadata replacement"

fm_write_meta "$state/missing.meta" 'window=session:fm-missing' 'kind=ship'
if fm_task_identity_validate "$state" missing "$repo" 2> "$err"; then
  fail "missing recorded repository identity should fail closed"
fi
pass "existing task metadata without a provable repository identity fails closed"

echo "# fm-task-identity.test.sh: all assertions passed"
