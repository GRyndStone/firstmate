#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/learnings.md, then run fm-lock.sh, fm-wake-drain.sh,
# then read data/backlog.md, every state/*.meta, and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The bootstrap composition seams are the
# opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag for a read-only session and the
# narrower FM_BOOTSTRAP_SKIP_ENDPOINT_MUTATION=1 flag when endpoint ownership
# cannot license automatic liveness cleanup. Both live in fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - detect-only diagnostics always run. The four
#                       MUTATING sweeps (secondmate fast-forward, secondmate
#                       liveness, X-mode artifact writes, fleet sync) run only
#                       when this session actually holds the lock.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/learnings.md: read-only, always safe, always runs.
#   5. fleet digest   - data/backlog.md, durable program-source pointers,
#                       every state/*.meta, a bounded state/*.status tail,
#                       same-home endpoint ownership anomalies, state/.afk,
#                       and a cheap per-task endpoint-liveness read: read-only,
#                       always runs.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - fast-forwarding
# secondmate homes, writing X-mode artifacts, fetching/fast-forwarding every
# project clone - before ever discovering another session already holds the
# lock. Two sessions racing those sweeps is exactly the hazard the lock
# exists to prevent, so locking first closes the hole outright: only the
# session that actually wins the lock ever touches shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute from a second
# session.
# Only the four mutating sweeps and the wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout. Ordinary reporting and lock
#   refusal exit 0; unsafe effective-state admission exits non-zero before any
#   lock, bootstrap, recovery, or fleet access. A lock refusal is reported as
#   a loud banner inline so the read-only digest still completes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
if ! . "$SCRIPT_DIR/fm-wake-lib.sh"; then
  unset FM_WAKE_STATE_INIT
  printf 'SESSION START - %s\n' "$FM_HOME"
  printf 'ALERT: effective state failed strict home-scoping validation; lock, bootstrap, recovery, and fleet probes were skipped.\n'
  exit 1
fi
unset FM_WAKE_STATE_INIT
STATE=$FM_VALIDATED_STATE_PATH
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-program-lib.sh
. "$SCRIPT_DIR/fm-program-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = template
# defaults, projects.md absent = rebuild from clones, etc. - AGENTS.md
# section 3) and must never be confused with an empty-but-present file, so
# the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

section "SESSION START - $FM_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: secondmate sync, X-mode artifacts,\n'
    printf '●  fleet sync, and wake-queue drain. Detect-only bootstrap diagnostics and\n'
    printf '●  the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

ENDPOINT_AUDIT_OK=1
STATE_PROJECTION_SAFE=1
STATE_METADATA_SAFE=1
ENDPOINT_MUTATION_SAFE=1
ENDPOINT_AUDIT_JSON=$(FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_HOME="$FM_HOME" \
  FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-endpoint-audit.sh" --json 2>&1) || ENDPOINT_AUDIT_OK=0
if [ "$ENDPOINT_AUDIT_OK" -eq 1 ]; then
  if [ "$ENDPOINT_AUDIT_JSON" = '[]' ]; then
    ENDPOINT_AUDIT_OUT='endpoint-audit: no same-home endpoint ownership anomalies found'
  else
    ENDPOINT_MUTATION_SAFE=0
    ENDPOINT_AUDIT_OUT=$(printf '%s' "$ENDPOINT_AUDIT_JSON" | jq -r \
      '.[] | "ALERT endpoint-ownership: kind=\(.kind) task=\(.task) worktree=\(.worktree) backend=\(.backend) recorded=\(.recorded_endpoint) live=\(.live_endpoints | join(",")) reason=\(.reason // "-") action=inspect-only"')
  fi
  if printf '%s' "$ENDPOINT_AUDIT_JSON" | jq -e \
    'any(.[]; .backend == "unknown" and ((.reason // "") | contains("metadata is symlinked or non-regular")))' \
    >/dev/null; then
    STATE_PROJECTION_SAFE=0
    STATE_METADATA_SAFE=0
  fi
else
  ENDPOINT_AUDIT_OUT=$ENDPOINT_AUDIT_JSON
  STATE_PROJECTION_SAFE=0
  ENDPOINT_MUTATION_SAFE=0
fi

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ] || [ "$STATE_METADATA_SAFE" -eq 0 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$ENDPOINT_MUTATION_SAFE" -eq 0 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_SKIP_ENDPOINT_MUTATION=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$("$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness banners land right here too, ahead of the bulk
# digest below. The read-only path never touches the queue (another session
# may be actively draining it) but still runs fm-guard.sh directly with
# non-mutating advisory text, so the same alarms surface without repair
# commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
elif [ "$STATE_PROJECTION_SAFE" -eq 0 ]; then
  printf 'skipped - state metadata or endpoint inventory failed the pre-projection audit.\n'
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ "$STATE_PROJECTION_SAFE" -eq 0 ] || { [ -e "$STATE/.afk" ] && AFK_PRESENT=1; }
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if [ "$STATE_PROJECTION_SAFE" -eq 0 ] \
    || ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart plain pi so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 4. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_file_or_absent "$DATA/backlog.md" "data/backlog.md"

subsection "Durable program sources"
PROGRAM_FOUND=0
while IFS=$'\t' read -r relative source; do
  [ -n "$source" ] || continue
  PROGRAM_FOUND=1
  printf '%s: %s\n' "$relative" "$source"
done < <(fm_program_source_lines "$DATA")
if [ "$PROGRAM_FOUND" -eq 1 ]; then
  printf 'WARNING: the runnable queue is dispatch state, not proof of durable-program completion; audit each source for obligations that were never materialized as tasks.\n'
  printf 'Boundary: decomposition completeness requires supervisor judgment; use bin/fm-fleet-view.sh for structured runnable, held, and blocked counts.\n'
else
  printf '(none found by the documented naming convention; absence does not prove no plan exists elsewhere)\n'
fi

subsection "In-flight tasks (state/*.meta)"
META_FOUND=0
if [ "$STATE_PROJECTION_SAFE" -eq 1 ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    META_FOUND=1
    id=$(basename "$meta" .meta)
    printf '\n--- %s ---\n' "$id"
    cat "$meta"

    window=$(fm_meta_get "$meta" window)
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$window" ]; then
      backend=$(fm_backend_of_meta "$meta")
      endpoint_state=$(fm_backend_target_state_of_meta "$meta" "fm-$id")
      case "$endpoint_state" in
        present) printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window" ;;
        absent) printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window" ;;
        *) printf 'endpoint: unknown (backend=%s window=%s; exact-home probe unavailable)\n' "$backend" "$window" ;;
      esac
    else
      printf 'endpoint: unknown (no window recorded)\n'
    fi

    status="$STATE/$id.status"
    if [ -f "$status" ]; then
      print_status_tail "$status"
    else
      printf 'status tail: (no status file yet: %s)\n' "$status"
    fi
  done
else
  printf '(skipped - endpoint ownership audit failed before metadata projection)\n'
fi
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Endpoint ownership anomalies"
[ -n "$ENDPOINT_AUDIT_OUT" ] && printf '%s\n' "$ENDPOINT_AUDIT_OUT"
if [ "$ENDPOINT_AUDIT_OK" -eq 0 ]; then
  printf 'ALERT: same-home endpoint inventory could not be audited; duplicate recovery endpoints cannot be ruled out.\n'
fi

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
if [ "$STATE_PROJECTION_SAFE" -eq 1 ]; then
  for status in "$STATE"/*.status; do
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    id=$(basename "$status" .status)
    if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
      [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
      continue
    fi
    ORPHAN_STATUS_FOUND=1
    printf '\n--- %s ---\n' "$id"
    print_status_tail "$status"
  done
else
  printf '(skipped - endpoint ownership audit failed before state projection)\n'
fi
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
if [ "$STATE_PROJECTION_SAFE" -eq 0 ]; then
  printf 'unknown - effective state could not be audited safely\n'
elif [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/secondmates.md, data/captain.md, data/learnings.md,
data/backlog.md, or state/*.meta now - they were just printed in full.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

exit 0
