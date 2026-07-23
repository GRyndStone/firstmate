#!/usr/bin/env bash
# Task identity lifecycle tests: same-repository recovery is allowed and
# cross-repository reuse is refused with linked-task guidance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-identity-lib.sh
. "$ROOT/bin/fm-task-identity-lib.sh"

fm_test_tmproot TMP_ROOT fm-task-identity
state="$TMP_ROOT/state"
repo="$TMP_ROOT/repo"
same_wt="$TMP_ROOT/same-worktree"
other="$TMP_ROOT/other"
fresh_state="$TMP_ROOT/fresh-state"
mkdir -p "$state"
fm_git_init_commit "$repo"
git -C "$repo" worktree add --quiet -b recovery "$same_wt"
fm_git_init_commit "$other"

fm_task_identity_bind "$fresh_state" fresh "$repo" \
  || fail "task identity binding could not create its missing state directory"
[ -f "$fresh_state/fresh.identity" ] \
  || fail "task identity binding did not persist into its newly created state directory"
pass "task identity binding creates its lock parent on a clean home"
repo_key=$(fm_task_identity_repository_key "$repo") || fail "repository instance key could not be resolved"
linked_key=$(fm_task_identity_repository_key "$same_wt") || fail "linked worktree instance key could not be resolved"
case "$repo_key" in git:v3:*) ;; *) fail "repository identity still uses recyclable filesystem coordinates: $repo_key" ;; esac
[ "$linked_key" = "$repo_key" ] || fail "linked worktree did not share its repository instance identity"
common_dir=$(fm_task_identity_git_common_dir "$repo") || fail "git common directory could not be resolved"
[ -f "$common_dir/firstmate-repository-id" ] || fail "repository instance identity was not persisted in the git common directory"
pass "repository identity is durable, non-filesystem-derived, and shared by linked worktrees"

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

legacy_state="$TMP_ROOT/legacy-state"
mkdir -p "$legacy_state"
legacy_key=$(fm_task_identity_legacy_repository_key "$repo") || fail "legacy repository key could not be resolved"
fm_write_meta "$legacy_state/legacy.identity" \
  'schema=fm-task-identity.v2' \
  'task=legacy' \
  "repository_identity=$legacy_key" \
  "project=$repo"
fm_task_identity_bind "$legacy_state" legacy "$same_wt" \
  || fail "same-repository legacy binding could not migrate"
[ "$(fm_task_identity_meta_value "$legacy_state/legacy.identity" schema)" = fm-task-identity.v3 ] \
  || fail "legacy repository binding did not migrate to the durable identity schema"
[ "$(fm_task_identity_meta_value "$legacy_state/legacy.identity" repository_identity)" = "$repo_key" ] \
  || fail "legacy repository binding did not adopt the shared repository instance id"
pass "legacy repository bindings migrate to durable instance identity"

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
fm_write_criteria "$TMP_ROOT/data" "task"
printf 'live pi hook\n' > "$state/task.pi-ext.ts"
printf 'live-token\n' > "$state/task.grok-turnend-token"
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
[ "$(cat "$state/task.pi-ext.ts")" = 'live pi hook' ] \
  || fail "failed replacement spawn removed another lifecycle's pi hook"
[ "$(cat "$state/task.grok-turnend-token")" = 'live-token' ] \
  || fail "failed replacement spawn removed another lifecycle's Grok token"
pass "failed replacement spawn preserves the live lifecycle and its owned artifacts"

path_state="$TMP_ROOT/path-state"
escape_artifact="$TMP_ROOT/escape.pi-ext.ts"
mkdir -p "$path_state"
printf 'live lifecycle hook\n' > "$escape_artifact"
if FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$path_state" \
  FM_DATA_OVERRIDE="$TMP_ROOT/data" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
  FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
  "$ROOT/bin/fm-spawn.sh" '../escape' "$other" --harness codex 2> "$err"; then
  fail "spawn accepted a path-traversing task id"
fi
grep -F "invalid task id '../escape'" "$err" >/dev/null \
  || fail "path-traversing spawn refusal did not identify the invalid task id"
[ "$(cat "$escape_artifact")" = 'live lifecycle hook' ] \
  || fail "invalid-id abort cleanup removed an artifact outside its task scope"
pass "spawn validates task ids before installing artifact cleanup"

fm_write_meta "$state/missing.meta" 'window=session:fm-missing' 'kind=ship'
if fm_task_identity_validate "$state" missing "$repo" 2> "$err"; then
  fail "missing recorded repository identity should fail closed"
fi
pass "existing task metadata without a provable repository identity fails closed"

fm_task_identity_bind "$state" task "$repo" \
  || fail "existing task metadata could not bootstrap a durable repository binding"
[ -f "$state/task.identity" ] || fail "repository binding was not persisted"
rm -f "$state/task.meta"
fm_task_identity_validate "$state" task "$same_wt" \
  || fail "durable binding rejected same-repository reuse after metadata removal"
if fm_task_identity_validate "$state" task "$other" 2> "$err"; then
  fail "metadata removal erased the cross-repository task-id guard"
fi
grep -F "task id 'task' is already bound" "$err" >/dev/null \
  || fail "durable cross-repository refusal lost the bound task id"
pass "task identity remains repository-bound after volatile metadata removal"

retired_repo="$TMP_ROOT/retired-repo"
retired_key=$(fm_task_identity_repository_key "$repo") || fail "retired repository key could not be captured"
mv "$repo" "$retired_repo"
fm_git_init_commit "$repo"
replacement_key=$(fm_task_identity_repository_key "$repo") || fail "replacement repository key could not be resolved"
[ "$replacement_key" != "$retired_key" ] || fail "replacement repository recycled the retired instance identity"
if fm_task_identity_validate "$state" task "$repo" 2> "$err"; then
  fail "repository replacement at the same path reused a durable task id"
fi
grep -F "task id 'task' is already bound" "$err" >/dev/null \
  || fail "same-path repository replacement refusal lost the bound task id"
pass "task identity rejects a replacement repository at the recorded path"

echo "# fm-task-identity.test.sh: all assertions passed"
