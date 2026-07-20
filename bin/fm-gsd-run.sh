#!/usr/bin/env bash
# Launch a GSD driving run in a VISIBLE herdr tab, never a raw invisible shell.
# This is the launch-mechanics owner for the drive-gsd visibility contract
# (.agents/skills/drive-gsd/SKILL.md "Visible driving runs"), so the captain
# and firstmate can always inspect a live run instead of trusting a subprocess
# buried in the driving crewmate's own shell.
# Usage: fm-gsd-run.sh [--no-wait] <task-id> <gsd-project-dir> gsd <args...>
#   Opens a fresh tab labeled gsd-<task-id>-r<stamp> in this home's herdr
#   workspace (bin/backends/herdr.sh conventions; the gsd- prefix keeps run
#   tabs out of the fm-<id> task-tab namespace that recovery's label matching
#   adopts, and the epoch-pid-random stamp keeps same-second runs for one
#   task id from sharing a label or exit file), cd's into <gsd-project-dir>,
#   runs the command there via `env`, and records the command's exit code to
#   a per-run exit file when it ends.
#   Leading NAME=value assignments before `gsd` are allowed (an operating
#   guide's PATH or model setup); any other leading word is refused so this
#   stays a GSD launcher, not a general remote shell.
#   Default: prints the run's tab/target/exit-file line, then waits for the
#   exit file and exits with the run's own exit code - a drop-in replacement
#   for running the command directly, with no helper-imposed timeout (bound
#   the run itself, e.g. `gsd headless auto --timeout`).
#   --no-wait: returns immediately after that line; poll the printed exit
#   file yourself (absent = still running) - use this for long auto runs
#   whose wall-clock exceeds your harness's foreground command budget.
#   The tab stays open after the run so its output stays inspectable; the
#   watcher never adopts it because the label does not start with fm-.
#   Exit code 96 is RESERVED for every wait-side abort - a run tab that
#   closed before recording an exit code, an unreadable-pane-state streak,
#   and a mid-wait herdr server restart - so a scripted caller can tell "the
#   wait was abandoned; the run itself was never touched and may still be
#   live in its tab" from "the run finished and failed". The run's own exit
#   code is always passed through unchanged, including a run that itself
#   exits 96.
#   At launch the wait records the herdr server's identity (its pid and/or
#   start time when `status --json` exposes them) and re-reads it each poll:
#   a changed identity means the server restarted, the run's process died
#   with it, and the exit file can never appear, so the WAIT aborts loudly
#   (exit 96) without touching the pane. The verified herdr build (0.7.3,
#   protocol 16) exposes NO pid or start-time in `status --json`; on such
#   builds the restart check is skipped rather than substituting a weaker
#   heuristic, a mid-wait identity read that yields nothing counts toward
#   the unreadable-state streak, and a restarted-then-restored server is
#   covered only by that streak.
#   FM_GSD_RUN_POLL overrides the wait poll interval in seconds (default 5);
#   FM_GSD_RUN_STATE_DIR overrides the exit-file directory (default: a fresh
#   mktemp dir per run; a relative path is resolved to an absolute one at
#   launch); FM_GSD_RUN_UNKNOWN_LIMIT overrides how many consecutive
#   unreadable pane-state polls the wait tolerates before abandoning the
#   WAIT (default 6) - that abort never touches the pane or the run, which
#   may still be live with its exit file still to come.
# Requires the herdr CLI: the visibility contract names herdr as the surface,
# so when herdr is missing or refuses, this fails loudly instead of falling
# back to an invisible run - the caller reports blocked rather than driving
# invisibly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

NO_WAIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-wait) NO_WAIT=1; shift ;;
    -*) echo "error: unknown flag $1 (see --help)" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 3 ]; then
  echo "error: usage: fm-gsd-run.sh [--no-wait] <task-id> <gsd-project-dir> gsd <args...>" >&2
  exit 2
fi

ID=$1
GSD_DIR=$2
shift 2

case "$ID" in
  ''|*[!a-zA-Z0-9._-]*) echo "error: task id must be a plain slug (letters, digits, ., _, -): '$ID'" >&2; exit 2 ;;
esac

GSD_DIR_ABS=$(cd "$GSD_DIR" 2>/dev/null && pwd -P) || { echo "error: gsd project dir not found: $GSD_DIR" >&2; exit 2; }

# The command must be a gsd invocation, optionally after NAME=value
# assignments; anything else is refused (this helper is not a remote shell).
FIRST_WORD=""
for w in "$@"; do
  case "$w" in
    [A-Za-z_]*=*) continue ;;
  esac
  FIRST_WORD=$w
  break
done
case "${FIRST_WORD##*/}" in
  gsd) ;;
  *) echo "error: the run command must be a gsd invocation (got '${FIRST_WORD:-nothing}'); only leading NAME=value assignments may precede gsd" >&2; exit 2 ;;
esac

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || exit 1

WAIT_ABORT_CODE=96

# The herdr server's identity for restart detection, or empty when this
# build's `status --json` exposes no pid/start-time (see header).
gsd_run_server_identity() {
  fm_backend_herdr_cli "$SES" status --json 2>/dev/null \
    | jq -r '.server | [(.pid // empty), (.started_at // empty), (.start_time // empty)] | join("/")' 2>/dev/null
}

RUN_STAMP="$(date +%s)-$$-$RANDOM"
LABEL="gsd-$ID-r$RUN_STAMP"

# Container ensure first so missing-herdr / refused-container preflight never
# leaves an unused mktemp root behind.
# Container ensure echoes "<session>:<workspace_id>\t<seeded_default_tab_id>";
# the seeded tab id threads through to create_task untouched, which is the
# only function allowed to prune it (see bin/backends/herdr.sh).
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$GSD_DIR_ABS") || exit 1
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_DEFAULT_TAB_ID=${CONTAINER_RAW#*$'\t'}
SES=${CONTAINER%%:*}
WSID=${CONTAINER#*:}
TAB_ID=
PANE_ID=
OWNED_RUN_DIR=0
RUN_DIR=

# Arm unstarted-run rollback BEFORE create_task so a create that commits a tab
# then fails/interrupts before IDs return still cleans via label-aware rollback.
# shellcheck disable=SC2329
cleanup_unstarted_run() {
  if [ "$OWNED_RUN_DIR" -eq 1 ] && [ -n "${RUN_DIR:-}" ]; then
    rm -rf "$RUN_DIR"
  fi
  if [ -n "${TAB_ID:-}" ]; then
    fm_backend_herdr_cli "$SES" tab close "$TAB_ID" >/dev/null 2>&1 || true
  else
    fm_backend_herdr_rollback_created_task_tab "$SES" "$WSID" "$LABEL" "" "" >/dev/null 2>&1 || true
  fi
}
trap cleanup_unstarted_run EXIT

TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL" "$GSD_DIR_ABS" "$SEEDED_DEFAULT_TAB_ID") || exit 1
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
if [ -z "$TAB_ID" ] || [ -z "$PANE_ID" ]; then
  echo "error: herdr did not return a tab/pane id for run tab $LABEL" >&2
  exit 1
fi
TARGET="$SES:$PANE_ID"

# Exit-file dir only after the run tab exists. Default is a fresh mktemp root
# per run (override with FM_GSD_RUN_STATE_DIR); owned roots are removed if
# setup fails before the pane command starts.
if [ -n "${FM_GSD_RUN_STATE_DIR:-}" ]; then
  mkdir -p "$FM_GSD_RUN_STATE_DIR"
  RUN_DIR=$(cd "$FM_GSD_RUN_STATE_DIR" && pwd -P)
else
  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-gsd-run-$ID.XXXXXX")
  OWNED_RUN_DIR=1
fi
EXIT_FILE="$RUN_DIR/$LABEL.exit"

# The pane command: run the gsd invocation through `env` (so quoted leading
# NAME=value assignments still apply as environment), then record its exit
# code. `env` resolves gsd against any PATH assignment passed this way.
PANE_CMD="cd $(shell_quote "$GSD_DIR_ABS") && env"
for w in "$@"; do
  PANE_CMD="$PANE_CMD $(shell_quote "$w")"
done
PANE_CMD="$PANE_CMD; echo \$? > $(shell_quote "$EXIT_FILE")"

SERVER_IDENTITY=$(gsd_run_server_identity) || SERVER_IDENTITY=""

# Keep unstarted-run rollback armed through deterministic pre-send readiness.
# Once the target is ready, clear the trap so an ambiguous pane-run failure
# preserves the tab and exit-file dir rather than destroying live work.
fm_backend_herdr_target_ready "$TARGET" || {
  echo "error: herdr target $TARGET is not ready for run tab $LABEL" >&2
  exit 1
}
trap - EXIT
fm_backend_herdr_send_text_line "$TARGET" "$PANE_CMD" || {
  echo "error: run launch outcome is ambiguous for herdr tab $LABEL (target $TARGET); the tab and exit state at $EXIT_FILE were preserved" >&2
  exit 1
}
echo "run: tab=$LABEL target=$TARGET exit_file=$EXIT_FILE"

if [ "$NO_WAIT" -eq 1 ]; then
  echo "not waiting: the run is live in tab $LABEL; poll the exit file for completion"
  exit 0
fi

POLL=${FM_GSD_RUN_POLL:-5}
UNKNOWN_LIMIT=${FM_GSD_RUN_UNKNOWN_LIMIT:-6}
case "$UNKNOWN_LIMIT" in ''|*[!0-9]*|0) UNKNOWN_LIMIT=6 ;; esac
UNKNOWN_STREAK=0
while [ ! -s "$EXIT_FILE" ]; do
  STATE=$(fm_backend_herdr_pane_agent_state "$SES" "$PANE_ID")
  if [ "$STATE" = dead ]; then
    [ -s "$EXIT_FILE" ] && break
    echo "error: run tab $LABEL closed before the run recorded an exit code" >&2
    exit "$WAIT_ABORT_CODE"
  fi
  UNREADABLE=0
  [ "$STATE" = unknown ] && UNREADABLE=1
  if [ -n "$SERVER_IDENTITY" ]; then
    NOW_IDENTITY=$(gsd_run_server_identity) || NOW_IDENTITY=""
    if [ -z "$NOW_IDENTITY" ]; then
      UNREADABLE=1
    elif [ "$NOW_IDENTITY" != "$SERVER_IDENTITY" ]; then
      [ -s "$EXIT_FILE" ] && break
      echo "error: the herdr server behind run tab $LABEL restarted mid-wait (identity $SERVER_IDENTITY -> $NOW_IDENTITY), so the run's process cannot have survived and $EXIT_FILE can never appear; abandoning the WAIT - the pane was NOT touched, and tab $LABEL still holds the run's output" >&2
      exit "$WAIT_ABORT_CODE"
    fi
  fi
  if [ "$UNREADABLE" -eq 1 ]; then
    UNKNOWN_STREAK=$((UNKNOWN_STREAK + 1))
    if [ "$UNKNOWN_STREAK" -ge "$UNKNOWN_LIMIT" ]; then
      [ -s "$EXIT_FILE" ] && break
      echo "error: abandoning the WAIT after $UNKNOWN_STREAK consecutive unreadable pane states for run tab $LABEL (herdr may be down); the run was NOT touched - it may still be live in the tab, and $EXIT_FILE may still appear when it ends" >&2
      exit "$WAIT_ABORT_CODE"
    fi
  else
    UNKNOWN_STREAK=0
  fi
  sleep "$POLL"
done
CODE=$(head -1 "$EXIT_FILE" | tr -cd '0-9')
case "$CODE" in
  ''|*[!0-9]*) CODE=1 ;;
esac
[ "$CODE" -le 255 ] || CODE=1
echo "run finished: exit=$CODE (output stays in herdr tab $LABEL)"
exit "$CODE"
