#!/usr/bin/env bash
# Tear down a finished task through exact-home endpoint ownership preflight,
# then release its backend/worktree resources or retire a secondmate home.
# Backends without verified exact-home inventories fail closed before closure.
# Successful PR-based ship paths refresh/prune the project's clone.
# Ship and scout paths record backlog completion through the configured
# serialized backlog wrapper.
# Completion happens only from the durable finalizing phase after endpoint and
# cleanup ownership are closed; meta and phase state remain until the serialized
# backlog mutation succeeds.
# Before endpoint or worktree cleanup, teardown persists a staged completion
# binding plus a phase record outside every removal target, bound to a
# non-recyclable task-owned marker and the cleanup target's exact path identity.
# The binding proves nothing alone; backlog finalization accepts it only with
# the retained finalizing phase and independently confirmed cleanup.
# An interrupted retry removes only while both bindings still match, and can
# independently confirm completed cleanup without touching a replacement path.
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
# product. Non-forced teardown requires it, and all endpoint ownership
# preflights still apply.
# Orca worktree and terminal release primitives remain bound to recorded identity,
# but current teardown fails closed before either cleanup because Orca lacks a
# verified exact-home duplicate inventory; it never guesses from ambient CLI state.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that preflights exact-home child endpoint ownership
# and removal targets, then discards child work, kills child runtime endpoints,
# and removes the retired home. Removing a
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
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$SCRIPT_DIR/fm-treehouse-lib.sh"
fm_validate_effective_state_path "$STATE" existing || exit 1
STATE=$FM_VALIDATED_STATE_PATH
[ -z "${FM_STATE_OVERRIDE:-}" ] || FM_STATE_OVERRIDE=$STATE

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
REQUESTED_FORCE=$FORCE
if [ "$#" -gt 2 ]; then
  echo "error: teardown accepts only one optional --force argument" >&2
  echo "usage: fm-teardown.sh <task-id> [--force]" >&2
  exit 2
fi
case "$REQUESTED_FORCE" in
  ''|--force) ;;
  *)
    echo "error: invalid teardown force request: $REQUESTED_FORCE" >&2
    echo "usage: fm-teardown.sh <task-id> [--force]" >&2
    exit 2
    ;;
esac

META="$STATE/$ID.meta"
TEARDOWN_LOCK="$STATE/.$ID.teardown.lock"
TEARDOWN_LOCKED=0
release_teardown_lock() {
  if [ "$TEARDOWN_LOCKED" -eq 1 ]; then
    fm_lock_release "$TEARDOWN_LOCK"
    TEARDOWN_LOCKED=0
  fi
}
teardown_exit() {
  local status=$?
  trap - EXIT INT TERM
  release_teardown_lock
  exit "$status"
}
trap teardown_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fm_lock_acquire_wait "$TEARDOWN_LOCK"
TEARDOWN_LOCKED=1
fm_backend_adopt_legacy_tmux_meta "$META" "fm-$ID" >/dev/null 2>&1 || true
COMPLETION_PROOF="$STATE/$ID.teardown-complete"
TEARDOWN_STAGE="$STATE/$ID.teardown-stage"
AUX_OWNERS="$STATE/$ID.teardown-owners"
BACKLOG_MUTATION_INTENT="$STATE/$ID.backlog-mutation-intent"
FINAL_CLEANUP="$STATE/$ID.teardown-final-cleanup"

final_cleanup_schema_valid() {
  awk -F= -v id="$ID" '
    $1 == "version" { versions++; version = $2 }
    $1 == "task" { tasks++; task = $2 }
    $1 == "meta-cksum" { metas++; meta = $2 }
    $1 == "stage-cksum" { stages++; stage = $2 }
    $1 == "done-ack" { acks++; ack = $2 }
    $1 == "force" { forces++; force = $2 }
    { lines++ }
    END {
      exit !(versions == 1 && version == "1" && tasks == 1 && task == id \
        && metas == 1 && meta ~ /^[0-9]+:[0-9]+$/ \
        && stages == 1 && stage ~ /^[0-9]+:[0-9]+$/ \
        && acks == 1 && ack ~ /^[0-9a-f]{32}$/ \
        && forces == 1 && force ~ /^[01]$/ && lines == 6)
    }
  ' "$FINAL_CLEANUP"
}

final_cleanup_value() {
  sed -n "s/^$1=//p" "$FINAL_CLEANUP" | tail -1
}

remove_final_state_paths() {
  local path
  for path in \
    "$STATE/$ID.status" \
    "$STATE/$ID.turn-ended" \
    "$STATE/$ID.check.sh" \
    "$STATE/$ID.pi-ext.ts" \
    "$STATE/$ID.grok-turnend-token" \
    "$STATE/$ID.tearing-down" \
    "$STATE/$ID.spawning" \
    "$COMPLETION_PROOF" \
    "$BACKLOG_MUTATION_INTENT" \
    "$AUX_OWNERS" \
    "$TEARDOWN_STAGE" \
    "$META"; do
    rm -f "$path" || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  done
}

finish_final_state_cleanup() {
  remove_final_state_paths || {
    echo "REFUSED: final lifecycle files for $ID were only partially removed; preserving $FINAL_CLEANUP for retry." >&2
    return 1
  }
  rm -f "$FINAL_CLEANUP" || {
    echo "REFUSED: final lifecycle files for $ID are absent, but retry authority could not be consumed." >&2
    return 1
  }
  [ ! -e "$FINAL_CLEANUP" ] && [ ! -L "$FINAL_CLEANUP" ] || {
    echo "REFUSED: final lifecycle cleanup authority remains for $ID." >&2
    return 1
  }
}

prepare_final_state_cleanup() {
  local marker_tmp meta_cksum stage_cksum done_ack stage_force
  [ ! -e "$FINAL_CLEANUP" ] && [ ! -L "$FINAL_CLEANUP" ] || return 1
  [ -f "$META" ] && [ ! -L "$META" ] \
    && [ -f "$TEARDOWN_STAGE" ] && [ ! -L "$TEARDOWN_STAGE" ] \
    && grep -q '^phase=backlog-recorded$' "$TEARDOWN_STAGE" || return 1
  meta_cksum=$(cksum < "$META" | awk '{print $1 ":" $2}') || return 1
  stage_cksum=$(cksum < "$TEARDOWN_STAGE" | awk '{print $1 ":" $2}') || return 1
  done_ack=$(sed -n 's/^done-ack=//p' "$TEARDOWN_STAGE" | tail -1)
  stage_force=$(sed -n 's/^force=//p' "$TEARDOWN_STAGE" | tail -1)
  [[ "$done_ack" =~ ^[0-9a-f]{32}$ ]] || return 1
  case "$stage_force" in 0|1) ;; *) return 1 ;; esac
  marker_tmp=$(mktemp "$STATE/.$ID.teardown-final-cleanup.tmp.XXXXXXXX") || return 1
  if ! {
    printf 'version=1\n'
    printf 'task=%s\n' "$ID"
    printf 'meta-cksum=%s\n' "$meta_cksum"
    printf 'stage-cksum=%s\n' "$stage_cksum"
    printf 'done-ack=%s\n' "$done_ack"
    printf 'force=%s\n' "$stage_force"
  } > "$marker_tmp" || ! mv "$marker_tmp" "$FINAL_CLEANUP"; then
    rm -f "$marker_tmp" 2>/dev/null || true
    return 1
  fi
}

if [ -e "$FINAL_CLEANUP" ] || [ -L "$FINAL_CLEANUP" ]; then
  if [ ! -f "$FINAL_CLEANUP" ] || [ -L "$FINAL_CLEANUP" ] || ! final_cleanup_schema_valid; then
    echo "REFUSED: invalid final lifecycle cleanup authority at $FINAL_CLEANUP." >&2
    exit 1
  fi
  if [ "$REQUESTED_FORCE" = --force ] && [ "$(final_cleanup_value force)" != 1 ]; then
    echo "REFUSED: cannot change teardown force posture after cleanup completed for $ID." >&2
    exit 1
  fi
  if [ -e "$META" ] || [ -L "$META" ]; then
    [ -f "$META" ] && [ ! -L "$META" ] \
      && [ "$(cksum < "$META" | awk '{print $1 ":" $2}')" = "$(final_cleanup_value meta-cksum)" ] || {
      echo "REFUSED: final lifecycle cleanup authority no longer matches task metadata for $ID." >&2
      exit 1
    }
  fi
  if [ -e "$TEARDOWN_STAGE" ] || [ -L "$TEARDOWN_STAGE" ]; then
    [ -f "$TEARDOWN_STAGE" ] && [ ! -L "$TEARDOWN_STAGE" ] \
      && [ "$(cksum < "$TEARDOWN_STAGE" | awk '{print $1 ":" $2}')" = "$(final_cleanup_value stage-cksum)" ] \
      && grep -q '^phase=backlog-recorded$' "$TEARDOWN_STAGE" || {
      echo "REFUSED: final lifecycle cleanup authority no longer matches the completed teardown stage for $ID." >&2
      exit 1
    }
  fi
  finish_final_state_cleanup || exit 1
  echo "teardown $ID final lifecycle cleanup resumed and completed"
  exit 0
fi

[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no regular meta for task $ID at $META" >&2; exit 1; }
META_CKSUM=$(cksum < "$META" | awk '{print $1 ":" $2}') || exit 1
KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
teardown_metadata_context_valid() {
  case "$KIND:$MODE" in
    ship:no-mistakes|ship:direct-PR|ship:local-only) return 0 ;;
    scout:no-mistakes|scout:direct-PR|scout:local-only) return 0 ;;
    secondmate:secondmate) return 0 ;;
  esac
  return 1
}
if ! teardown_metadata_context_valid; then
  echo "REFUSED: invalid teardown metadata context kind=$KIND mode=$MODE; preserving lifecycle state." >&2
  exit 1
fi
RESUMING_STAGE=0
STAGE_PHASE=
STAGE_OWNER_IDENTITY=
STAGE_OWNER_MARKER=
STAGE_OWNER_TOKEN=
STAGE_OUTCOME=
STAGE_RECORD_CKSUM=
STAGE_FORCE=
STAGE_AUX_CKSUM=
STAGE_DONE_ACK=
stage_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$TEARDOWN_STAGE" | tail -1
}
teardown_stage_schema_valid() {
  awk -F= '
    $1 == "version" { versions++; version = substr($0, index($0, "=") + 1) }
    $1 == "task" { tasks++; task = substr($0, index($0, "=") + 1) }
    $1 == "meta-cksum" { metas++; meta = substr($0, index($0, "=") + 1) }
    $1 == "phase" { phases++; phase = substr($0, index($0, "=") + 1) }
    $1 == "owner-identity" { identities++; identity = substr($0, index($0, "=") + 1) }
    $1 == "owner-marker" { markers++; marker = substr($0, index($0, "=") + 1) }
    $1 == "owner-token" { tokens++; token = substr($0, index($0, "=") + 1) }
    $1 == "force" { forces++; force = substr($0, index($0, "=") + 1) }
    $1 == "outcome" { outcomes++; outcome = substr($0, index($0, "=") + 1) }
    $1 == "record-cksum" { records++; record = substr($0, index($0, "=") + 1) }
    $1 == "aux-cksum" { auxes++; aux = substr($0, index($0, "=") + 1) }
    $1 == "done-ack" { acks++; ack = substr($0, index($0, "=") + 1) }
    { lines++ }
    END {
      exit !(versions == 1 && version == "4" && tasks == 1 && task != "" \
        && metas == 1 && meta != "" && phases == 1 && phase != "" \
        && identities == 1 && identity != "" && markers == 1 && marker != "" \
        && tokens == 1 && token != "" && forces == 1 && force ~ /^[01]$/ \
        && outcomes == 1 && outcome != "" && records == 1 && record != "" \
        && auxes == 1 && aux != "" && acks == 1 \
        && ack ~ /^[0-9a-f]+$/ && length(ack) == 32 && lines == 12)
    }
  ' "$TEARDOWN_STAGE"
}
orphan_auxiliary_manifest_recoverable() {
  local kind target identity marker token
  [ -f "$AUX_OWNERS" ] && [ ! -L "$AUX_OWNERS" ] || return 1
  awk -F '\t' '
    NF != 5 { bad = 1 }
    $1 == "" || $2 == "" || $3 == "" || $4 == "" { bad = 1 }
    $5 !~ /^[0-9a-f]+$/ || length($5) != 32 { bad = 1 }
    END { exit bad }
  ' "$AUX_OWNERS" || return 1
  while IFS=$'\t' read -r kind target identity marker token; do
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  done < "$AUX_OWNERS"
}
if [ -e "$TEARDOWN_STAGE" ] || [ -L "$TEARDOWN_STAGE" ]; then
  if [ ! -f "$TEARDOWN_STAGE" ] || [ -L "$TEARDOWN_STAGE" ] \
     || ! teardown_stage_schema_valid \
     || [ "$(stage_value version)" != 4 ] \
     || [ "$(stage_value task)" != "$ID" ] \
     || [ "$(stage_value meta-cksum)" != "$META_CKSUM" ]; then
    echo "REFUSED: invalid or stale teardown stage at $TEARDOWN_STAGE; preserving lifecycle state." >&2
    exit 1
  fi
  STAGE_PHASE=$(stage_value phase)
  case "$STAGE_PHASE" in
    preparing|prepared|endpoint-closed|worktree-cleanup-started|worktree-cleaned|finalizing|backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded|ownership-lost) ;;
    *) echo "REFUSED: invalid teardown phase in $TEARDOWN_STAGE; preserving lifecycle state." >&2; exit 1 ;;
  esac
  STAGE_OWNER_IDENTITY=$(stage_value owner-identity)
  STAGE_OWNER_MARKER=$(stage_value owner-marker)
  STAGE_OWNER_TOKEN=$(stage_value owner-token)
  STAGE_OUTCOME=$(stage_value outcome)
  STAGE_RECORD_CKSUM=$(stage_value record-cksum)
  STAGE_FORCE=$(stage_value force)
  STAGE_AUX_CKSUM=$(stage_value aux-cksum)
  STAGE_DONE_ACK=$(stage_value done-ack)
  [ -n "$STAGE_OWNER_IDENTITY" ] && [ -n "$STAGE_OWNER_MARKER" ] \
    && [ -n "$STAGE_OWNER_TOKEN" ] && [ -n "$STAGE_OUTCOME" ] \
    && [ -n "$STAGE_RECORD_CKSUM" ] && [ -n "$STAGE_AUX_CKSUM" ] \
    && [[ "$STAGE_DONE_ACK" =~ ^[0-9a-f]{32}$ ]] || {
    echo "REFUSED: incomplete teardown stage at $TEARDOWN_STAGE; preserving lifecycle state." >&2
    exit 1
  }
  case "$STAGE_FORCE" in
    0|1) ;;
    *) echo "REFUSED: invalid teardown force posture in $TEARDOWN_STAGE; preserving lifecycle state." >&2; exit 1 ;;
  esac
  if [ -L "$AUX_OWNERS" ] || [ ! -f "$AUX_OWNERS" ] \
     || [ "$(cksum < "$AUX_OWNERS" | awk '{print $1 ":" $2}')" != "$STAGE_AUX_CKSUM" ]; then
    echo "REFUSED: invalid or stale auxiliary teardown ownership at $AUX_OWNERS; preserving lifecycle state." >&2
    exit 1
  fi
  if [ "$STAGE_FORCE" = 1 ]; then
    FORCE=--force
  fi
  RESUMING_STAGE=1
elif [ -e "$AUX_OWNERS" ] || [ -L "$AUX_OWNERS" ]; then
  if orphan_auxiliary_manifest_recoverable; then
    rm -f "$AUX_OWNERS" || {
      echo "REFUSED: could not clear unclaimed auxiliary teardown plan at $AUX_OWNERS." >&2
      exit 1
    }
  else
    echo "REFUSED: auxiliary teardown ownership exists without its stage at $AUX_OWNERS; preserving it for reconciliation." >&2
    exit 1
  fi
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
  tmux|herdr|zellij|orca|cmux)
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
ORCA_WORKTREE_STATE=

teardown_outcome_valid() {
  local kind=$1 mode=$2 force=$3 outcome=$4
  case "$kind:$force:$outcome" in
    secondmate:0:not-applicable|secondmate:1:not-applicable) return 0 ;;
    scout:0:delivered-report|scout:1:discarded) return 0 ;;
    ship:0:unlanded|ship:1:discarded) return 0 ;;
    ship:0:delivered-local) [ "$mode" = local-only ] && return 0 ;;
    ship:0:delivered-pr|ship:0:delivered-default)
      case "$mode" in no-mistakes|direct-PR) return 0 ;; esac
      ;;
  esac
  return 1
}
if [ "$RESUMING_STAGE" -eq 1 ] \
   && ! teardown_outcome_valid "$KIND" "$MODE" "$STAGE_FORCE" "$STAGE_OUTCOME"; then
  echo "REFUSED: invalid teardown outcome for $KIND/$MODE with force=$STAGE_FORCE in $TEARDOWN_STAGE; preserving lifecycle state." >&2
  exit 1
fi
STAGE_OUTCOME_DELIVERED=0
case "$STAGE_OUTCOME" in
  delivered-report|delivered-local|delivered-pr|delivered-default) STAGE_OUTCOME_DELIVERED=1 ;;
esac
BACKLOG_TRACKED=0
BACKLOG_RECORD_CKSUM=
if [ "$KIND" = secondmate ]; then
  BACKLOG_TRACKED=0
elif BACKLOG_LOOKUP=$("$SCRIPT_DIR/fm-backlog.sh" show "$ID" --full 2>&1); then
  BACKLOG_TRACKED=1
  if [ "$RESUMING_STAGE" -eq 1 ] \
     && { [ "$STAGE_PHASE" = backlog-done-started ] \
       || { [ "$STAGE_PHASE" = backlog-recorded ] \
         && [ "$STAGE_OUTCOME_DELIVERED" -eq 1 ]; }; }; then
    BACKLOG_RECORD_CKSUM=$STAGE_RECORD_CKSUM
  else
    BACKLOG_RECORD_CKSUM=$(printf '%s' "$BACKLOG_LOOKUP" | fm_tasks_axi_task_fingerprint) || {
      echo "REFUSED: backlog backend returned no stable task record for $ID." >&2
      exit 1
    }
  fi
elif printf '%s\n' "$BACKLOG_LOOKUP" | grep -q 'code:[[:space:]]*NOT_FOUND'; then
  if [ "$RESUMING_STAGE" -eq 1 ] \
     && { [ "$STAGE_PHASE" = backlog-done-started ] \
       || { [ "$STAGE_PHASE" = backlog-recorded ] \
         && [ "$STAGE_OUTCOME_DELIVERED" -eq 1 ]; }; } \
     && [ "$STAGE_RECORD_CKSUM" != none ]; then
    BACKLOG_TRACKED=1
    BACKLOG_RECORD_CKSUM=$STAGE_RECORD_CKSUM
  else
    BACKLOG_TRACKED=0
  fi
else
  echo "REFUSED: could not determine whether backlog task $ID exists." >&2
  [ -z "$BACKLOG_LOOKUP" ] || printf '%s\n' "$BACKLOG_LOOKUP" >&2
  echo "Repair the selected home's backlog/configuration and retry; teardown will preserve lifecycle state." >&2
  exit 1
fi
if [ "$RESUMING_STAGE" -eq 1 ] \
   && [ "$STAGE_PHASE" != backlog-hold-started ] \
   && [ "$STAGE_PHASE" != backlog-reopen-started ] \
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
  local action=${1:-delivery} report_path reason
  [ "$KIND" = secondmate ] && return 0
  if [ "$BACKLOG_TRACKED" -ne 1 ]; then
    printf '%s\n' "Backlog: $ID was not present in this home's backlog before teardown; no completion mutation was attempted. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
    return 0
  fi
  case "$DELIVERY_OUTCOME" in
      delivered-report)
        [ "$action" = delivery ] || return 1
        report_path="data/$ID/report.md"
        if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --report "$report_path" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done with $report_path after successful teardown. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for scout $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      delivered-local)
        [ "$action" = delivery ] || return 1
        if "$SCRIPT_DIR/fm-backlog.sh" "done" "$ID" --note "local main" >/dev/null; then
          printf '%s\n' "Backlog: $ID recorded Done with local main after successful teardown. Run bin/fm-backlog.sh ready, check date gates, and dispatch only work whose blockers are gone and date is due."
        else
          echo "error: teardown completed, but serialized backlog completion failed for $ID; it remains outside Done" >&2
          return 1
        fi
        ;;
      delivered-pr)
        [ "$action" = delivery ] || return 1
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
        [ "$action" = delivery ] || return 1
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
        case "$action" in
          hold)
            "$SCRIPT_DIR/fm-backlog.sh" hold "$ID" --reason "$reason" --kind parked >/dev/null || {
              echo "error: teardown completed, but truthful $DELIVERY_OUTCOME hold recording failed for $ID" >&2
              return 1
            }
            ;;
          reopen)
            "$SCRIPT_DIR/fm-backlog.sh" reopen "$ID" >/dev/null || {
              echo "error: teardown completed, but truthful $DELIVERY_OUTCOME reopen failed for $ID" >&2
              return 1
            }
            printf '%s\n' "Backlog: $ID remains outside Done with a structured $DELIVERY_OUTCOME hold after teardown."
            ;;
          *) return 1 ;;
        esac
        ;;
  esac
}

revalidate_backlog_record_binding() {
  local current current_cksum
  [ "$BACKLOG_TRACKED" -eq 1 ] || return 0
  current=$("$SCRIPT_DIR/fm-backlog.sh" show "$ID" --full 2>&1) || {
    echo "REFUSED: could not re-read backlog task $ID before finalization." >&2
    return 1
  }
  current_cksum=$(printf '%s' "$current" | fm_tasks_axi_task_fingerprint) || return 1
  [ "$current_cksum" = "$STAGE_RECORD_CKSUM" ] || {
    echo "REFUSED: backlog task $ID changed before finalization; preserving lifecycle state." >&2
    return 1
  }
}

expected_backlog_mutation_cksum() {
  local action=$1 record=$2 reason=${3:-} transformed
  transformed=$(printf '%s\n' "$record" | awk -v action="$action" -v reason="$reason" '
    /^  state:/ {
      states++
      if (action == "reopen") print "  state: queued"
      else print
      next
    }
    /^  closed:/ {
      closed++
      if (action == "reopen") print "  closed: -"
      else print
      next
    }
    /^  held:/ {
      held++
      if (action == "hold") print "  held: yes"
      else print
      next
    }
    /^  hold_reason:/ {
      hold_reasons++
      if (action == "hold") print "  hold_reason: " reason
      else print
      next
    }
    /^  hold_kind:/ {
      hold_kinds++
      if (action == "hold") print "  hold_kind: parked"
      else print
      next
    }
    /^  hold_until:/ {
      hold_untils++
      if (action == "hold") print "  hold_until: -"
      else print
      next
    }
    { print }
    END {
      if (states != 1 || closed != 1 || held != 1 || hold_reasons != 1 \
          || hold_kinds != 1 || hold_untils != 1) exit 1
    }
  ') || return 1
  printf '%s' "$transformed" | fm_tasks_axi_task_fingerprint
}

write_backlog_mutation_intent() {
  local action=$1 pre_cksum=$2 post_cksum=$3 tmp
  tmp=$(mktemp "$STATE/.$ID.backlog-mutation-intent.tmp.XXXXXXXX") || return 1
  if ! {
    printf 'version=1\n'
    printf 'task=%s\n' "$ID"
    printf 'action=%s\n' "$action"
    printf 'pre-cksum=%s\n' "$pre_cksum"
    printf 'post-cksum=%s\n' "$post_cksum"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_publish_file_no_follow "$tmp" "$BACKLOG_MUTATION_INTENT" replace; then
    rm -f "$tmp"
    return 1
  fi
}

backlog_mutation_intent_matches() {
  local action=$1 pre_cksum=$2 post_cksum
  [ -f "$BACKLOG_MUTATION_INTENT" ] && [ ! -L "$BACKLOG_MUTATION_INTENT" ] || return 1
  awk -F= -v id="$ID" -v action="$action" -v pre="$pre_cksum" '
    $1 == "version" { versions++; version = substr($0, index($0, "=") + 1) }
    $1 == "task" { tasks++; task = substr($0, index($0, "=") + 1) }
    $1 == "action" { actions++; got_action = substr($0, index($0, "=") + 1) }
    $1 == "pre-cksum" { pres++; got_pre = substr($0, index($0, "=") + 1) }
    $1 == "post-cksum" { posts++; post = substr($0, index($0, "=") + 1) }
    { lines++ }
    END {
      exit !(versions == 1 && version == "1" && tasks == 1 && task == id \
        && actions == 1 && got_action == action && pres == 1 && got_pre == pre \
        && posts == 1 && post != "" && lines == 5)
    }
  ' "$BACKLOG_MUTATION_INTENT" || return 1
  post_cksum=$(sed -n 's/^post-cksum=//p' "$BACKLOG_MUTATION_INTENT")
  [ "$post_cksum" = "$BACKLOG_CURRENT_CKSUM" ] || return 1
  BACKLOG_MUTATION_EXPECTED_CKSUM=$post_cksum
}

read_current_backlog_record() {
  BACKLOG_CURRENT_RECORD=$("$SCRIPT_DIR/fm-backlog.sh" show "$ID" --full 2>&1) || {
    echo "REFUSED: could not read backlog task $ID during truthful finalization." >&2
    return 1
  }
  BACKLOG_CURRENT_CKSUM=$(printf '%s' "$BACKLOG_CURRENT_RECORD" | fm_tasks_axi_task_fingerprint) || return 1
}

prepare_backlog_mutation() {
  local action=$1 reason=${2:-}
  BACKLOG_MUTATION_ALREADY_APPLIED=0
  read_current_backlog_record || return 1
  if [ "$BACKLOG_CURRENT_CKSUM" = "$STAGE_RECORD_CKSUM" ]; then
    BACKLOG_MUTATION_EXPECTED_CKSUM=$(expected_backlog_mutation_cksum "$action" "$BACKLOG_CURRENT_RECORD" "$reason") || return 1
    write_backlog_mutation_intent "$action" "$STAGE_RECORD_CKSUM" "$BACKLOG_MUTATION_EXPECTED_CKSUM" || return 1
    return 0
  fi
  if backlog_mutation_intent_matches "$action" "$STAGE_RECORD_CKSUM"; then
    BACKLOG_MUTATION_ALREADY_APPLIED=1
    return 0
  fi
  echo "REFUSED: backlog task $ID changed during the staged $action transition; preserving lifecycle state." >&2
  return 1
}

verify_backlog_mutation_result() {
  read_current_backlog_record || return 1
  [ "$BACKLOG_CURRENT_CKSUM" = "$BACKLOG_MUTATION_EXPECTED_CKSUM" ] || {
    echo "REFUSED: staged backlog mutation for $ID did not produce its exact expected record; preserving lifecycle state." >&2
    return 1
  }
  BACKLOG_RECORD_CKSUM=$BACKLOG_CURRENT_CKSUM
}

write_completion_proof() {
  local tmp
  [ "$BACKLOG_TRACKED" -eq 1 ] || return 0
  case "$DELIVERY_OUTCOME" in
    delivered-report|delivered-local|delivered-pr|delivered-default) ;;
    *) return 0 ;;
  esac
  tmp=$(mktemp "$STATE/.$ID.teardown-complete.tmp.XXXXXXXX") || return 1
  if ! {
    printf 'version=2\n'
    printf 'task=%s\n' "$ID"
    printf 'kind=%s\n' "$KIND"
    printf 'outcome=%s\n' "$DELIVERY_OUTCOME"
    printf 'record-cksum=%s\n' "$BACKLOG_RECORD_CKSUM"
    printf 'done-ack=%s\n' "$STAGE_DONE_ACK"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [ -e "$COMPLETION_PROOF" ] || [ -L "$COMPLETION_PROOF" ]; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_publish_file_no_follow "$tmp" "$COMPLETION_PROOF" exclusive; then
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
  [ "$(sed -n 's/^version=//p' "$COMPLETION_PROOF" | tail -1)" = 2 ] \
    && [ "$(sed -n 's/^task=//p' "$COMPLETION_PROOF" | tail -1)" = "$ID" ] \
    && [ "$(sed -n 's/^kind=//p' "$COMPLETION_PROOF" | tail -1)" = "$KIND" ] \
    && [ "$(sed -n 's/^outcome=//p' "$COMPLETION_PROOF" | tail -1)" = "$DELIVERY_OUTCOME" ] \
    && [ "$(sed -n 's/^record-cksum=//p' "$COMPLETION_PROOF" | tail -1)" = "$BACKLOG_RECORD_CKSUM" ] \
    && [ "$(sed -n 's/^done-ack=//p' "$COMPLETION_PROOF" | tail -1)" = "$STAGE_DONE_ACK" ]
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

teardown_owner_marker_path() {
  local owner owner_abs git_dir git_top marker_dir
  owner=$(teardown_owner_path)
  [ -n "$owner" ] && [ -d "$owner" ] || return 1
  owner_abs=$(cd "$owner" 2>/dev/null && pwd -P) || return 1
  git_dir=$(git -C "$owner" rev-parse --absolute-git-dir 2>/dev/null || true)
  git_top=$(git -C "$owner" rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$git_top" ] || git_top=$(cd "$git_top" 2>/dev/null && pwd -P) || return 1
  if [ -n "$git_dir" ] && [ "$git_top" = "$owner_abs" ]; then
    marker_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || return 1
  elif [ "$KIND" = secondmate ] && [ -d "$owner/state" ]; then
    marker_dir=$(cd "$owner/state" 2>/dev/null && pwd -P) || return 1
  else
    return 1
  fi
  printf '%s/.fm-teardown-owner-%s\n' "$marker_dir" "$ID"
}

new_teardown_owner_token() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
  case "$token" in
    ????????????????????????????????) printf '%s\n' "$token" ;;
    *) return 1 ;;
  esac
}

auxiliary_target_canonical() {
  local target=$1 canonical
  [ -n "$target" ] && [ -d "$target" ] && [ ! -L "$target" ] || return 1
  canonical=$(cd -P "$target" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$canonical"
}

auxiliary_target_identity() {
  local target=$1 canonical inode path_cksum
  canonical=$(auxiliary_target_canonical "$target") || return 1
  inode=$(stat -f '%d:%i' "$canonical" 2>/dev/null \
    || stat -c '%d:%i' "$canonical" 2>/dev/null) || return 1
  path_cksum=$(printf '%s' "$canonical" | cksum | awk '{print $1 ":" $2}') || return 1
  printf '%s:%s\n' "$inode" "$path_cksum"
}

append_auxiliary_owner() {
  local kind=$1 target=$2 manifest=$3 index=$4 canonical identity marker token
  [ -d "$target" ] || return 0
  canonical=$(auxiliary_target_canonical "$target") || return 1
  case "$canonical" in *$'\t'*|*$'\n'*) return 1 ;; esac
  identity=$(auxiliary_target_identity "$canonical") || return 1
  marker="$canonical/.fm-teardown-owner-$ID-$index"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  token=$(new_teardown_owner_token) || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$canonical" "$identity" "$marker" "$token" >> "$manifest"
}

collect_child_auxiliary_owners() {
  local home=$1 manifest=$2 child_meta child_kind child_wt child_home index
  [ -d "$home/state" ] || return 0
  for child_meta in "$home/state"/*.meta; do
    [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
    child_meta_is_regular "$child_meta" || return 1
    child_kind=$(fm_meta_get "$child_meta" kind)
    child_wt=$(fm_meta_get "$child_meta" worktree)
    if [ "$child_kind" = secondmate ]; then
      child_home=$(fm_meta_get "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -d "$child_home" ]; then
        index=$(awk 'END { print NR + 1 }' "$manifest")
        append_auxiliary_owner child-home "$child_home" "$manifest" "$index" || return 1
        collect_child_auxiliary_owners "$child_home" "$manifest" || return 1
      fi
    elif [ -d "$child_wt" ]; then
      index=$(awk 'END { print NR + 1 }' "$manifest")
      append_auxiliary_owner child-worktree "$child_wt" "$manifest" "$index" || return 1
    fi
  done
}

child_meta_is_regular() {
  local child_meta=$1
  if [ -L "$child_meta" ] || [ ! -f "$child_meta" ]; then
    echo "REFUSED: child task metadata is symlinked or non-regular: $child_meta" >&2
    return 1
  fi
}

prepare_auxiliary_owners() {
  local tmp index
  tmp=$(mktemp "$STATE/.$ID.teardown-owners.tmp.XXXXXXXX") || return 1
  : > "$tmp" || return 1
  if [ "$KIND" = secondmate ] && [ "$FORCE" = --force ]; then
    collect_child_auxiliary_owners "$HOME_PATH" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  if [ -n "$TASK_TMP" ] && [ -d "$TASK_TMP" ]; then
    index=$(awk 'END { print NR + 1 }' "$tmp")
    append_auxiliary_owner tasktmp "$TASK_TMP" "$tmp" "$index" || {
      rm -f "$tmp"
      return 1
    }
  fi
  if ! fm_publish_file_no_follow "$tmp" "$AUX_OWNERS" replace; then
    rm -f "$tmp"
    return 1
  fi
  STAGE_AUX_CKSUM=$(cksum < "$AUX_OWNERS" | awk '{print $1 ":" $2}') || {
    rm -f "$AUX_OWNERS"
    return 1
  }
}

ensure_owned_marker() {
  local marker=$1 token=$2 old_umask
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] \
      && [ "$(cat "$marker" 2>/dev/null)" = "$token" ]
    return
  fi
  old_umask=$(umask)
  umask 077
  if ! ( set -C; printf '%s\n' "$token" > "$marker" ) 2>/dev/null; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

ensure_auxiliary_owner_markers() {
  local kind target identity marker token current
  while IFS=$'\t' read -r kind target identity marker token; do
    [ -n "$kind" ] && [ -n "$target" ] && [ -n "$identity" ] \
      && [ -n "$marker" ] && [ -n "$token" ] || return 1
    current=$(auxiliary_target_identity "$target") || return 1
    [ "$current" = "$identity" ] || return 1
    ensure_owned_marker "$marker" "$token" || return 1
  done < "$AUX_OWNERS"
}

remove_auxiliary_markers_from() {
  local manifest=$1 kind target identity marker token
  [ -f "$manifest" ] || return 0
  while IFS=$'\t' read -r kind target identity marker token; do
    [ -n "$marker" ] && [ -n "$token" ] || return 1
    if [ -f "$marker" ] && [ ! -L "$marker" ] \
       && [ "$(cat "$marker" 2>/dev/null)" = "$token" ]; then
      rm -f "$marker" || return 1
    fi
  done < "$manifest"
}

validate_auxiliary_owners() {
  local allow_absent=${1:-0} kind target identity marker token current
  [ -f "$AUX_OWNERS" ] && [ ! -L "$AUX_OWNERS" ] || return 1
  while IFS=$'\t' read -r kind target identity marker token; do
    [ -n "$kind" ] && [ -n "$target" ] && [ -n "$identity" ] \
      && [ -n "$marker" ] && [ -n "$token" ] || return 1
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      [ "$allow_absent" -eq 1 ] || return 1
      continue
    fi
    [ -d "$target" ] && [ ! -L "$target" ] || return 1
    current=$(auxiliary_target_identity "$target") || return 1
    [ "$current" = "$identity" ] || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] \
      && [ "$(cat "$marker" 2>/dev/null)" = "$token" ] || return 1
  done < "$AUX_OWNERS"
}

auxiliary_owner_matches_target() {
  local wanted=$1 canonical kind target identity marker token current found=0
  canonical=$(auxiliary_target_canonical "$wanted") || return 1
  while IFS=$'\t' read -r kind target identity marker token; do
    [ "$target" = "$canonical" ] || continue
    found=$((found + 1))
    [ -d "$target" ] || return 1
    current=$(auxiliary_target_identity "$target") || return 1
    [ "$current" = "$identity" ] || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] \
      && [ "$(cat "$marker" 2>/dev/null)" = "$token" ] || return 1
  done < "$AUX_OWNERS"
  [ "$found" -eq 1 ]
}

plan_teardown_owner_marker() {
  local marker token
  marker=$(teardown_owner_marker_path) || return 1
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  token=$(new_teardown_owner_token) || return 1
  STAGE_OWNER_MARKER=$marker
  STAGE_OWNER_TOKEN=$token
}

create_teardown_owner_marker() {
  [ "$STAGE_OWNER_MARKER" != none ] || return 0
  ensure_owned_marker "$STAGE_OWNER_MARKER" "$STAGE_OWNER_TOKEN"
}

remove_teardown_owner_marker() {
  [ "$STAGE_OWNER_MARKER" != none ] || return 0
  [ -n "$STAGE_OWNER_MARKER" ] || return 1
  if [ -f "$STAGE_OWNER_MARKER" ] && [ ! -L "$STAGE_OWNER_MARKER" ] \
     && [ "$(cat "$STAGE_OWNER_MARKER" 2>/dev/null)" = "$STAGE_OWNER_TOKEN" ]; then
    rm -f "$STAGE_OWNER_MARKER"
    return
  fi
  [ ! -e "$STAGE_OWNER_MARKER" ] && [ ! -L "$STAGE_OWNER_MARKER" ]
}

write_teardown_stage() {
  local phase=$1 owner_identity=$2 tmp
  tmp=$(mktemp "$STATE/.$ID.teardown-stage.tmp.XXXXXXXX") || return 1
  if ! {
    printf 'version=4\n'
    printf 'task=%s\n' "$ID"
    printf 'meta-cksum=%s\n' "$META_CKSUM"
    printf 'phase=%s\n' "$phase"
    printf 'owner-identity=%s\n' "$owner_identity"
    printf 'owner-marker=%s\n' "$STAGE_OWNER_MARKER"
    printf 'owner-token=%s\n' "$STAGE_OWNER_TOKEN"
    printf 'force=%s\n' "$STAGE_FORCE"
    printf 'outcome=%s\n' "$DELIVERY_OUTCOME"
    printf 'record-cksum=%s\n' "${BACKLOG_RECORD_CKSUM:-none}"
    printf 'aux-cksum=%s\n' "$STAGE_AUX_CKSUM"
    printf 'done-ack=%s\n' "$STAGE_DONE_ACK"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_publish_file_no_follow "$tmp" "$TEARDOWN_STAGE" replace; then
    rm -f "$tmp"
    return 1
  fi
  [ -f "$TEARDOWN_STAGE" ] && [ ! -L "$TEARDOWN_STAGE" ]
}

owner_identity_matches() {
  local expected=${1:-$STAGE_OWNER_IDENTITY} current owner marker
  if [ "$expected" = absent ]; then
    owner=$(teardown_owner_path)
    [ "$STAGE_OWNER_MARKER" = none ] && [ "$STAGE_OWNER_TOKEN" = none ] || return 1
    [ -z "$owner" ] || { [ ! -e "$owner" ] && [ ! -L "$owner" ]; }
    return
  fi
  marker=$(teardown_owner_marker_path) || return 1
  [ "$marker" = "$STAGE_OWNER_MARKER" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(cat "$marker" 2>/dev/null)" = "$STAGE_OWNER_TOKEN" ] || return 1
  current=$(teardown_owner_identity) || return 1
  [ "$current" = "$expected" ]
}

preparing_owner_identity_matches() {
  local expected=${1:-$STAGE_OWNER_IDENTITY} current owner marker
  if [ "$expected" = absent ]; then
    owner=$(teardown_owner_path)
    [ "$STAGE_OWNER_MARKER" = none ] && [ "$STAGE_OWNER_TOKEN" = none ] || return 1
    [ -z "$owner" ] || { [ ! -e "$owner" ] && [ ! -L "$owner" ]; }
    return
  fi
  marker=$(teardown_owner_marker_path) || return 1
  [ "$marker" = "$STAGE_OWNER_MARKER" ] || return 1
  current=$(teardown_owner_identity) || return 1
  [ "$current" = "$expected" ]
}

complete_teardown_stage_preparation() {
  preparing_owner_identity_matches || return 1
  create_teardown_owner_marker || return 1
  ensure_auxiliary_owner_markers || return 1
  advance_teardown_stage prepared || return 1
}

prepare_teardown_stage() {
  local identity
  identity=$(teardown_owner_identity) || return 1
  if [ "$identity" = absent ]; then
    STAGE_OWNER_MARKER=none
    STAGE_OWNER_TOKEN=none
  else
    plan_teardown_owner_marker || return 1
  fi
  if ! prepare_auxiliary_owners; then
    return 1
  fi
  STAGE_OWNER_IDENTITY=$identity
  STAGE_OUTCOME=$DELIVERY_OUTCOME
  STAGE_RECORD_CKSUM=${BACKLOG_RECORD_CKSUM:-none}
  STAGE_DONE_ACK=$(new_teardown_owner_token) || {
    rm -f "$AUX_OWNERS"
    return 1
  }
  if ! write_teardown_stage preparing "$identity"; then
    rm -f "$AUX_OWNERS"
    return 1
  fi
  STAGE_PHASE=preparing
  complete_teardown_stage_preparation || return 1
  if ! ensure_completion_proof; then
    echo "REFUSED: could not persist completion proof for $ID; no endpoint or worktree cleanup was attempted." >&2
    return 1
  fi
}

advance_teardown_stage() {
  local phase=$1
  write_teardown_stage "$phase" "$STAGE_OWNER_IDENTITY" || return 1
  STAGE_PHASE=$phase
  STAGE_RECORD_CKSUM=${BACKLOG_RECORD_CKSUM:-none}
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

validate_teardown_stage_storage_external_to() {
  local target=$1 label=$2 abs_target abs_state
  [ -n "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target") || {
    echo "REFUSED: cannot canonicalize $label $target while validating teardown state storage." >&2
    return 1
  }
  abs_state=$(cd "$STATE" 2>/dev/null && pwd -P) || {
    echo "REFUSED: cannot canonicalize teardown state directory $STATE." >&2
    return 1
  }
  if [ "$abs_state" = "$abs_target" ] || path_is_ancestor_of "$abs_target" "$abs_state"; then
    echo "REFUSED: teardown state directory $abs_state is inside $label $abs_target." >&2
    echo "Move FM_STATE_OVERRIDE outside every cleanup target and retry." >&2
    return 1
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

worktree_absent_from_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -d "$project" ] || return 1
  abs_target=$(removal_target_abs_path "$target") || return 1
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" != "$abs_target" ] || return 1
        ;;
    esac
  done <<EOF
$listed
EOF
}

worktree_released_from_project() {
  worktree_absent_from_project "$1" "$2" \
    || fm_treehouse_worktree_available_for_project "$1" "$2"
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

endpoint_audit_clean_for_close() {
  local audit anomalies live reasons
  audit=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-endpoint-audit.sh" --json --task "$ID"
  ) || {
    echo "REFUSED: could not refresh the same-home endpoint audit immediately before closing $ID." >&2
    return 1
  }
  anomalies=$(printf '%s' "$audit" | jq -r --arg id "$ID" \
    '[.[] | select(.task == $id) | .kind] | unique | join(",")') || return 1
  [ -z "$anomalies" ] || {
    live=$(printf '%s' "$audit" | jq -r --arg id "$ID" \
      '[.[] | select(.task == $id) | .live_endpoints[]?] | unique | join(",")') || return 1
    reasons=$(printf '%s' "$audit" | jq -r --arg id "$ID" \
      '[.[] | select(.task == $id) | .reason // empty] | unique | join("; ")') || return 1
    echo "REFUSED: task $ID has a same-home endpoint ownership anomaly immediately before close: kind=$anomalies live=${live:-unknown} reason=${reasons:-unspecified}" >&2
    return 1
  }
}

close_endpoint_before_lifecycle_cleanup() {
  local attempt=0 endpoint_state close_attempted=0
  [ -n "$T" ] || {
    echo "REFUSED: task $ID has no exact recorded endpoint to close." >&2
    return 1
  }
  endpoint_audit_clean_for_close || return 1
  endpoint_state=$(fm_backend_target_state_of_meta "$META" "fm-$ID")
  case "$endpoint_state" in
    present)
      fm_backend_kill_owned_meta "$META" "fm-$ID" || {
        echo "REFUSED: failed to close exact endpoint $T for task $ID; preserving lifecycle state." >&2
        return 1
      }
      close_attempted=1
      ;;
    absent) ;;
    *)
      echo "REFUSED: endpoint state for $T is unknown; preserving lifecycle state for $ID." >&2
      return 1
      ;;
  esac
  while [ "$attempt" -lt 10 ]; do
    if [ "$close_attempted" -eq 1 ]; then
      endpoint_state=$(fm_backend_closed_target_state_of_meta "$META" "fm-$ID")
    else
      endpoint_state=$(fm_backend_target_state_of_meta "$META" "fm-$ID")
    fi
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

orca_worktree_probe() {
  local worktree_id=$1 out rc=0 path
  fm_backend_source orca || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json 2>&1) || rc=$?
  if printf '%s' "$out" | jq -e \
    '.ok == false and (.error.code == "worktree_not_found" or .error.code == "not_found")' \
    >/dev/null 2>&1; then
    printf 'absent\n'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "REFUSED: cannot determine whether Orca worktree id $worktree_id exists; preserving metadata." >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    return 1
  fi
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path 2>/dev/null) || {
    echo "REFUSED: Orca worktree id $worktree_id returned no verified path; preserving metadata." >&2
    return 1
  }
  printf 'present\t%s\n' "$path"
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 probe resolved inspected_abs resolved_abs
  probe=$(orca_worktree_probe "$worktree_id") || return 1
  case "$probe" in
    present$'\t'*) resolved=${probe#*$'\t'} ;;
    absent)
      echo "REFUSED: Orca worktree id $worktree_id is absent while inspected worktree ${inspected:-<missing>} still exists." >&2
      return 1
      ;;
    *) return 1 ;;
  esac
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

orca_worktree_identity_state() {
  local worktree_id=$1 inspected=$2 probe resolved
  if [ -n "$inspected" ] && { [ -e "$inspected" ] || [ -L "$inspected" ]; }; then
    require_orca_worktree_path_match "$worktree_id" "$inspected" || return 1
    printf 'present\n'
    return 0
  fi
  probe=$(orca_worktree_probe "$worktree_id") || return 1
  case "$probe" in
    absent) printf 'absent\n' ;;
    present$'\t'*)
      resolved=${probe#*$'\t'}
      echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved after recorded path ${inspected:-<missing>} disappeared." >&2
      echo "The recorded Orca id may have been reused; preserving metadata without removing it." >&2
      return 1
      ;;
    *) return 1 ;;
  esac
}

revalidate_owned_cleanup() {
  local safety_rc allow_aux_absent=0
  if ! owner_identity_matches; then
    echo "REFUSED: teardown cleanup-target identity no longer matches for $ID." >&2
    return 1
  fi
  case "$STAGE_PHASE" in
    worktree-cleanup-started|worktree-cleaned|finalizing|backlog-*) allow_aux_absent=1 ;;
  esac
  validate_auxiliary_owners "$allow_aux_absent" || {
    echo "REFUSED: an auxiliary cleanup target no longer has its staged ownership token for $ID." >&2
    return 1
  }

  if [ "$KIND" = secondmate ]; then
    validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || return 1
    if [ "$STAGE_OWNER_IDENTITY" = absent ]; then
      worktree_absent_from_project "$FM_ROOT" "$HOME_PATH" || {
        echo "REFUSED: absent secondmate home $HOME_PATH remains registered as a worktree; preserving lifecycle state." >&2
        return 1
      }
    fi
    if [ "$FORCE" = "--force" ]; then
      validate_firstmate_home_children_removal "$HOME_PATH" || return 1
    fi
    return 0
  fi

  if [ "$BACKEND" = orca ]; then
    ORCA_WORKTREE_STATE=$(orca_worktree_identity_state "$ORCA_WORKTREE_ID" "$WT") || return 1
    ORCA_PATH_MATCH_VERIFIED=1
  elif [ -d "$WT" ]; then
    if ! worktree_registered_for_project "$PROJ" "$WT" \
       && ! standalone_git_worktree "$WT"; then
      echo "REFUSED: recorded cleanup target $WT is neither the project worktree nor a standalone git checkout for $ID." >&2
      return 1
    fi
  elif ! worktree_absent_from_project "$PROJ" "$WT"; then
    echo "REFUSED: absent cleanup target $WT remains registered for $PROJ; preserving lifecycle state." >&2
    return 1
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
  if [ -L "$target" ]; then
    echo "REFUSED: unsafe child worktree removal target $target is a symlink" >&2
    return 1
  fi
  validate_teardown_stage_storage_external_to "$target" "child worktree" || return 1
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
  local target=$1 label=$2 post_cleanup_check=${3:-}
  validate_removal_target "$target" "$label" >/dev/null || return 1
  [ -z "$post_cleanup_check" ] || "$post_cleanup_check" || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  auxiliary_owner_matches_target "$target" || return 1
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

AUXILIARY_REVALIDATE_TARGET=
AUXILIARY_REVALIDATE_PROJECT=
AUXILIARY_REVALIDATE_LABEL=
AUXILIARY_REVALIDATE_ID=

revalidate_auxiliary_child_worktree_cleanup() {
  auxiliary_owner_matches_target "$AUXILIARY_REVALIDATE_TARGET" || return 1
  validate_child_worktree_for_removal \
    "$AUXILIARY_REVALIDATE_TARGET" "$AUXILIARY_REVALIDATE_PROJECT" >/dev/null
}

revalidate_auxiliary_firstmate_home_cleanup() {
  auxiliary_owner_matches_target "$AUXILIARY_REVALIDATE_TARGET" || return 1
  validate_firstmate_home_for_removal \
    "$AUXILIARY_REVALIDATE_TARGET" "$AUXILIARY_REVALIDATE_LABEL" \
    "$AUXILIARY_REVALIDATE_ID" >/dev/null
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  if [ -L "$home" ]; then
    echo "REFUSED: unsafe $label removal target $home is a symlink" >&2
    return 1
  fi
  validate_teardown_stage_storage_external_to "$home" "$label" || return 1
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
  local home=$1 label=$2 expected_id=${3:-} post_cleanup_check=${4:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "$post_cleanup_check" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label" "$post_cleanup_check"
}

validate_firstmate_home_lifecycle_accounting() {
  local home=$1 sub_state suffix artifact child_id child_meta owner
  sub_state="$home/state"
  if [ -e "$sub_state" ] || [ -L "$sub_state" ]; then
    [ -d "$sub_state" ] && [ ! -L "$sub_state" ] || {
      echo "REFUSED: secondmate state is symlinked or non-directory: $sub_state" >&2
      return 1
    }
  else
    return 0
  fi
  for suffix in spawning tearing-down teardown-stage teardown-final-cleanup backlog-mutation-intent teardown-owners; do
    for artifact in "$sub_state"/*.$suffix; do
      [ -e "$artifact" ] || [ -L "$artifact" ] || continue
      child_id=$(basename "$artifact" ".$suffix")
      child_meta="$sub_state/$child_id.meta"
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ]; then
        echo "REFUSED: secondmate home has unaccounted child lifecycle authority: $artifact" >&2
        return 1
      fi
    done
  done
  for owner in "$sub_state"/.*.teardown.lock "$sub_state"/.*.teardown.lock.owner.*; do
    [ -e "$owner" ] || [ -L "$owner" ] || continue
    echo "REFUSED: secondmate home has unresolved child teardown authority: $owner" >&2
    return 1
  done
  for owner in "$sub_state/.backlog-mutation-owner" "$sub_state"/.backlog-receipts.claimed.*; do
    [ -e "$owner" ] || [ -L "$owner" ] || continue
    echo "REFUSED: secondmate home has unresolved backlog mutation authority: $owner" >&2
    return 1
  done
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
    child_meta_is_regular "$child_meta" || return 1
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_lifecycle_accounting "$child_home" || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
      orca_worktree_identity_state "$child_orca_worktree_id" "$child_wt" >/dev/null || return 1
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
    [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
    child_meta_is_regular "$child_meta" || return 1
    child_id=$(basename "$child_meta" .meta)
    child_backend=$(fm_backend_of_meta "$child_meta")
    case "$child_backend" in
      tmux|herdr|zellij|orca|cmux)
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

child_endpoint_state() {
  local home=$1 child_meta=$2 child_id=$3 child_backend=$4 child_target=$5
  : "$child_backend" "$child_target"
  (
    unset FM_ROOT_OVERRIDE
    FM_HOME=$home
    FM_ROOT=$home
    fm_backend_target_state_of_meta "$child_meta" "fm-$child_id"
  )
}

close_child_endpoint() {
  local home=$1 child_meta=$2 child_id=$3 child_backend=$4 child_target=$5 state attempt=0 close_attempted=0
  audit_firstmate_home_children_endpoints "$home" || return 1
  state=$(child_endpoint_state "$home" "$child_meta" "$child_id" "$child_backend" "$child_target") || return 1
  case "$state" in
    absent) return 0 ;;
    present)
      (
        unset FM_ROOT_OVERRIDE
        FM_HOME=$home
        FM_ROOT=$home
        fm_backend_kill_owned_meta "$child_meta" "fm-$child_id"
      ) || {
        echo "REFUSED: failed to close exact child endpoint $child_target for $child_id; preserving child lifecycle state." >&2
        return 1
      }
      close_attempted=1
      ;;
    *)
      echo "REFUSED: child endpoint state for $child_target is unknown; preserving child lifecycle state for $child_id." >&2
      return 1
      ;;
  esac
  while [ "$attempt" -lt 10 ]; do
    if [ "$close_attempted" -eq 1 ]; then
      state=$(
        unset FM_ROOT_OVERRIDE
        FM_HOME=$home FM_ROOT=$home \
          fm_backend_closed_target_state_of_meta "$child_meta" "fm-$child_id"
      ) || return 1
    else
      state=$(child_endpoint_state "$home" "$child_meta" "$child_id" "$child_backend" "$child_target") || return 1
    fi
    case "$state" in
      absent) return 0 ;;
      unknown) return 1 ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "REFUSED: child endpoint $child_target still exists after close; preserving lifecycle state for $child_id." >&2
  return 1
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_orca_state child_return_rc
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
    child_meta_is_regular "$child_meta" || return 1
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
    if [ -z "$child_t" ]; then
      echo "REFUSED: child task $child_id has no exact recorded endpoint; preserving child lifecycle state." >&2
      return 1
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
      child_orca_state=$(orca_worktree_identity_state "$child_orca_worktree_id" "$child_wt") || return 1
    fi
    # Tombstone for the child home's own watcher, same contract as the main
    # task path: a mid-teardown gone endpoint is teardown, not a crew death.
    touch "$sub_state/$child_id.tearing-down"
    close_child_endpoint "$home" "$child_meta" "$child_id" "$child_backend" "$child_t" || return 1
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        auxiliary_owner_matches_target "$child_home" || return 1
        cleanup_firstmate_home_children "$child_home" || return 1
        AUXILIARY_REVALIDATE_TARGET=$child_home
        AUXILIARY_REVALIDATE_LABEL="child firstmate home"
        AUXILIARY_REVALIDATE_ID=$child_id
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" \
          revalidate_auxiliary_firstmate_home_cleanup || return 1
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        auxiliary_owner_matches_target "$child_wt" || return 1
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      fi
      if [ "$child_orca_state" = present ]; then
        orca_worktree_identity_state "$child_orca_worktree_id" "$child_wt" >/dev/null || return 1
        fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
        [ "$(orca_worktree_probe "$child_orca_worktree_id")" = absent ] || {
          echo "REFUSED: Orca child worktree id $child_orca_worktree_id was not confirmed absent after removal." >&2
          return 1
        }
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      auxiliary_owner_matches_target "$child_wt" || return 1
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" "$child_wt/.fm-grok-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        AUXILIARY_REVALIDATE_TARGET=$child_wt
        AUXILIARY_REVALIDATE_PROJECT=$child_proj
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" \
          revalidate_auxiliary_child_worktree_cleanup; then
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
  local id=$1 tmp line count=0 registered_home registered_abs expected_abs
  if [ -e "$SECONDMATE_REG" ] || [ -L "$SECONDMATE_REG" ]; then
    [ -f "$SECONDMATE_REG" ] && [ ! -L "$SECONDMATE_REG" ] || return 1
  else
    return 0
  fi
  expected_abs=$(removal_target_abs_path "$HOME_PATH") || return 1
  while IFS= read -r line; do
    case "$line" in
      "- $id"|"- $id "*)
        count=$((count + 1))
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_home" ] && [ "$registered_abs" = "$expected_abs" ] || {
          echo "REFUSED: secondmate registry entry for $id no longer names the staged home $expected_abs." >&2
          return 1
        }
        ;;
    esac
  done < "$SECONDMATE_REG"
  [ "$count" -le 1 ] || {
    echo "REFUSED: secondmate registry contains duplicate entries for $id." >&2
    return 1
  }
  [ "$count" -eq 1 ] || return 0
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  tmp=$(mktemp "$DATA/.secondmates.md.tmp.XXXXXXXX") || return 1
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  if ! fm_publish_file_no_follow "$tmp" "$SECONDMATE_REG" replace; then
    rm -f "$tmp"
    return 1
  fi
  ! grep -qE "^- $id( |$)" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  validate_firstmate_home_lifecycle_accounting "$HOME_PATH" || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    audit_firstmate_home_children_endpoints "$HOME_PATH" || exit 1
  fi
else
  validate_teardown_stage_storage_external_to "$WT" "worktree" || exit 1
fi
[ -z "$TASK_TMP" ] || validate_teardown_stage_storage_external_to "$TASK_TMP" "task temp root" || exit 1

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || [ -L "$child_meta" ] || continue
      child_meta_is_regular "$child_meta" || exit 1
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  if ! REPORT=$(fm_firstmate_scout_report_path "$FM_HOME" "$ID"); then
    echo "REFUSED: scout task $ID has no owned regular report at $FM_HOME/data/$ID/report.md." >&2
    echo "The report must be a non-symlink file contained in this Firstmate home, or use --force after explicit discard approval." >&2
    exit 1
  fi
fi

if [ "$RESUMING_STAGE" -eq 1 ]; then
  DELIVERY_OUTCOME=$STAGE_OUTCOME
  if [ "$STAGE_FORCE" = 0 ] && [ "$REQUESTED_FORCE" = --force ]; then
    case "$STAGE_PHASE" in
      worktree-cleaned|finalizing|backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded)
        echo "REFUSED: cannot change teardown force posture after cleanup completed for $ID." >&2
        echo "Retry without --force so the staged truthful outcome can finish." >&2
        exit 1
        ;;
    esac
    STAGE_FORCE=1
    FORCE=--force
    if [ "$KIND" != secondmate ]; then
      DELIVERY_OUTCOME=discarded
    fi
    write_teardown_stage "$STAGE_PHASE" "$STAGE_OWNER_IDENTITY" || {
      echo "REFUSED: could not persist forced retry posture for $ID; preserving the prior stage." >&2
      exit 1
    }
    STAGE_OUTCOME=$DELIVERY_OUTCOME
    rm -f "$COMPLETION_PROOF" || {
      echo "REFUSED: could not invalidate delivery proof after forcing retry for $ID." >&2
      exit 1
    }
  fi
  case "$STAGE_PHASE" in
    preparing)
      complete_teardown_stage_preparation || {
        echo "REFUSED: could not reconcile interrupted teardown preparation for $ID; preserving exact staged authority." >&2
        exit 1
      }
      revalidate_owned_cleanup || exit 1
      ;;
    prepared)
      revalidate_owned_cleanup || exit 1
      ;;
    endpoint-closed|worktree-cleanup-started|worktree-cleaned|finalizing|backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded)
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
  ORCA_WORKTREE_STATE=present
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
  if [ "$FORCE" = --force ]; then
    STAGE_FORCE=1
  else
    STAGE_FORCE=0
  fi
  if ! teardown_outcome_valid "$KIND" "$MODE" "$STAGE_FORCE" "$DELIVERY_OUTCOME"; then
    echo "REFUSED: invalid computed teardown outcome $DELIVERY_OUTCOME for $KIND/$MODE with force=$STAGE_FORCE; preserving lifecycle state." >&2
    exit 1
  fi
  prepare_teardown_stage || {
    echo "REFUSED: could not stage retryable teardown state for $ID; no endpoint or worktree cleanup was attempted." >&2
    exit 1
  }
fi
case "$STAGE_PHASE" in
  backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded) ;;
  *)
    ensure_completion_proof || {
      echo "REFUSED: could not persist completion proof for $ID; no endpoint or worktree cleanup was attempted." >&2
      exit 1
    }
    ;;
esac

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
      ORCA_WORKTREE_STATE=$(orca_worktree_identity_state "$ORCA_WORKTREE_ID" "$WT") || return 1
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
    if [ "$ORCA_WORKTREE_STATE" = present ]; then
      fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID" || return 1
      [ "$(orca_worktree_probe "$ORCA_WORKTREE_ID")" = absent ] || {
        echo "REFUSED: Orca worktree id $ORCA_WORKTREE_ID was not confirmed absent after removal." >&2
        return 1
      }
    fi
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
    remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" revalidate_owned_cleanup || return 1
    remove_secondmate_registry_entry "$ID" || return 1
  fi
  if [ -n "$TASK_TMP" ] && { [ -e "$TASK_TMP" ] || [ -L "$TASK_TMP" ]; }; then
    auxiliary_owner_matches_target "$TASK_TMP" || return 1
    safe_rm_rf "$TASK_TMP" "task temp root" || return 1
  fi
  cleanup_backend_release_confirmed || {
    echo "REFUSED: cleanup command completed, but the exact worktree is not confirmed absent or returned available for $ID." >&2
    return 1
  }
  auxiliary_targets_absent || return 1
  remove_teardown_owner_marker || return 1
}

auxiliary_targets_absent() {
  local kind target identity marker token
  while IFS=$'\t' read -r kind target identity marker token; do
    [ -n "$target" ] || return 1
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  done < "$AUX_OWNERS"
}

cleanup_backend_release_confirmed() {
  local probe
  if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
    probe=$(orca_worktree_probe "$ORCA_WORKTREE_ID") || return 1
    [ "$probe" = absent ]
  elif [ "$KIND" = secondmate ]; then
    worktree_released_from_project "$FM_ROOT" "$HOME_PATH"
  else
    worktree_released_from_project "$PROJ" "$WT"
  fi
}

cleanup_backend_absence_confirmed() {
  if [ "$STAGE_OWNER_MARKER" != none ]; then
    [ ! -e "$STAGE_OWNER_MARKER" ] && [ ! -L "$STAGE_OWNER_MARKER" ] || return 1
  fi
  cleanup_backend_release_confirmed
}

endpoint_absence_confirmed() {
  local endpoint_state
  [ -n "$T" ] || return 1
  endpoint_state=$(fm_backend_closed_target_state_of_meta "$META" "fm-$ID") || return 1
  [ "$endpoint_state" = absent ]
}

post_cleanup_absence_confirmed() {
  endpoint_absence_confirmed \
    && cleanup_backend_absence_confirmed \
    && auxiliary_targets_absent
}

cleanup_retryable_residual_state() {
  if [ "$KIND" = secondmate ]; then
    remove_secondmate_registry_entry "$ID" || return 1
  fi
  if [ "$STAGE_OWNER_MARKER" != none ]; then
    remove_teardown_owner_marker || return 1
    [ ! -e "$STAGE_OWNER_MARKER" ] && [ ! -L "$STAGE_OWNER_MARKER" ] || return 1
  fi
}

case "$STAGE_PHASE" in
  worktree-cleaned|finalizing|backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded)
    if ! post_cleanup_absence_confirmed; then
      echo "REFUSED: staged post-cleanup state for $ID no longer has confirmed endpoint and cleanup absence." >&2
      exit 1
    fi
    ;;
esac

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
    if cleanup_backend_release_confirmed && auxiliary_targets_absent; then
      cleanup_retryable_residual_state || {
        echo "REFUSED: cleanup is confirmed complete, but exact residual teardown state could not be removed for $ID; preserving retry authority." >&2
        exit 1
      }
      advance_teardown_stage worktree-cleaned || {
        echo "REFUSED: cleanup is confirmed complete, but the durable teardown phase could not be advanced for $ID." >&2
        exit 1
      }
    elif owner=$(teardown_owner_path) \
      && [ -n "$owner" ] && { [ -e "$owner" ] || [ -L "$owner" ]; }; then
      advance_teardown_stage ownership-lost || {
        echo "REFUSED: ownership was lost after interrupted cleanup, and that state could not be persisted for $ID." >&2
        exit 1
      }
      echo "REFUSED: teardown ownership is lost for $ID; preserving lifecycle state without inspecting or removing the recorded path." >&2
      exit 1
    else
      echo "REFUSED: interrupted cleanup for $ID is not yet independently confirmed; preserving retryable lifecycle state." >&2
      exit 1
    fi
  else
    perform_owned_cleanup || exit 1
    if ! cleanup_backend_absence_confirmed || ! auxiliary_targets_absent; then
      echo "REFUSED: cleanup reported success, but owned cleanup targets are not confirmed absent for $ID." >&2
      exit 1
    fi
    cleanup_retryable_residual_state || {
      echo "REFUSED: cleanup is confirmed complete, but exact residual teardown state could not be removed for $ID; preserving retry authority." >&2
      exit 1
    }
    advance_teardown_stage worktree-cleaned || {
      echo "REFUSED: cleanup finished, but the durable teardown phase could not be advanced for $ID." >&2
      exit 1
    }
  fi
fi
case "$STAGE_PHASE" in
  worktree-cleaned|finalizing|backlog-done-started|backlog-hold-started|backlog-held|backlog-reopen-started|backlog-recorded)
    if ! post_cleanup_absence_confirmed; then
      echo "REFUSED: staged post-cleanup state for $ID no longer has confirmed endpoint and cleanup absence." >&2
      exit 1
    fi
    ;;
esac
if [ "$STAGE_PHASE" = ownership-lost ]; then
  echo "REFUSED: teardown ownership is lost for $ID; reconcile the external cleanup state without reusing the recorded path." >&2
  exit 1
fi
if [ "$STAGE_PHASE" = worktree-cleaned ]; then
  advance_teardown_stage finalizing || {
    echo "REFUSED: cleanup finished, but finalization could not be staged for $ID." >&2
    exit 1
  }
fi
if [ "$STAGE_PHASE" = finalizing ]; then
  revalidate_backlog_record_binding || exit 1
  if [ "$BACKLOG_TRACKED" -ne 1 ] || [ "$KIND" = secondmate ]; then
    backlog_record_after_teardown || exit 1
    advance_teardown_stage backlog-recorded || exit 1
  else
    case "$DELIVERY_OUTCOME" in
      delivered-*) advance_teardown_stage backlog-done-started || exit 1 ;;
      discarded|unlanded) advance_teardown_stage backlog-hold-started || exit 1 ;;
      *)
        echo "REFUSED: invalid staged teardown outcome $DELIVERY_OUTCOME for $ID; preserving lifecycle state." >&2
        exit 1
        ;;
    esac
  fi
fi
if [ "$STAGE_PHASE" = backlog-done-started ]; then
  backlog_record_after_teardown delivery || exit 1
  advance_teardown_stage backlog-recorded || {
    echo "REFUSED: backlog finalization succeeded, but its durable phase could not be recorded for $ID." >&2
    exit 1
  }
fi
if [ "$STAGE_PHASE" = backlog-hold-started ]; then
  if [ "$DELIVERY_OUTCOME" = discarded ]; then
    BACKLOG_HOLD_REASON="discarded during explicitly forced teardown; no successful delivery recorded"
  else
    BACKLOG_HOLD_REASON="teardown complete but work is recoverable only outside the delivered default branch; no successful delivery recorded"
  fi
  prepare_backlog_mutation hold "$BACKLOG_HOLD_REASON" || exit 1
  if [ "$BACKLOG_MUTATION_ALREADY_APPLIED" -eq 0 ]; then
    backlog_record_after_teardown hold || exit 1
  fi
  verify_backlog_mutation_result || exit 1
  advance_teardown_stage backlog-held || {
    echo "REFUSED: truthful backlog hold succeeded, but its durable phase could not be recorded for $ID." >&2
    exit 1
  }
  rm -f "$BACKLOG_MUTATION_INTENT" || true
fi
if [ "$STAGE_PHASE" = backlog-held ]; then
  revalidate_backlog_record_binding || exit 1
  advance_teardown_stage backlog-reopen-started || exit 1
fi
if [ "$STAGE_PHASE" = backlog-reopen-started ]; then
  prepare_backlog_mutation reopen || exit 1
  if [ "$BACKLOG_MUTATION_ALREADY_APPLIED" -eq 0 ]; then
    backlog_record_after_teardown reopen || exit 1
  fi
  verify_backlog_mutation_result || exit 1
  advance_teardown_stage backlog-recorded || {
    echo "REFUSED: truthful backlog reopen succeeded, but its durable phase could not be recorded for $ID." >&2
    exit 1
  }
  rm -f "$BACKLOG_MUTATION_INTENT" || true
fi
if [ "$STAGE_PHASE" = backlog-recorded ] \
   && { [ "$DELIVERY_OUTCOME" = discarded ] || [ "$DELIVERY_OUTCOME" = unlanded ]; }; then
  revalidate_backlog_record_binding || exit 1
fi
post_cleanup_absence_confirmed || {
  echo "REFUSED: final lifecycle cleanup for $ID lost confirmed endpoint or cleanup absence." >&2
  exit 1
}
remove_grok_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
prepare_final_state_cleanup || {
  echo "REFUSED: could not persist final lifecycle cleanup authority for $ID; preserving task state." >&2
  exit 1
}
finish_final_state_cleanup || exit 1
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
