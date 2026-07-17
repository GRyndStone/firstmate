#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind, the
# adapter forces one same-session follow-up by running `grok --resume <session>`
# with a guard instruction. Every later Stop event reruns the predicate and
# schedules another continuation while the turn would still end blind.
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
[ -n "$SESSION_ID" ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'

GROK_HOME="${GROK_HOME:-$HOME/.grok}" \
  grok --resume "$SESSION_ID" \
    --cwd "$ROOT" \
    --output-format plain \
    -p "TURN WOULD END BLIND - supervision is off. Resume supervision according to the session-start operating block before ending the turn.

$REASON" >/dev/null 2>&1 || true
