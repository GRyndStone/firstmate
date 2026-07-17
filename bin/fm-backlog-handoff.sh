#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# The move needs compatible `tasks-axi` on PATH, including atomic multi-ID `mv`
# (introduced in 0.2.2). Bootstrap requires it fleet-wide, so this works
# everywhere; the `config/backlog-backend=manual` knob only governs firstmate's
# own hand-editing of its own backlog, not this validated helper.
# The helper acquires both homes' state/.backlog.lock files in sorted path order
# before classification and holds them through the atomic move, so routine
# mutations cannot race either side of the handoff and two opposite handoffs
# cannot deadlock.
# Idempotent: re-running converges. Atomic: on any move failure nothing moves.
# See AGENTS.md project management and task lifecycle.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG=
MAIN_BACKLOG=
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ $# -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2; exit 1; }
ID=$1
shift
for key in "$@"; do
  fm_tasks_axi_valid_task_id "$key" || {
    echo "error: invalid backlog item id: $key" >&2
    exit 2
  }
done

secondmate_home() {
  local id=$1 line
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  line=$(grep -E "^- $id( |$)" "$REG" | tail -1 || true)
  [ -n "$line" ] || { echo "error: secondmate $id is not registered in $REG" >&2; return 1; }
  printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
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

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolved_existing_data_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: active firstmate data directory does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

validate_home_tasks_config() {
  local home=$1 config archive_rel archive_path archive_parent archive_resolved
  config="$home/.tasks.toml"
  if [ -L "$config" ] || [ ! -f "$config" ]; then
    echo "error: firstmate home must contain a regular .tasks.toml: $config" >&2
    return 1
  fi
  archive_rel=$(fm_tasks_axi_markdown_archive "$config") || return 1
  case "$archive_rel" in
    /*) archive_path=$archive_rel ;;
    *) archive_path="$home/$archive_rel" ;;
  esac
  archive_parent=$(dirname "$archive_path")
  archive_resolved=$(cd "$archive_parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$archive_path")") || {
    echo "error: cannot resolve markdown.archive parent inside firstmate home: $archive_path" >&2
    return 1
  }
  case "$archive_resolved" in
    "$home"/*) ;;
    *)
      echo "error: markdown.archive must remain inside firstmate home: $archive_path" >&2
      return 1
      ;;
  esac
  if [ -L "$archive_resolved" ]; then
    echo "error: markdown.archive must not be a symlink: $archive_resolved" >&2
    return 1
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. This reads only section headings and item header
# lines - never item bodies - so it drives the fleet-level classification (in-
# flight refusal, already-present idempotency, missing-key abort) without
# re-implementing the block/body move semantics that tasks-axi mv owns.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

ACTIVE_HOME=$(resolved_existing_dir "$FM_HOME") || exit 1
ACTIVE_DATA=$(resolved_existing_data_dir "$DATA") || exit 1
if [ -z "${FM_DATA_OVERRIDE:-}" ]; then
  case "$ACTIVE_DATA" in
    "$ACTIVE_HOME"/*) ;;
    *)
      echo "error: active firstmate data directory must resolve inside the active home: $DATA" >&2
      exit 1
      ;;
  esac
fi
DATA=$ACTIVE_DATA
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

MAIN_LOCK="$STATE/.backlog.lock"
SUB_LOCK="$SUB_HOME/state/.backlog.lock"
mkdir -p "$STATE" "$SUB_HOME/state"
if [ "$MAIN_LOCK" = "$SUB_LOCK" ]; then
  FIRST_LOCK=$MAIN_LOCK
  SECOND_LOCK=
elif [ "$(printf '%s\n' "$MAIN_LOCK" "$SUB_LOCK" | LC_ALL=C sort | head -n 1)" = "$MAIN_LOCK" ]; then
  FIRST_LOCK=$MAIN_LOCK
  SECOND_LOCK=$SUB_LOCK
else
  FIRST_LOCK=$SUB_LOCK
  SECOND_LOCK=$MAIN_LOCK
fi
LOCKS_HELD=0
MOVE_RESULT=
release_backlog_locks() {
  [ -z "$MOVE_RESULT" ] || rm -f "$MOVE_RESULT" 2>/dev/null || true
  if [ "$LOCKS_HELD" -eq 1 ]; then
    [ -z "$SECOND_LOCK" ] || fm_lock_release "$SECOND_LOCK"
    fm_lock_release "$FIRST_LOCK"
    LOCKS_HELD=0
  fi
}
trap release_backlog_locks EXIT
fm_lock_acquire_wait "$FIRST_LOCK"
[ -z "$SECOND_LOCK" ] || fm_lock_acquire_wait "$SECOND_LOCK"
LOCKS_HELD=1
if ! fm_tasks_axi_reconcile_mutation_owner "$STATE"; then
  echo "error: the active home still has live or unreadable durable backlog mutation ownership" >&2
  exit 1
fi
if [ "$SUB_HOME/state" != "$STATE" ] \
   && ! fm_tasks_axi_reconcile_mutation_owner "$SUB_HOME/state"; then
  echo "error: secondmate $ID still has live or unreadable durable backlog mutation ownership" >&2
  exit 1
fi
refuse_receipt_transactions() {
  local label=$1 state_dir=$2 claim
  for claim in "$state_dir"/.backlog-receipts.claimed.*; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    echo "error: $label has an interrupted backlog receipt transaction; reconcile it with fm-backlog.sh before handoff" >&2
    return 1
  done
}
refuse_receipt_transactions "the active home" "$STATE" || exit 1
if [ "$SUB_HOME/state" != "$STATE" ]; then
  refuse_receipt_transactions "secondmate $ID" "$SUB_HOME/state" || exit 1
fi

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
      "## Queued") TO_MOVE+=("$key") ;;
      "## In flight") IN_FLIGHT+=("$key") ;;
      "## Done") DONE+=("$key") ;;
      *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

validate_home_tasks_config "$ACTIVE_HOME" || exit 1
validate_home_tasks_config "$SUB_HOME" || exit 1

if ! (cd "$ACTIVE_HOME" && HOME="$ACTIVE_HOME" fm_tasks_axi_compatible); then
  echo "error: tasks-axi with atomic multi-ID mv support (0.2.2+) is required to move backlog items" >&2
  exit 1
fi

# Seed the destination with firstmate's standard three-section scaffold when it
# does not exist yet, so the moved item lands under the right section. (Left to
# create the file itself, tasks-axi mv writes its own `# Backlog` title format,
# which is not firstmate's home-backlog convention.)
mkdir -p "$SUB_HOME/data"
SUB_CREATED=0
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
  SUB_CREATED=1
fi
MOVE_RESULT=$(mktemp "$STATE/.backlog-handoff-result.XXXXXX") || exit 1
printf '%s\n' ambiguous > "$MOVE_RESULT" || exit 1

run_owned_handoff_mutation() {
  local parent_pid worker_pid worker_identity current_identity previous_identity=
  local mutation_token start_path i=0 status=0 published_main=0 published_sub=0
  parent_pid=${BASHPID:-$$}
  mutation_token=$(fm_tasks_axi_mutation_owner_token) || return 1
  start_path=$(fm_tasks_axi_mutation_owner_start_path "$STATE") || return 1
  (
    local wait_count=0
    while [ ! -e "$start_path" ]; do
      fm_pid_alive "$parent_pid" || exit 125
      [ "$wait_count" -lt 200 ] || exit 125
      sleep 0.05
      wait_count=$((wait_count + 1))
    done
    cd "$ACTIVE_HOME" || exit 1
    HOME="$ACTIVE_HOME" exec tasks-axi mv "${TO_MOVE[@]}" --backend markdown \
      --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG"
  ) &
  worker_pid=$!
  while [ "$i" -lt 40 ]; do
    current_identity=$(fm_tasks_axi_mutation_pid_identity "$worker_pid" 2>/dev/null || true)
    if [ -n "$current_identity" ] && [ -n "$previous_identity" ] \
       && [ "$current_identity" = "$previous_identity" ]; then
      worker_identity=$current_identity
      break
    fi
    previous_identity=$current_identity
    sleep 0.01
    i=$((i + 1))
  done
  if [ -z "${worker_identity:-}" ]; then
    wait "$worker_pid" 2>/dev/null || true
    return 1
  fi
  if ! fm_tasks_axi_publish_mutation_owner "$STATE" "$worker_pid" "$worker_identity" "$mutation_token"; then
    current_identity=$(fm_tasks_axi_mutation_pid_identity "$worker_pid" 2>/dev/null || true)
    [ "$current_identity" != "$worker_identity" ] || kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    return 1
  fi
  published_main=1
  if [ "$SUB_HOME/state" != "$STATE" ]; then
    if ! fm_tasks_axi_publish_mutation_owner "$SUB_HOME/state" "$worker_pid" "$worker_identity" "$mutation_token"; then
      current_identity=$(fm_tasks_axi_mutation_pid_identity "$worker_pid" 2>/dev/null || true)
      [ "$current_identity" != "$worker_identity" ] || kill -TERM "$worker_pid" 2>/dev/null || true
      wait "$worker_pid" 2>/dev/null || true
      fm_tasks_axi_clear_mutation_owner "$STATE" "$mutation_token" 2>/dev/null || true
      return 1
    fi
    published_sub=1
    if ! fm_tasks_axi_start_mutation_owner "$SUB_HOME/state" "$mutation_token"; then
      current_identity=$(fm_tasks_axi_mutation_pid_identity "$worker_pid" 2>/dev/null || true)
      [ "$current_identity" != "$worker_identity" ] || kill -TERM "$worker_pid" 2>/dev/null || true
      wait "$worker_pid" 2>/dev/null || true
      fm_tasks_axi_clear_mutation_owner "$SUB_HOME/state" "$mutation_token" 2>/dev/null || true
      fm_tasks_axi_clear_mutation_owner "$STATE" "$mutation_token" 2>/dev/null || true
      return 1
    fi
  fi
  if ! fm_tasks_axi_start_mutation_owner "$STATE" "$mutation_token"; then
    current_identity=$(fm_tasks_axi_mutation_pid_identity "$worker_pid" 2>/dev/null || true)
    [ "$current_identity" != "$worker_identity" ] || kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    [ "$published_sub" -eq 0 ] || fm_tasks_axi_clear_mutation_owner "$SUB_HOME/state" "$mutation_token" 2>/dev/null || true
    [ "$published_main" -eq 0 ] || fm_tasks_axi_clear_mutation_owner "$STATE" "$mutation_token" 2>/dev/null || true
    return 1
  fi
  wait "$worker_pid" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' committed > "$MOVE_RESULT" || return 1
  else
    printf '%s\n' failed > "$MOVE_RESULT" || return 1
  fi
  [ "$published_sub" -eq 0 ] || fm_tasks_axi_clear_mutation_owner "$SUB_HOME/state" "$mutation_token" || status=70
  [ "$published_main" -eq 0 ] || fm_tasks_axi_clear_mutation_owner "$STATE" "$mutation_token" || status=70
  return "$status"
}

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call is a
# single atomic transaction, so a connected set (blocker + dependents) moves
# together and, on any failure, neither backlog's content changes - the only
# cleanup is a scaffold we just created. tasks-axi writes both its success and
# error output to stdout, so capture it and surface it only on failure.
MV_STATUS=0
MV_OUT=$(run_owned_handoff_mutation 2>&1) || MV_STATUS=$?
MOVE_OUTCOME=$(cat "$MOVE_RESULT" 2>/dev/null || printf '%s\n' ambiguous)
rm -f "$MOVE_RESULT"
MOVE_RESULT=
RECEIPT_INVALIDATION_FAILED=0
if [ "$MOVE_OUTCOME" = committed ]; then
  for key in "${TO_MOVE[@]}"; do
    fm_tasks_axi_invalidate_completion_receipt "$STATE" "$key" || RECEIPT_INVALIDATION_FAILED=1
    fm_tasks_axi_invalidate_completion_receipt "$SUB_HOME/state" "$key" || RECEIPT_INVALIDATION_FAILED=1
  done
fi
if [ "$MV_STATUS" -ne 0 ]; then
  if [ "$SUB_CREATED" -eq 1 ] && [ "$MOVE_OUTCOME" = failed ]; then
    rm -f "$SUB_BACKLOG"
  fi
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  if [ "$MOVE_OUTCOME" = committed ]; then
    echo "error: backlog handoff committed, but durable mutation-owner cleanup failed; destination was preserved" >&2
    [ "$RECEIPT_INVALIDATION_FAILED" -eq 0 ] \
      || echo "error: one or more completion receipts also could not be invalidated safely" >&2
  elif [ "$MOVE_OUTCOME" = failed ]; then
    echo "error: tasks-axi mv failed; nothing was moved." >&2
  else
    echo "error: backlog handoff outcome is ambiguous; destination was preserved for reconciliation" >&2
  fi
  exit 1
fi
if [ "$RECEIPT_INVALIDATION_FAILED" -ne 0 ]; then
  echo "error: handoff succeeded but one or more completion receipts could not be invalidated safely" >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
