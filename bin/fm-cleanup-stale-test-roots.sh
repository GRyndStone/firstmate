#!/usr/bin/env bash
# fm-cleanup-stale-test-roots.sh - guarded cleanup for leaked firstmate test
# fixture roots under TMPDIR (historically fm-secondmate-safety.* and kin).
#
# Default mode is dry-run: inventory matching roots, recheck every safety gate,
# emit an explicit deletion manifest with per-path and total byte counts, and
# exit 0 without deleting anything.
#
#   fm-cleanup-stale-test-roots.sh              # dry-run (default)
#   fm-cleanup-stale-test-roots.sh --dry-run    # explicit dry-run
#   fm-cleanup-stale-test-roots.sh --apply      # delete only paths that pass every gate
#   fm-cleanup-stale-test-roots.sh --prefix P   # match P.* instead of default list
#   fm-cleanup-stale-test-roots.sh --min-age-hours N   # default 6
#   fm-cleanup-stale-test-roots.sh --base DIR   # scan DIR (default: TMPDIR or /tmp)
#
# Safety gates (all required for a path to be eligible):
#   1. Exact path prefix: basename matches <prefix>.* under the scan base only
#      (no recursion into unrelated trees; no symlink escape of the base).
#   2. Owner: directory owner UID equals the invoking user (id -u).
#   3. Age/freshness: the newest mtime and (when available) birth time anywhere
#      in the tree are both older than --min-age-hours (default 6).
#   4. Live process references: no process command line or cwd/root points at
#      the path (best-effort via ps and lsof).
#   5. Open files: lsof reports no open handles under the path.
#
# Ambiguous or live targets are listed under REFUSED and never deleted.
# --apply refuses the entire run if any candidate was refused (fail closed),
# unless --apply-eligible is passed to delete only the green set after the
# same manifest is printed.
#
# This tool does not replace the tests/lib.sh root fix; it is for already-leaked
# inventory after that fix lands. Remeasure at execution time - never treat an
# old audit inventory as permission to delete.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034
_FM_UNUSED_ROOT=$ROOT

MODE=dry-run
MIN_AGE_HOURS=6
BASE="${TMPDIR:-/tmp}"
APPLY_ELIGIBLE=0
PREFIXES=(fm-secondmate-safety)

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --dry-run) MODE=dry-run; shift ;;
    --apply) MODE=apply; shift ;;
    --apply-eligible) MODE=apply; APPLY_ELIGIBLE=1; shift ;;
    --min-age-hours)
      MIN_AGE_HOURS=${2:?--min-age-hours needs a number}
      shift 2
      ;;
    --base)
      BASE=${2:?--base needs a directory}
      shift 2
      ;;
    --prefix)
      PREFIXES=("${2:?--prefix needs a name}")
      shift 2
      ;;
    --prefix-add)
      PREFIXES+=("${2:?--prefix-add needs a name}")
      shift 2
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage 2
      ;;
  esac
done

if ! [[ "$MIN_AGE_HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'error: --min-age-hours must be a non-negative number\n' >&2
  exit 2
fi

if [ ! -d "$BASE" ]; then
  printf 'error: base is not a directory: %s\n' "$BASE" >&2
  exit 2
fi
BASE=$(cd "$BASE" && pwd -P)
ME_UID=$(id -u)
# shellcheck disable=SC2003
MIN_AGE_SECS=$(awk -v h="$MIN_AGE_HOURS" 'BEGIN { printf "%d", h * 3600 }')

# Collect candidate paths (non-recursive, basename match only).
candidates=()
for prefix in "${PREFIXES[@]}"; do
  if [[ ! "$prefix" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'error: refusing unsafe prefix %q\n' "$prefix" >&2
    exit 2
  fi
  # Use find -maxdepth 1 for exact base membership; resolve each path with pwd -P.
  while IFS= read -r -d '' p; do
    candidates+=("$p")
  done < <(find "$BASE" -maxdepth 1 -type d -name "${prefix}.*" -print0 2>/dev/null)
done

path_bytes() {
  local p=$1 output kib
  if ! output=$(du -sk "$p" 2>/dev/null); then
    return 1
  fi
  kib=$(awk 'NR == 1 { print $1 }' <<< "$output")
  if ! [[ "$kib" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s' "$((kib * 1024))"
}

PATH_NEWEST_MTIME=
PATH_NEWEST_BIRTH=
path_activity_epochs() {
  local p=$1 probe stats summary
  PATH_NEWEST_MTIME=
  PATH_NEWEST_BIRTH=
  probe=$(stat -c %Y "$p" 2>/dev/null) || probe=
  if [[ "$probe" =~ ^[0-9]+$ ]]; then
    if ! stats=$(find "$p" -exec stat -c '%Y %W' {} + 2>/dev/null); then
      return 1
    fi
  else
    probe=$(stat -f %m "$p" 2>/dev/null) || probe=
    if ! [[ "$probe" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    if ! stats=$(find "$p" -exec stat -f '%m %B' {} + 2>/dev/null); then
      return 1
    fi
  fi
  if ! summary=$(awk '
      NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^-?[0-9]+$/ { bad=1; next }
      {
        if (!seen || $1 > newest_mtime) newest_mtime=$1
        birth=($2 > 0 ? $2 : $1)
        if (!seen || birth > newest_birth) newest_birth=birth
        seen=1
      }
      END {
        if (bad || !seen) exit 1
        printf "%.0f %.0f\n", newest_mtime, newest_birth
      }
    ' <<< "$stats"); then
    return 1
  fi
  PATH_NEWEST_MTIME=${summary%% *}
  PATH_NEWEST_BIRTH=${summary#* }
  [[ "$PATH_NEWEST_MTIME" =~ ^[0-9]+$ ]] \
    && [[ "$PATH_NEWEST_BIRTH" =~ ^[0-9]+$ ]]
}

owner_uid() {
  local p=$1 value
  value=$(stat -c %u "$p" 2>/dev/null) || value=
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return
  fi
  value=$(stat -f %u "$p" 2>/dev/null) || value=
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

has_open_files() {
  local p=$1 output status
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  # +D walks the tree; fail closed on any non-empty output or non-1 status.
  if output=$(lsof -nP +D "$p" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  return 0
}

has_live_process_ref() {
  local p=$1 output
  local FM_CLEANUP_PROBE_PATH=$p
  export FM_CLEANUP_PROBE_PATH
  if ! command -v ps >/dev/null 2>&1; then
    return 0
  fi
  if ! output=$(ps -ax -o pid= -o command= 2>/dev/null); then
    return 0
  fi
  if awk -v me="$$" -v pp="$PPID" '
      BEGIN { root=ENVIRON["FM_CLEANUP_PROBE_PATH"] }
      $1 == me || $1 == pp { next }
      index($0, root) > 0 { found=1 }
      END { exit !found }
    ' <<< "$output"; then
    return 0
  fi
  return 1
}

CLASS_KIND=
CLASS_PATH=
CLASS_REASON=
CLASS_BYTES=0

add_class_reason() {
  local reason=$1
  if [ -n "$CLASS_REASON" ]; then
    CLASS_REASON="$CLASS_REASON,$reason"
  else
    CLASS_REASON=$reason
  fi
}

set_class_refusal() {
  CLASS_KIND=REFUSE
  CLASS_PATH=$1
  CLASS_REASON=$2
  CLASS_BYTES=${3:-0}
}

classify_path() {
  local raw=$1 resolved base_name prefix_ok=0 ouid age_m age_b bytes r
  local now
  CLASS_KIND=
  CLASS_PATH=$raw
  CLASS_REASON=
  CLASS_BYTES=0
  now=$(date +%s)

  if [ ! -d "$raw" ]; then
    set_class_refusal "$raw" not-a-directory-anymore
    return
  fi
  resolved=$(cd "$raw" && pwd -P) || {
    set_class_refusal "$raw" resolve-failed
    return
  }
  CLASS_PATH=$resolved
  case "$resolved" in
    "$BASE"/*) : ;;
    *)
      set_class_refusal "$resolved" escaped-base-via-symlink-or-resolve
      return
      ;;
  esac
  base_name=$(basename "$resolved")
  for prefix in "${PREFIXES[@]}"; do
    case "$base_name" in
      "${prefix}".*) prefix_ok=1; break ;;
    esac
  done
  if [ "$prefix_ok" -ne 1 ]; then
    set_class_refusal "$resolved" basename-prefix-mismatch
    return
  fi

  if bytes=$(path_bytes "$resolved") && [[ "$bytes" =~ ^[0-9]+$ ]]; then
    CLASS_BYTES=$bytes
  else
    add_class_reason size-probe-failed
  fi
  if ouid=$(owner_uid "$resolved"); then
    if [ "$ouid" != "$ME_UID" ]; then
      add_class_reason "owner-uid-$ouid-ne-$ME_UID"
    fi
  else
    add_class_reason owner-probe-failed
  fi

  if path_activity_epochs "$resolved"; then
    age_m=$((now - PATH_NEWEST_MTIME))
    age_b=$((now - PATH_NEWEST_BIRTH))
    if [ "$age_m" -lt "$MIN_AGE_SECS" ]; then
      r="mtime-too-fresh-${age_m}s"
      add_class_reason "$r"
    fi
    if [ "$age_b" -lt "$MIN_AGE_SECS" ]; then
      r="birth-too-fresh-${age_b}s"
      add_class_reason "$r"
    fi
  else
    add_class_reason freshness-probe-failed
  fi

  if has_live_process_ref "$resolved"; then
    add_class_reason live-process-command-or-cwd
  fi
  if has_open_files "$resolved"; then
    add_class_reason open-files-cwd-root-or-lsof-unavailable
  fi

  if [ -n "$CLASS_REASON" ]; then
    CLASS_KIND=REFUSE
    return
  fi
  CLASS_KIND=OK
}

eligible=()
eligible_bytes=()
refused=()
refused_reasons=()
total_eligible_bytes=0
total_refused_bytes=0
total_scan_bytes=0

printf 'fm-cleanup-stale-test-roots\n'
printf 'mode: %s\n' "$MODE"
printf 'base: %s\n' "$BASE"
printf 'prefixes: %s\n' "${PREFIXES[*]}"
printf 'min_age_hours: %s\n' "$MIN_AGE_HOURS"
printf 'invoker_uid: %s\n' "$ME_UID"
printf 'remeasured_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'candidates_found: %s\n' "${#candidates[@]}"
printf '\n'

for raw in "${candidates[@]:-}"; do
  [ -n "$raw" ] || continue
  classify_path "$raw"
  case "$CLASS_KIND" in
    OK)
      eligible+=("$CLASS_PATH")
      eligible_bytes+=("$CLASS_BYTES")
      total_eligible_bytes=$((total_eligible_bytes + CLASS_BYTES))
      total_scan_bytes=$((total_scan_bytes + CLASS_BYTES))
      ;;
    REFUSE)
      refused+=("$CLASS_PATH")
      refused_reasons+=("$CLASS_REASON")
      total_refused_bytes=$((total_refused_bytes + CLASS_BYTES))
      total_scan_bytes=$((total_scan_bytes + CLASS_BYTES))
      ;;
    *)
      refused+=("$raw")
      refused_reasons+=(classification-failed)
      ;;
  esac
done

printf '=== DELETION MANIFEST (eligible) ===\n'
if [ "${#eligible[@]}" -eq 0 ]; then
  printf '(none)\n'
else
  i=0
  for p in "${eligible[@]}"; do
    printf '  bytes=%s path=%q\n' "${eligible_bytes[$i]}" "$p"
    i=$((i + 1))
  done
fi
printf 'eligible_count: %s\n' "${#eligible[@]}"
printf 'eligible_bytes: %s\n' "$total_eligible_bytes"

printf '\n=== REFUSED (will not delete) ===\n'
if [ "${#refused[@]}" -eq 0 ]; then
  printf '(none)\n'
else
  i=0
  for p in "${refused[@]}"; do
    printf '  reason=%s path=%q\n' "${refused_reasons[$i]}" "$p"
    i=$((i + 1))
  done
fi
printf 'refused_count: %s\n' "${#refused[@]}"
printf 'refused_bytes: %s\n' "$total_refused_bytes"
printf 'scan_total_bytes: %s\n' "$total_scan_bytes"

printf '\n=== BEFORE/AFTER PLAN ===\n'
printf 'before_bytes_matching_scan: %s\n' "$total_scan_bytes"
if [ "$MODE" = "dry-run" ]; then
  printf 'after_bytes_if_apply_eligible: %s\n' "$((total_scan_bytes - total_eligible_bytes))"
  printf 'action: dry-run (no deletions performed)\n'
  exit 0
fi

# Apply mode
if [ "${#refused[@]}" -gt 0 ] && [ "$APPLY_ELIGIBLE" -ne 1 ]; then
  printf 'action: refused --apply because %s path(s) failed safety gates\n' "${#refused[@]}"
  printf 'hint: re-run with --apply-eligible to delete only the eligible set, or fix refusals\n'
  exit 3
fi

deleted=0
deleted_bytes=0
failed=0
for p in "${eligible[@]:-}"; do
  [ -n "$p" ] || continue
  classify_path "$p"
  case "$CLASS_KIND" in
    OK)
      if rm -rf "$CLASS_PATH"; then
        deleted=$((deleted + 1))
        deleted_bytes=$((deleted_bytes + CLASS_BYTES))
        printf 'deleted: %s\t%q\n' "$CLASS_BYTES" "$CLASS_PATH"
      else
        printf 'delete-failed: %q\n' "$CLASS_PATH"
        failed=$((failed + 1))
      fi
      ;;
    REFUSE)
      printf 'skip-recheck: reason=%s path=%q\n' "$CLASS_REASON" "$CLASS_PATH"
      failed=$((failed + 1))
      ;;
    *)
      printf 'skip-recheck: reason=classify-error path=%q\n' "$p"
      failed=$((failed + 1))
      ;;
  esac
done

# Remeasure remaining matching roots.
remain_bytes=0
remain_count=0
for prefix in "${PREFIXES[@]}"; do
  while IFS= read -r -d '' p; do
    remain_count=$((remain_count + 1))
    if bytes=$(path_bytes "$p") && [[ "$bytes" =~ ^[0-9]+$ ]]; then
      remain_bytes=$((remain_bytes + bytes))
    else
      printf 'measure-failed: %q\n' "$p"
      failed=$((failed + 1))
    fi
  done < <(find "$BASE" -maxdepth 1 -type d -name "${prefix}.*" -print0 2>/dev/null)
done

printf '\n=== AFTER ===\n'
printf 'deleted_count: %s\n' "$deleted"
printf 'deleted_bytes: %s\n' "$deleted_bytes"
printf 'delete_failures: %s\n' "$failed"
printf 'remaining_matching_count: %s\n' "$remain_count"
printf 'remaining_matching_bytes: %s\n' "$remain_bytes"
printf 'before_bytes_matching_scan: %s\n' "$total_scan_bytes"
printf 'after_bytes_matching_scan: %s\n' "$remain_bytes"

if [ "$failed" -gt 0 ]; then
  exit 4
fi
exit 0
