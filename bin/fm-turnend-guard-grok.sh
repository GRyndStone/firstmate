#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh. When that predicate says the primary would end blind, the
# adapter durably records one session-scoped follow-up and schedules its bounded
# delivery after the current Stop hook returns. Every later Stop event reruns
# the predicate and preserves or establishes one ready continuation owner while
# the turn would still end blind.
set -u

PAYLOAD=$(cat 2>/dev/null || true)

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -f "$ROOT/AGENTS.md" ] && [ -d "$ROOT/bin" ] || exit 0
[ -f "$ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')
if [ -z "$SESSION_ID" ]; then
  printf '%s\n' 'FIRSTMATE TURN-END GUARD UNSUPPORTED: Grok Stop payload omitted its exact sessionId; the passive hook cannot safely resume the originating session, so no continuation was scheduled.' >&2
  exit 0
fi
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}
[ ! -e "$STATE" ] && exit 0
[ -d "$STATE" ] || exit 1
HANDOFF_DIR="$STATE/.turnend-handoffs"
if command -v shasum >/dev/null 2>&1; then
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | shasum -a 256 | awk '{print substr($1,1,24)}')
elif command -v sha256sum >/dev/null 2>&1; then
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | sha256sum | awk '{print substr($1,1,24)}')
else
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | cksum | awk '{print $1 "-" $2}')
fi
[ -n "$KEY" ] || exit 1
PENDING="$HANDOFF_DIR/grok-$KEY.pending"
. "$ROOT/bin/fm-wake-lib.sh" || exit 1
HOOK_PID=${BASHPID:-$$}
HOOK_IDENTITY=$(fm_pid_identity "$HOOK_PID") || exit 1
PREPARE_LOCK="$PENDING.prepare"
PREPARE_OWNER="$PREPARE_LOCK/owner"
PREPARE_RECORD=$(printf '%s\n%s' "$HOOK_PID" "$HOOK_IDENTITY")
PREPARE_HELD=false

release_preparation() {
  [ "$PREPARE_HELD" = true ] || return 0
  if [ -d "$PREPARE_LOCK" ] && [ ! -L "$PREPARE_LOCK" ] \
    && [ "$(cat "$PREPARE_OWNER" 2>/dev/null || true)" = "$PREPARE_RECORD" ]; then
    rm -f "$PREPARE_OWNER" 2>/dev/null || true
    rmdir "$PREPARE_LOCK" 2>/dev/null || true
  fi
  PREPARE_HELD=false
}

acquire_preparation() {
  local attempt old_record old_pid old_identity
  attempt=0
  while [ "$attempt" -lt 250 ]; do
    if mkdir "$PREPARE_LOCK" 2>/dev/null; then
      if printf '%s\n' "$PREPARE_RECORD" > "$PREPARE_OWNER"; then
        PREPARE_HELD=true
        return 0
      fi
      rmdir "$PREPARE_LOCK" 2>/dev/null || true
      return 1
    fi
    [ -d "$PREPARE_LOCK" ] && [ ! -L "$PREPARE_LOCK" ] || return 1
    old_record=$(cat "$PREPARE_OWNER" 2>/dev/null || true)
    old_pid=$(printf '%s\n' "$old_record" | sed -n '1p')
    old_identity=$(printf '%s\n' "$old_record" | sed '1d')
    if ! fm_pid_alive "$old_pid" \
      || [ "$(fm_pid_identity "$old_pid" 2>/dev/null || true)" != "$old_identity" ]; then
      [ "$(cat "$PREPARE_OWNER" 2>/dev/null || true)" = "$old_record" ] || continue
      rm -f "$PREPARE_OWNER" 2>/dev/null || true
      rmdir "$PREPARE_LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

trap release_preparation EXIT
trap 'release_preparation; exit 1' TERM INT

delivery_owner_alive() {
  local record owner_pid owner_identity
  [ -f "$PENDING.delivery" ] && [ ! -L "$PENDING.delivery" ] || return 1
  record=$(cat "$PENDING.delivery" 2>/dev/null || true)
  owner_pid=$(printf '%s\n' "$record" | sed -n '1p')
  owner_identity=$(printf '%s\n' "$record" | sed '1d')
  fm_pid_alive "$owner_pid" \
    && [ "$(fm_pid_identity "$owner_pid" 2>/dev/null || true)" = "$owner_identity" ]
}

mkdir -p "$HANDOFF_DIR" || exit 1
acquire_preparation || exit 1
if [ -x "$ROOT/bin/fm-turnend-guard.sh" ]; then
  REASON=$(printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>&1 >/dev/null)
  RC=$?
else
  RC=125
  REASON='shared turn-end guard is unavailable'
fi
[ "$RC" -ne 0 ] || { rm -f "$PENDING" 2>/dev/null || true; exit 0; }

[ -n "$REASON" ] || {
  if [ "$RC" -eq 2 ]; then
    REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'
  else
    REASON="shared turn-end guard failed with exit $RC"
  fi
}
delivery_owner_alive && exit 0
TMP=$(mktemp "$HANDOFF_DIR/.grok-$KEY.XXXXXX.tmp") || exit 1
TOKEN=$(basename "$TMP")
{
  printf '%s\n' "$TOKEN"
  printf '%s\n' "$HOOK_PID"
  printf '%s\n' "$HOOK_IDENTITY"
  printf '%s\n' "$SESSION_ID"
  printf '%s\n' "$REASON"
} > "$TMP" || { rm -f "$TMP"; exit 1; }
chmod 600 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$PENDING" || { rm -f "$TMP"; exit 1; }

DELIVER="$ROOT/bin/fm-turnend-guard-grok-deliver.sh"
[ -x "$DELIVER" ] || exit 1
READY="$PENDING.ready"
nohup "$DELIVER" "$PENDING" "$ROOT" "$TOKEN" </dev/null >>"$HANDOFF_DIR/grok-delivery.log" 2>&1 &
WORKER_PID=$!
attempt=0
while [ "$attempt" -lt 100 ]; do
  WORKER_IDENTITY=$(fm_pid_identity "$WORKER_PID" 2>/dev/null || true)
  if [ -n "$WORKER_IDENTITY" ]; then
    EXPECTED_READY=$(printf '%s\n%s\n%s' "$TOKEN" "$WORKER_PID" "$WORKER_IDENTITY")
    if [ -f "$READY" ] && [ ! -L "$READY" ] \
      && [ "$(cat "$READY" 2>/dev/null || true)" = "$EXPECTED_READY" ]; then
      rm -f "$READY" 2>/dev/null || true
      exit 0
    fi
  fi
  fm_pid_alive "$WORKER_PID" || break
  sleep 0.02
  attempt=$((attempt + 1))
done
kill -TERM "$WORKER_PID" 2>/dev/null || true
wait "$WORKER_PID" 2>/dev/null || true
exit 1
