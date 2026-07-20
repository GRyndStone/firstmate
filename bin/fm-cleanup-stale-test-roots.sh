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
  if printf '%s\n' "$output" | awk -v me="$$" -v pp="$PPID" '
      BEGIN { root=ENVIRON["FM_CLEANUP_PROBE_PATH"] }
      $1 == me || $1 == pp { next }
      index($0, root) > 0 { found=1; exit }
      END { exit !found }
    '; then
    return 0
  fi
  return 1
}

# classify_path <raw-or-resolved-path>
# Prints "OK|<resolved>|<bytes>" when every safety gate passes, or
# "REFUSE|<path>|<reason>|<bytes>" when any gate fails. Shared by the initial
# scan and the immediate pre-delete recheck so apply mode cannot TOCTOU-skip
# owner/age/live/open-file gates.
classify_path() {
  local raw=$1 resolved base_name prefix_ok=0 ouid mtime birth age_m age_b bytes
  local reason_csv="" r
  local now
  now=$(date +%s)

  if [ ! -d "$raw" ]; then
    printf 'REFUSE|%s|not-a-directory-anymore|0\n' "$raw"
    return
  fi
  resolved=$(cd "$raw" && pwd -P) || {
    printf 'REFUSE|%s|resolve-failed|0\n' "$raw"
    return
  }
  case "$resolved" in
    "$BASE"/*) : ;;
    *)
      printf 'REFUSE|%s|escaped-base-via-symlink-or-resolve|0\n' "$resolved"
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
    printf 'REFUSE|%s|basename-prefix-mismatch|0\n' "$resolved"
    return
  fi

  bytes=$(path_bytes "$resolved")
  ouid=$(owner_uid "$resolved")
  if [ "$ouid" != "$ME_UID" ]; then
    reason_csv="owner-uid-$ouid-ne-$ME_UID"
  fi

  mtime=$(path_mtime_epoch "$resolved")
  birth=$(path_birth_epoch "$resolved")
  age_m=$((now - mtime))
  age_b=$((now - birth))
  if [ "$age_m" -lt "$MIN_AGE_SECS" ]; then
    r="mtime-too-fresh-${age_m}s"
    if [ -n "$reason_csv" ]; then reason_csv="$reason_csv,$r"; else reason_csv=$r; fi
  fi
  if [ "$age_b" -lt "$MIN_AGE_SECS" ]; then
    r="birth-too-fresh-${age_b}s"
    if [ -n "$reason_csv" ]; then reason_csv="$reason_csv,$r"; else reason_csv=$r; fi
  fi

  if has_live_process_ref "$resolved"; then
    r="live-process-command-or-cwd"
    if [ -n "$reason_csv" ]; then reason_csv="$reason_csv,$r"; else reason_csv=$r; fi
  fi
  if has_open_files "$resolved"; then
    r="open-files-cwd-root-or-lsof-unavailable"
    if [ -n "$reason_csv" ]; then reason_csv="$reason_csv,$r"; else reason_csv=$r; fi
  fi

  if [ -n "$reason_csv" ]; then
    printf 'REFUSE|%s|%s|%s\n' "$resolved" "$reason_csv" "$bytes"
    return
  fi
  printf 'OK|%s|%s\n' "$resolved" "$bytes"
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
  verdict=$(classify_path "$raw")
  case "$verdict" in
    OK\|*)
      resolved=${verdict#OK|}
      bytes=${resolved##*|}
      resolved=${resolved%|*}
      eligible+=("$resolved")
      eligible_bytes+=("$bytes")
      total_eligible_bytes=$((total_eligible_bytes + bytes))
      total_scan_bytes=$((total_scan_bytes + bytes))
      ;;
    REFUSE\|*)
      rest=${verdict#REFUSE|}
      resolved=${rest%%|*}
      rest=${rest#*|}
      reason=${rest%%|*}
      bytes=${rest#*|}
      refused+=("$resolved")
      refused_reasons+=("$reason")
      total_refused_bytes=$((total_refused_bytes + bytes))
      total_scan_bytes=$((total_scan_bytes + bytes))
      ;;
  esac
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
  # Immediate pre-delete recheck: every safety gate, not just basename/existence.
  verdict=$(classify_path "$p")
  case "$verdict" in
    OK\|*)
      resolved=${verdict#OK|}
      bytes=${resolved##*|}
      resolved=${resolved%|*}
      if rm -rf "$resolved"; then
        deleted=$((deleted + 1))
        deleted_bytes=$((deleted_bytes + bytes))
        printf 'deleted: %s\t%s\n' "$bytes" "$resolved"
      else
        printf 'delete-failed: %s\n' "$resolved"
        failed=$((failed + 1))
      fi
      ;;
    REFUSE\|*)
      rest=${verdict#REFUSE|}
      resolved=${rest%%|*}
      rest=${rest#*|}
      reason=${rest%%|*}
      printf 'skip-recheck: reason=%s path=%s\n' "$reason" "$resolved"
      failed=$((failed + 1))
      ;;
    *)
      printf 'skip-recheck: reason=classify-error path=%s\n' "$p"
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
