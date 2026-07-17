#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, refresh/prune the project's clone for PR-based ship
# tasks, then record backlog completion through the serialized backlog wrapper
# for ship and scout teardowns when the tasks-axi backend is active.
# Completion happens only after owned meta and teardown state are gone.
# Before endpoint or worktree cleanup, teardown persists any required
# completion proof plus a phase record bound to the cleanup target's exact path
# identity outside the target itself.
# An interrupted retry advances that phase only while the identity still matches;
# once it changes, teardown never inspects or removes the recorded path again.
# A secondmate teardown records no backlog completion because secondmates are
# not backlog items.
# Touches a state/<task-id>.tearing-down tombstone before the endpoint-affecting
# cleanup and removes it with the task's other state files, so the watcher absorbs
# the teardown's own gone endpoint while the tombstone is fresh
# (FM_TEARDOWN_TOMBSTONE_SECS) instead of waking on it as a crew death.
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=teardown
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
fm_tasks_axi_valid_task_id "$ID" || {
  echo "error: invalid task id: $ID" >&2
  exit 2
}
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
COMPLETION_PROOF="$STATE/$ID.teardown-complete"
TEARDOWN_STAGE="$STATE/$ID.teardown-stage"
META_CKSUM=$(cksum < "$META" | awk '{print $1 ":" $2}') || exit 1
RESUMING_STAGE=0
STAGE_PHASE=
STAGE_OWNER_IDENTITY=
STAGE_OUTCOME=
STAGE_RECORD_CKSUM=
stage_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$TEARDOWN_STAGE" | tail -1
}
if [ -e "$TEARDOWN_STAGE" ] || [ -L "$TEARDOWN_STAGE" ]; then
  if [ ! -f "$TEARDOWN_STAGE" ] || [ -L "$TEARDOWN_STAGE" ] \
     || [ "$(stage_value version)" != 2 ] \
     || [ "$(stage_value task)" != "$ID" ] \
     || [ "$(stage_value meta-cksum)" != "$META_CKSUM" ]; then
    echo "REFUSED: invalid or stale teardown stage at $TEARDOWN_STAGE; preserving lifecycle state." >&2
    exit 1
  fi
  STAGE_PHASE=$(stage_value phase)
  case "$STAGE_PHASE" in
    prepared|endpoint-closed|worktree-cleanup-started|worktree-cleaned|ownership-lost) ;;
    *) echo "REFUSED: invalid teardown phase in $TEARDOWN_STAGE; preserving lifecycle state." >&2; exit 1 ;;
  esac
  STAGE_OWNER_IDENTITY=$(stage_value owner-identity)
  STAGE_OUTCOME=$(stage_value outcome)
  STAGE_RECORD_CKSUM=$(stage_value record-cksum)
  [ -n "$STAGE_OWNER_IDENTITY" ] && [ -n "$STAGE_OUTCOME" ] && [ -n "$STAGE_RECORD_CKSUM" ] || {
    echo "REFUSED: incomplete teardown stage at $TEARDOWN_STAGE; preserving lifecycle state." >&2
    exit 1
  }
  RESUMING_STAGE=1
elif [ -e "$COMPLETION_PROOF" ] || [ -L "$COMPLETION_PROOF" ]; then
  rm -f "$COMPLETION_PROOF" 2>/dev/null || {
    echo "REFUSED: cannot clear stale completion proof at $COMPLETION_PROOF; preserving lifecycle state." >&2
    exit 1
  }
fi
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
case "$BACKEND" in
  herdr|zellij|cmux)
  DUPLICATE_AUDIT=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-endpoint-audit.sh" --json --task "$ID"
  ) || {
    echo "REFUSED: could not complete the same-home duplicate endpoint audit for $ID." >&2
    echo "Restore read-only $BACKEND inventory access and retry; teardown will not guess which endpoint is owned." >&2
    exit 1
  }
  DUPLICATE_LIVE=$(printf '%s' "$DUPLICATE_AUDIT" | jq -r --arg id "$ID" \
    '[.[] | select(.task == $id) | .live_endpoints[]] | unique | join(",")') || exit 1
  DUPLICATE_KINDS=$(printf '%s' "$DUPLICATE_AUDIT" | jq -r --arg id "$ID" \
    '[.[] | select(.task == $id) | .kind] | unique | join(",")') || exit 1
  if [ -n "$DUPLICATE_KINDS" ]; then
    echo "REFUSED: task $ID has a same-home endpoint ownership anomaly: kind=$DUPLICATE_KINDS live=${DUPLICATE_LIVE:-unknown}" >&2
    echo "Inspect and reconcile exact endpoints without a broad sweep or automatic closure, then retry teardown." >&2
    exit 1
  fi
  ;;
esac
if [ "$BACKEND" = orca ]; then
  T_ORCA=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$T_ORCA" ] && T=$T_ORCA
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
BACKLOG_TRACKED=0
BACKLOG_RECORD_CKSUM=
if fm_tasks_axi_backend_available "$CONFIG"; then
  if BACKLOG_LOOKUP=$("$SCRIPT_DIR/fm-backlog.sh" show "$ID" --full 2>&1); then
    BACKLOG_TRACKED=1
    BACKLOG_RECORD_CKSUM=$(printf '%s' "$BACKLOG_LOOKUP" | fm_tasks_axi_task_fingerprint) || {
      echo "REFUSED: tasks-axi returned no stable task record for $ID." >&2
      exit 1
    }
  elif printf '%s\n' "$BACKLOG_LOOKUP" | grep -q 'code:[[:space:]]*NOT_FOUND'; then
    BACKLOG_TRACKED=0
  else
    echo "REFUSED: could not determine whether backlog task $ID exists." >&2
    [ -z "$BACKLOG_LOOKUP" ] || printf '%s\n' "$BACKLOG_LOOKUP" >&2
    echo "Repair the selected home's backlog/configuration and retry; teardown will preserve lifecycle state." >&2
    exit 1
  fi
fi
if [ "$RESUMING_STAGE" -eq 1 ] \
   && [ "$STAGE_RECORD_CKSUM" != "${BACKLOG_RECORD_CKSUM:-none}" ]; then
  echo "REFUSED: backlog task $ID changed after teardown was staged; preserving lifecycle state." >&2
  echo "Reconcile the staged lifecycle against the current backlog record before retrying." >&2
  exit 1
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_record_after_teardown() {
  local report_path reason
  [ "$KIND" = secondmate ] && return 0
  if fm_tasks_axi_backend_available "$CONFIG"; then
    if [ "$BACKLOG_TRACKED" -ne 1 ]; then
      printf '%s\n' "Backlog: $ID was not present in this home's tasks-axi backlog before teardown; no Done mutation was attempted. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
      return 0
    fi
    case "$DELIVERY_OUTCOME" in
      delivered-report)
        report_path="data/$ID/report.md"
        if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --report "$report_path" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done with $report_path after successful teardown. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for scout $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      delivered-local)
        if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --note "local main" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done with local main after successful teardown. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      delivered-pr)
        if [ -n "$PR_URL" ]; then
          if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --pr "$PR_URL" >/dev/null; then
            printf '%s\n' "Backlog: $ID recorded Done with $PR_URL after successful teardown. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
          else
            echo "error: teardown completed, but serialized backlog completion failed for $ID; it remains outside Done" >&2
            return 1
          fi
        elif "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --note "merged PR verified" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done after its merged PR was verified. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      delivered-default)
        if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --note "default branch contains delivered work" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done after delivery to the default branch was verified. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      discarded|unlanded)
        if [ "$DELIVERY_OUTCOME" = discarded ]; then
          reason="discarded during explicitly forced teardown; no successful delivery recorded"
        else
          reason="teardown complete but work is recoverable only outside the delivered default branch; no successful delivery recorded"
        fi
        if "$SCRIPT_DIR/fm-backlog.sh" hold "$ID" --reason "$reason" --kind parked >/dev/null \
           && "$SCRIPT_DIR/fm-backlog.sh" reopen "$ID" >/dev/null; then
          printf '%s\n' "Backlog: $ID remains outside Done with a structured $DELIVERY_OUTCOME hold after teardown."
        else
          echo "error: teardown completed, but truthful $DELIVERY_OUTCOME backlog recording failed for $ID" >&2
          return 1
        fi
        ;;
    esac
  else
    if [ "$DELIVERY_OUTCOME" = discarded ] || [ "$DELIVERY_OUTCOME" = unlanded ]; then
      printf '%s\n' "Backlog: $ID teardown succeeded with outcome $DELIVERY_OUTCOME. In manual backend mode, keep it outside Done and record a non-runnable structured hold with that reason."
    else
      printf '%s\n' "Backlog: $ID teardown succeeded. In manual backend mode only, update data/backlog.md now - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
    fi
  fi
}

write_completion_proof() {
  local tmp
  [ "$BACKLOG_TRACKED" -eq 1 ] || return 0
  case "$DELIVERY_OUTCOME" in
    delivered-report|delivered-local|delivered-pr|delivered-default) ;;
    *) return 0 ;;
  esac
  tmp="$COMPLETION_PROOF.tmp.$$"
  if ! {
    printf 'version=1\n'
    printf 'task=%s\n' "$ID"
    printf 'kind=%s\n' "$KIND"
    printf 'outcome=%s\n' "$DELIVERY_OUTCOME"
    printf 'record-cksum=%s\n' "$BACKLOG_RECORD_CKSUM"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -e "$COMPLETION_PROOF" ] || [ -L "$COMPLETION_PROOF" ]; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$COMPLETION_PROOF"; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$COMPLETION_PROOF" ] && [ ! -L "$COMPLETION_PROOF" ]
}

completion_proof_required() {
  [ "$BACKLOG_TRACKED" -eq 1 ] || return 1
  case "$DELIVERY_OUTCOME" in
    delivered-report|delivered-local|delivered-pr|delivered-default) return 0 ;;
  esac
  return 1
}

completion_proof_matches() {
  [ -f "$COMPLETION_PROOF" ] && [ ! -L "$COMPLETION_PROOF" ] || return 1
  [ "$(sed -n 's/^version=//p' "$COMPLETION_PROOF" | tail -1)" = 1 ] \
    && [ "$(sed -n 's/^task=//p' "$COMPLETION_PROOF" | tail -1)" = "$ID" ] \
    && [ "$(sed -n 's/^kind=//p' "$COMPLETION_PROOF" | tail -1)" = "$KIND" ] \
    && [ "$(sed -n 's/^outcome=//p' "$COMPLETION_PROOF" | tail -1)" = "$DELIVERY_OUTCOME" ] \
    && [ "$(sed -n 's/^record-cksum=//p' "$COMPLETION_PROOF" | tail -1)" = "$BACKLOG_RECORD_CKSUM" ]
}

ensure_completion_proof() {
  completion_proof_required || return 0
  if [ -e "$COMPLETION_PROOF" ] || [ -L "$COMPLETION_PROOF" ]; then
    completion_proof_matches
    return
  fi
  write_completion_proof
}

teardown_owner_path() {
  if [ "$KIND" = secondmate ]; then
    printf '%s\n' "$HOME_PATH"
  else
    printf '%s\n' "$WT"
  fi
}

teardown_owner_identity() {
  local owner canonical inode path_cksum
  owner=$(teardown_owner_path)
  [ -n "$owner" ] && [ -d "$owner" ] || {
    printf 'absent\n'
    return 0
  }
  canonical=$(cd "$owner" 2>/dev/null && pwd -P) || return 1
  inode=$(stat -f '%d:%i' "$canonical" 2>/dev/null \
    || stat -c '%d:%i' "$canonical" 2>/dev/null) || return 1
  path_cksum=$(printf '%s' "$canonical" | cksum | awk '{print $1 ":" $2}') || return 1
  printf '%s:%s\n' "$inode" "$path_cksum"
}

write_teardown_stage() {
  local phase=$1 owner_identity=$2 tmp
  tmp="$TEARDOWN_STAGE.tmp.$$"
  if ! {
    printf 'version=2\n'
    printf 'task=%s\n' "$ID"
    printf 'meta-cksum=%s\n' "$META_CKSUM"
    printf 'phase=%s\n' "$phase"
    printf 'owner-identity=%s\n' "$owner_identity"
    printf 'outcome=%s\n' "$DELIVERY_OUTCOME"
    printf 'record-cksum=%s\n' "${BACKLOG_RECORD_CKSUM:-none}"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -L "$TEARDOWN_STAGE" ] || ! mv "$tmp" "$TEARDOWN_STAGE"; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$TEARDOWN_STAGE" ] && [ ! -L "$TEARDOWN_STAGE" ]
}

owner_identity_matches() {
  local expected=${1:-$STAGE_OWNER_IDENTITY} current owner
  if [ "$expected" = absent ]; then
    owner=$(teardown_owner_path)
    [ -z "$owner" ] || { [ ! -e "$owner" ] && [ ! -L "$owner" ]; }
    return
  fi
  current=$(teardown_owner_identity) || return 1
  [ "$current" = "$expected" ]
}

prepare_teardown_stage() {
  local identity
  identity=$(teardown_owner_identity) || return 1
  write_teardown_stage prepared "$identity" || return 1
  STAGE_PHASE=prepared
  STAGE_OWNER_IDENTITY=$identity
  STAGE_OUTCOME=$DELIVERY_OUTCOME
  STAGE_RECORD_CKSUM=${BACKLOG_RECORD_CKSUM:-none}
  if ! ensure_completion_proof; then
    echo "REFUSED: could not persist completion proof for $ID; no endpoint or worktree cleanup was attempted." >&2
    rm -f "$TEARDOWN_STAGE"
    return 1
  fi
}

advance_teardown_stage() {
  local phase=$1
  write_teardown_stage "$phase" "$STAGE_OWNER_IDENTITY" || return 1
  STAGE_PHASE=$phase
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

standalone_git_worktree() {
  local target=$1 git_dir common_dir
  [ -d "$target/.git" ] && [ ! -L "$target/.git" ] || return 1
  inspectable_git_worktree "$target" || return 1
  git_dir=$(git -C "$target" rev-parse --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$target" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = .git ] && [ "$common_dir" = .git ]
}

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc

  if [ -n "$post_cleanup_check" ] && ! "$post_cleanup_check"; then
    echo "teardown: $label return aborted because cleanup authority or safety checks failed" >&2
    return 1
  fi

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if [ -n "$post_cleanup_check" ] && ! "$post_cleanup_check"; then
      echo "teardown: $label return retry aborted because cleanup authority or safety checks failed" >&2
      return 1
    fi
    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE "^\?\? (\\.claude/|\\.fm-grok-turnend$)" | head -1 || true)

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

delivery_outcome_before_teardown() {
  local branch default
  if [ "$KIND" = secondmate ]; then
    printf 'not-applicable'
    return 0
  fi
  if [ "$FORCE" = --force ]; then
    printf 'discarded'
    return 0
  fi
  if [ "$KIND" = scout ]; then
    printf 'delivered-report'
    return 0
  fi
  if ! inspectable_git_worktree "$WT"; then
    printf 'unlanded'
    return 0
  fi
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf HEAD)
  if [ "$MODE" = local-only ]; then
    default=$(default_branch) || { printf 'unlanded'; return 0; }
    if git -C "$WT" merge-base --is-ancestor HEAD "refs/heads/$default" 2>/dev/null; then
      printf 'delivered-local'
    else
      printf 'unlanded'
    fi
    return 0
  fi
  if [ -n "$PR_URL" ]; then
    if pr_is_merged "$branch"; then
      printf 'delivered-pr'
    else
      printf 'unlanded'
    fi
    return 0
  fi
  if pr_is_merged "$branch"; then
    printf 'delivered-pr'
  elif content_in_default; then
    printf 'delivered-default'
  else
    printf 'unlanded'
  fi
}

close_endpoint_before_lifecycle_cleanup() {
  local attempt=0 endpoint_state
  [ -n "$T" ] || {
    echo "REFUSED: task $ID has no exact recorded endpoint to close." >&2
    return 1
  }
  endpoint_state=$(fm_backend_target_state "$BACKEND" "$T" "fm-$ID" "$(meta_value "$META" zellij_tab_id)")
  case "$endpoint_state" in
    present)
      FM_BACKEND_STRICT_CLOSE=1 fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" || {
        echo "REFUSED: failed to close exact endpoint $T for task $ID; preserving lifecycle state." >&2
        return 1
      }
      ;;
    absent) ;;
    *)
      echo "REFUSED: endpoint state for $T is unknown; preserving lifecycle state for $ID." >&2
      return 1
      ;;
  esac
  while [ "$attempt" -lt 10 ]; do
    endpoint_state=$(fm_backend_target_state "$BACKEND" "$T" "fm-$ID" "$(meta_value "$META" zellij_tab_id)")
    case "$endpoint_state" in
      absent) return 0 ;;
      unknown)
        echo "REFUSED: cannot confirm endpoint $T is absent after close; preserving lifecycle state for $ID." >&2
        return 1
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "REFUSED: endpoint $T still exists after close; preserving lifecycle state for $ID." >&2
  return 1
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

revalidate_owned_cleanup() {
  local safety_rc
  if ! owner_identity_matches; then
    echo "REFUSED: teardown cleanup-target identity no longer matches for $ID." >&2
    return 1
  fi

  if [ "$KIND" = secondmate ]; then
    validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || return 1
    if [ "$FORCE" = "--force" ]; then
      validate_firstmate_home_children_removal "$HOME_PATH" || return 1
    fi
    return 0
  fi

  if [ "$BACKEND" = orca ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || return 1
    ORCA_PATH_MATCH_VERIFIED=1
  elif [ -d "$WT" ]; then
    if ! worktree_registered_for_project "$PROJ" "$WT" \
       && ! standalone_git_worktree "$WT"; then
      echo "REFUSED: recorded cleanup target $WT is neither the project worktree nor a standalone git checkout for $ID." >&2
      return 1
    fi
  fi

  if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
    if validate_worktree_teardown_safety; then
      :
    else
      safety_rc=$?
      if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
        cleanup_stale_lock_for_safety_check "$WT" || return 1
        owner_identity_matches || {
          echo "REFUSED: teardown cleanup-target identity changed while retrying safety checks for $ID." >&2
          return 1
        }
        validate_worktree_teardown_safety || return 1
      else
        return 1
      fi
    fi
  fi
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

audit_firstmate_home_children_endpoints() {
  local home=$1 sub_state child_meta child_id child_backend child_kind child_home child_wt audit live kinds
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_backend=$(fm_backend_of_meta "$child_meta")
    case "$child_backend" in
      herdr|zellij|cmux)
        audit=$(
          FM_ROOT_OVERRIDE="$home" \
            FM_HOME="$home" \
            FM_STATE_OVERRIDE="$sub_state" \
            FM_DATA_OVERRIDE="$home/data" \
            FM_CONFIG_OVERRIDE="$home/config" \
            "$SCRIPT_DIR/fm-endpoint-audit.sh" --json --task "$child_id"
        ) || {
          echo "REFUSED: could not complete the child-home duplicate endpoint audit for $child_id in $home." >&2
          echo "Restore exact-home $child_backend inventory access and retry; forced retirement will not guess which child endpoint is owned." >&2
          return 1
        }
        live=$(printf '%s' "$audit" | jq -r --arg id "$child_id" \
          '[.[] | select(.task == $id) | .live_endpoints[]] | unique | join(",")') || return 1
        kinds=$(printf '%s' "$audit" | jq -r --arg id "$child_id" \
          '[.[] | select(.task == $id) | .kind] | unique | join(",")') || return 1
        if [ -n "$kinds" ]; then
          echo "REFUSED: child task $child_id has a same-home endpoint ownership anomaly: kind=$kinds live=${live:-unknown}" >&2
          echo "Inspect and reconcile exact child endpoints without automatic closure, then retry retirement." >&2
          return 1
        fi
        ;;
    esac
    child_kind=$(meta_value "$child_meta" kind)
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      audit_firstmate_home_children_endpoints "$child_home" || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    if [ -n "$child_t" ]; then
      # Tombstone for the child home's own watcher, same contract as the main
      # task path: a mid-teardown gone endpoint is teardown, not a crew death.
      touch "$sub_state/$child_id.tearing-down"
      if [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) 2>/dev/null || true
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" 2>/dev/null || true
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home"
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id"
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      fi
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree"; then
          :
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
            return "$child_return_rc"
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj"
        fi
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.check.sh" "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token" "$sub_state/$child_id.tearing-down"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    audit_firstmate_home_children_endpoints "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
fi

if [ "$RESUMING_STAGE" -eq 1 ]; then
  DELIVERY_OUTCOME=$STAGE_OUTCOME
  case "$STAGE_PHASE" in
    prepared)
      revalidate_owned_cleanup || exit 1
      ;;
    endpoint-closed|worktree-cleanup-started)
      :
      ;;
    ownership-lost)
      echo "REFUSED: teardown ownership is lost for $ID; reconcile the external cleanup state without reusing the recorded path." >&2
      exit 1
      ;;
  esac
fi

if { [ "$RESUMING_STAGE" -eq 0 ] || [ "$STAGE_PHASE" = prepared ]; } \
   && [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

if { [ "$RESUMING_STAGE" -eq 0 ] || [ "$STAGE_PHASE" = prepared ]; } \
   && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

if [ "$RESUMING_STAGE" -eq 0 ]; then
  DELIVERY_OUTCOME=$(delivery_outcome_before_teardown) || exit 1
  prepare_teardown_stage || {
    echo "REFUSED: could not stage retryable teardown state for $ID; no endpoint or worktree cleanup was attempted." >&2
    exit 1
  }
fi
ensure_completion_proof || {
  echo "REFUSED: could not persist completion proof for $ID; no endpoint or worktree cleanup was attempted." >&2
  exit 1
}

# Tombstone for the watcher: everything from here to the state-file removal can
# take the task's endpoint down, and a gone endpoint whose
# meta still exists must read as teardown-in-progress, not a crew death
# (fm-watch.sh handle_gone_endpoint). Removed with the other state files below;
# the watcher's absorb is age-bounded, so a crashed teardown cannot suppress a
# real death past the bound.
touch "$STATE/$ID.tearing-down"
if [ "$STAGE_PHASE" = prepared ]; then
  close_endpoint_before_lifecycle_cleanup || exit 1
  advance_teardown_stage endpoint-closed || {
    echo "REFUSED: endpoint closed, but the durable teardown phase could not be advanced for $ID." >&2
    exit 1
  }
fi

perform_owned_cleanup() {
  local branch post_lock_cleanup_check
  revalidate_owned_cleanup || return 1
  if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
    cleanup_firstmate_home_children "$HOME_PATH" || return 1
  fi
  if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
    if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
      require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || return 1
      ORCA_PATH_MATCH_VERIFIED=1
    fi
    if [ -d "$WT" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      if [ "$branch" != "HEAD" ]; then
        if git -C "$WT" checkout --detach -q 2>/dev/null; then
          git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
        fi
      fi
      rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
    fi
    fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID" || return 1
  elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" "$WT/.fm-grok-turnend"
    post_lock_cleanup_check=revalidate_owned_cleanup
    teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" || {
      echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
      return 1
    }
  fi
  if [ "$KIND" = secondmate ]; then
    [ -n "$HOME_PATH" ] || HOME_PATH=$WT
    remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" || return 1
    remove_secondmate_registry_entry "$ID" || return 1
  fi
}

if [ "$STAGE_PHASE" = endpoint-closed ]; then
  if ! revalidate_owned_cleanup; then
    if ! owner_identity_matches; then
      advance_teardown_stage ownership-lost || true
    fi
    exit 1
  fi
  advance_teardown_stage worktree-cleanup-started || {
    echo "REFUSED: could not record cleanup ownership before destructive work for $ID." >&2
    exit 1
  }
fi
if [ "$STAGE_PHASE" = worktree-cleanup-started ]; then
  if ! revalidate_owned_cleanup; then
    if ! owner_identity_matches; then
      advance_teardown_stage ownership-lost || {
        echo "REFUSED: ownership was lost after interrupted cleanup, and that state could not be persisted for $ID." >&2
        exit 1
      }
      echo "REFUSED: teardown ownership is lost for $ID; preserving lifecycle state without inspecting or removing the recorded path." >&2
    fi
    exit 1
  fi
  perform_owned_cleanup || exit 1
  advance_teardown_stage worktree-cleaned || {
    echo "REFUSED: cleanup finished, but the durable teardown phase could not be advanced for $ID." >&2
    exit 1
  }
fi
if [ "$STAGE_PHASE" = ownership-lost ]; then
  echo "REFUSED: teardown ownership is lost for $ID; reconcile the external cleanup state without reusing the recorded path." >&2
  exit 1
fi
remove_grok_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" "$STATE/$ID.tearing-down" "$TEARDOWN_STAGE"
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_record_after_teardown
