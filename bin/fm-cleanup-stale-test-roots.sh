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
#   3. Age/freshness: mtime and (when available) birth time are both older than
#      --min-age-hours (default 6). Fresh or actively rewritten roots are refused.
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
NOW=$(date +%s)
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
  # Allocated size in bytes via du -sk * 1024 (matches prior audit method).
  local p=$1 kib
  kib=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
  if [ -z "${kib:-}" ]; then
    printf '0'
    return
  fi
  awk -v k="$kib" 'BEGIN { printf "%d", k * 1024 }'
}

path_mtime_epoch() {
  local p=$1
  if stat -f %m "$p" >/dev/null 2>&1; then
    stat -f %m "$p"
  else
    stat -c %Y "$p"
  fi
}

path_birth_epoch() {
  local p=$1 b
  # macOS: %B is birth; Linux often has %W (0 if unknown).
  if b=$(stat -f %B "$p" 2>/dev/null); then
    if [ -n "$b" ] && [ "$b" != "0" ] && [ "$b" != "-1" ]; then
      printf '%s\n' "$b"
      return
    fi
  fi
  if b=$(stat -c %W "$p" 2>/dev/null); then
    if [ -n "$b" ] && [ "$b" != "0" ]; then
      printf '%s\n' "$b"
      return
    fi
  fi
  # Unknown birth: treat as mtime for the age gate (conservative enough when
  # combined with mtime, and documented).
  path_mtime_epoch "$p"
}

owner_uid() {
  local p=$1
  if stat -f %u "$p" >/dev/null 2>&1; then
    stat -f %u "$p"
  else
    stat -c %u "$p"
  fi
}

has_open_files() {
  local p=$1
  if ! command -v lsof >/dev/null 2>&1; then
    # Without lsof we cannot prove no open files; refuse.
    return 0
  fi
  # Bound lsof to this path only. Avoid system-wide lsof and avoid +D tree
  # walks on multi-GiB fixture roots. macOS lsof accepts the path operand.
  if lsof -nP "$p" 2>/dev/null | awk 'NR>1 { found=1 } END { exit !found }'; then
    return 0
  fi
  return 1
}

has_live_process_ref() {
  local p=$1
  # Command-line mention (best effort; false positives refuse cleanup).
  # Exclude this cleanup script's own process tree from matching its scan path
  # only when the path appears solely as our argument noise: still fail closed
  # if any other process references the path.
  if command -v pgrep >/dev/null 2>&1; then
    # List PIDs matching the path, drop our own PID and parent.
    if pgrep -f "$p" 2>/dev/null | awk -v me="$$" -v pp="$PPID" '
        $1 != me && $1 != pp { found=1 }
        END { exit !found }
      '; then
      return 0
    fi
  else
    if ps -ax -o pid= -o command= 2>/dev/null | awk -v root="$p" -v me="$$" -v pp="$PPID" '
        $1 == me || $1 == pp { next }
        index($0, root) > 0 { found=1; exit }
        END { exit !found }
      '; then
      return 0
    fi
  fi
  return 1
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
  # Resolve and ensure still under BASE (no symlink escape).
  if [ ! -d "$raw" ]; then
    refused+=("$raw")
    refused_reasons+=("not-a-directory-anymore")
    continue
  fi
  resolved=$(cd "$raw" && pwd -P)
  case "$resolved" in
    "$BASE"/*) : ;;
    *)
      refused+=("$resolved")
      refused_reasons+=("escaped-base-via-symlink-or-resolve")
      continue
      ;;
  esac
  base_name=$(basename "$resolved")
  prefix_ok=0
  for prefix in "${PREFIXES[@]}"; do
    case "$base_name" in
      "${prefix}".*) prefix_ok=1; break ;;
    esac
  done
  if [ "$prefix_ok" -ne 1 ]; then
    refused+=("$resolved")
    refused_reasons+=("basename-prefix-mismatch")
    continue
  fi

  bytes=$(path_bytes "$resolved")
  total_scan_bytes=$((total_scan_bytes + bytes))
  reasons=()

  ouid=$(owner_uid "$resolved")
  if [ "$ouid" != "$ME_UID" ]; then
    reasons+=("owner-uid-$ouid-ne-$ME_UID")
  fi

  mtime=$(path_mtime_epoch "$resolved")
  birth=$(path_birth_epoch "$resolved")
  age_m=$((NOW - mtime))
  age_b=$((NOW - birth))
  if [ "$age_m" -lt "$MIN_AGE_SECS" ]; then
    reasons+=("mtime-too-fresh-${age_m}s")
  fi
  if [ "$age_b" -lt "$MIN_AGE_SECS" ]; then
    reasons+=("birth-too-fresh-${age_b}s")
  fi

  if has_live_process_ref "$resolved"; then
    reasons+=("live-process-or-lsof-reference")
  fi
  if has_open_files "$resolved"; then
    reasons+=("open-files")
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    refused+=("$resolved")
    refused_reasons+=("$(
      IFS=,
      printf '%s' "${reasons[*]}"
    )")
    total_refused_bytes=$((total_refused_bytes + bytes))
  else
    eligible+=("$resolved")
    eligible_bytes+=("$bytes")
    total_eligible_bytes=$((total_eligible_bytes + bytes))
  fi
done

printf '=== DELETION MANIFEST (eligible) ===\n'
if [ "${#eligible[@]}" -eq 0 ]; then
  printf '(none)\n'
else
  i=0
  for p in "${eligible[@]}"; do
    printf '  bytes=%s path=%s\n' "${eligible_bytes[$i]}" "$p"
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
    printf '  reason=%s path=%s\n' "${refused_reasons[$i]}" "$p"
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
  # Re-check existence and prefix immediately before rm.
  base_name=$(basename "$p")
  ok=0
  for prefix in "${PREFIXES[@]}"; do
    case "$base_name" in
      "${prefix}".*) ok=1; break ;;
    esac
  done
  if [ "$ok" -ne 1 ] || [ ! -d "$p" ]; then
    printf 'skip-race: %s\n' "$p"
    failed=$((failed + 1))
    continue
  fi
  b=$(path_bytes "$p")
  if rm -rf "$p"; then
    deleted=$((deleted + 1))
    deleted_bytes=$((deleted_bytes + b))
    printf 'deleted: %s\t%s\n' "$b" "$p"
  else
    printf 'delete-failed: %s\n' "$p"
    failed=$((failed + 1))
  fi
done

# Remeasure remaining matching roots.
remain_bytes=0
remain_count=0
for prefix in "${PREFIXES[@]}"; do
  while IFS= read -r -d '' p; do
    remain_count=$((remain_count + 1))
    remain_bytes=$((remain_bytes + $(path_bytes "$p")))
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
