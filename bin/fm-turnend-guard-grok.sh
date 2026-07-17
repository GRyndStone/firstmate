#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind, the
# adapter durably records one same-session follow-up and schedules its bounded
# delivery after the current Stop hook returns. Every later Stop event reruns
# the predicate and schedules another continuation while the turn would still
# end blind.
set -u

PAYLOAD=$(cat 2>/dev/null || true)

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-grok.XXXXXX") || exit 0
trap 'rm -f "$ERR"' EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'

STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}
HANDOFF_DIR="$STATE/.turnend-handoffs"
mkdir -p "$HANDOFF_DIR" || exit 1
KEY=$(printf '%s' "${SESSION_ID:-missing}" | cksum | awk '{print $1 "-" $2}')
TMP=$(mktemp "$HANDOFF_DIR/grok-$KEY.XXXXXX.tmp") || exit 1
PENDING=${TMP%.tmp}.pending
{
  printf '%s\n' "$SESSION_ID"
  printf '%s\n' "$REASON"
} > "$TMP" || { rm -f "$TMP"; exit 1; }
chmod 600 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$PENDING" || { rm -f "$TMP"; exit 1; }

[ -n "$SESSION_ID" ] || exit 1
DELIVER="$ROOT/bin/fm-turnend-guard-grok-deliver.sh"
[ -x "$DELIVER" ] || exit 1
for PENDING in "$HANDOFF_DIR"/grok-*.pending; do
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || continue
  nohup "$DELIVER" "$PENDING" "$ROOT" </dev/null >>"$HANDOFF_DIR/grok-delivery.log" 2>&1 &
done
exit 0
