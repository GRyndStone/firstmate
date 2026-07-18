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
EFFECTIVE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}
STATE=${FM_STATE_OVERRIDE:-$EFFECTIVE_HOME/state}
# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
. "$ROOT/bin/fm-wake-lib.sh" || exit 1
unset FM_WAKE_STATE_INIT
fm_validate_effective_state_path "$STATE" allow-missing-final || exit 1
STATE=$FM_VALIDATED_STATE_PATH
[ ! -e "$STATE" ] && exit 0
fm_validate_effective_state_path "$STATE" existing || exit 1
STATE=$FM_VALIDATED_STATE_PATH
HANDOFF_DIR="$STATE/.turnend-handoffs"
if [ -e "$HANDOFF_DIR" ]; then
  [ -d "$HANDOFF_DIR" ] && [ ! -L "$HANDOFF_DIR" ] || exit 1
else
  mkdir "$HANDOFF_DIR" 2>/dev/null \
    || { [ -d "$HANDOFF_DIR" ] && [ ! -L "$HANDOFF_DIR" ]; } \
    || exit 1
  [ -d "$HANDOFF_DIR" ] && [ ! -L "$HANDOFF_DIR" ] || exit 1
fi
if command -v shasum >/dev/null 2>&1; then
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | shasum -a 256 | awk '{print substr($1,1,24)}')
elif command -v sha256sum >/dev/null 2>&1; then
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | sha256sum | awk '{print substr($1,1,24)}')
else
  KEY=$(printf '%s' "${SESSION_ID:-missing}" | cksum | awk '{print $1 "-" $2}')
fi
[ -n "$KEY" ] || exit 1
PENDING="$HANDOFF_DIR/grok-$KEY.pending"
HOOK_PID=${BASHPID:-$$}
HOOK_IDENTITY=$(fm_pid_identity "$HOOK_PID") || exit 1
PREPARE_LOCK="$PENDING.prepare"
PREPARE_OWNER="$PREPARE_LOCK/owner"
PREPARE_RECORD=$(printf '%s\n%s' "$HOOK_PID" "$HOOK_IDENTITY")
PREPARE_HELD=false

# shellcheck disable=SC2329 # Invoked by name from EXIT and signal traps.
release_preparation() {
  [ "$PREPARE_HELD" = true ] || return 0
  if [ -d "$PREPARE_LOCK" ] && [ ! -L "$PREPARE_LOCK" ] \
    && [ -f "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ] \
    && [ "$(cat "$PREPARE_OWNER" 2>/dev/null || true)" = "$PREPARE_RECORD" ]; then
    rm -f "$PREPARE_OWNER" 2>/dev/null || true
    rmdir "$PREPARE_LOCK" 2>/dev/null || true
  fi
  PREPARE_HELD=false
}

acquire_preparation() {
  local attempt old_record old_pid old_identity old_state current_identity
  attempt=0
  while [ "$attempt" -lt 250 ]; do
    if mkdir "$PREPARE_LOCK" 2>/dev/null; then
      if printf '%s\n' "$PREPARE_RECORD" | fm_write_file_no_follow "$PREPARE_OWNER"; then
        PREPARE_HELD=true
        return 0
      fi
      rmdir "$PREPARE_LOCK" 2>/dev/null || true
      return 1
    fi
    if [ ! -e "$PREPARE_LOCK" ] && [ ! -L "$PREPARE_LOCK" ]; then
      attempt=$((attempt + 1))
      continue
    fi
    [ -d "$PREPARE_LOCK" ] && [ ! -L "$PREPARE_LOCK" ] || return 1
    if [ ! -e "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ]; then
      sleep 0.02
      attempt=$((attempt + 1))
      continue
    fi
    [ -f "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ] || return 1
    old_record=$(cat "$PREPARE_OWNER" 2>/dev/null || true)
    old_pid=$(printf '%s\n' "$old_record" | sed -n '1p')
    old_identity=$(printf '%s\n' "$old_record" | sed '1d')
    old_state=$(fm_pid_state "$old_pid")
    current_identity=
    if [ "$old_state" = alive ]; then
      current_identity=$(fm_pid_identity "$old_pid" 2>/dev/null || true)
    fi
    if [ "$old_state" = dead ] \
      || { [ "$old_state" = alive ] && [ -n "$current_identity" ] && [ "$current_identity" != "$old_identity" ]; }; then
      if [ ! -e "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ]; then
        attempt=$((attempt + 1))
        continue
      fi
      [ -f "$PREPARE_OWNER" ] && [ ! -L "$PREPARE_OWNER" ] || return 1
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
  local pending_record expected_token pending_hook_pid pending_hook_identity pending_session record owner_token owner_pid owner_identity
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  pending_record=$(cat "$PENDING" 2>/dev/null || true)
  expected_token=$(printf '%s\n' "$pending_record" | sed -n '1p')
  pending_hook_pid=$(printf '%s\n' "$pending_record" | sed -n '2p')
  pending_hook_identity=$(printf '%s\n' "$pending_record" | sed -n '3p')
  pending_session=$(printf '%s\n' "$pending_record" | sed -n '4p')
  [ -n "$expected_token" ] && [ -n "$pending_hook_identity" ] \
    && [ "$pending_session" = "$SESSION_ID" ] || return 1
  case "$pending_hook_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$PENDING.delivery" ] && [ ! -L "$PENDING.delivery" ] || return 1
  record=$(cat "$PENDING.delivery" 2>/dev/null || true)
  owner_token=$(printf '%s\n' "$record" | sed -n '1p')
  owner_pid=$(printf '%s\n' "$record" | sed -n '2p')
  owner_identity=$(printf '%s\n' "$record" | sed '1,2d')
  [ "$owner_token" = "$expected_token" ] \
    && fm_pid_alive "$owner_pid" \
    && [ "$(fm_pid_identity "$owner_pid" 2>/dev/null || true)" = "$owner_identity" ] \
    && [ "$(cat "$PENDING" 2>/dev/null || true)" = "$pending_record" ]
}

wait_for_delivery_owner_release() {
  local attempt record owner_pid owner_identity owner_state current_identity
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ -e "$PENDING.delivery" ] || return 0
    [ -f "$PENDING.delivery" ] && [ ! -L "$PENDING.delivery" ] || return 1
    record=$(cat "$PENDING.delivery" 2>/dev/null || true)
    owner_pid=$(printf '%s\n' "$record" | sed -n '2p')
    owner_identity=$(printf '%s\n' "$record" | sed '1,2d')
    case "$owner_pid" in
      ''|*[!0-9]*)
        owner_pid=$(printf '%s\n' "$record" | sed -n '1p')
        owner_identity=$(printf '%s\n' "$record" | sed '1d')
        ;;
    esac
    owner_state=$(fm_pid_state "$owner_pid")
    current_identity=
    if [ "$owner_state" = alive ]; then
      current_identity=$(fm_pid_identity "$owner_pid" 2>/dev/null || true)
    fi
    if [ "$owner_state" = dead ] \
      || { [ "$owner_state" = alive ] && [ -n "$current_identity" ] && [ "$current_identity" != "$owner_identity" ]; }; then
      [ "$(cat "$PENDING.delivery" 2>/dev/null || true)" = "$record" ] || continue
      rm -f "$PENDING.delivery" || return 1
      return 0
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

acquire_preparation || exit 1
if [ -x "$ROOT/bin/fm-turnend-guard.sh" ]; then
  REASON=$(printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>&1 >/dev/null)
  RC=$?
else
  RC=125
  REASON='shared turn-end guard is unavailable'
fi
[ "$RC" -ne 0 ] || { rm -f "$PENDING" "$PENDING.acknowledged" 2>/dev/null || true; exit 0; }

[ -n "$REASON" ] || {
  if [ "$RC" -eq 2 ]; then
    REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'
  else
    REASON="shared turn-end guard failed with exit $RC"
  fi
}
delivery_owner_alive && exit 0
if ! wait_for_delivery_owner_release; then
  delivery_owner_alive && exit 0
  exit 1
fi
TMP=$(mktemp "$HANDOFF_DIR/.grok-$KEY.tmp.XXXXXX") || exit 1
TOKEN=$(basename "$TMP")
{
  printf '%s\n' "$TOKEN"
  printf '%s\n' "$HOOK_PID"
  printf '%s\n' "$HOOK_IDENTITY"
  printf '%s\n' "$SESSION_ID"
  printf '%s\n' "$REASON"
} > "$TMP" || { rm -f "$TMP"; exit 1; }
chmod 600 "$TMP" 2>/dev/null || true
fm_publish_file_no_follow "$TMP" "$PENDING" replace || { rm -f "$TMP"; exit 1; }

DELIVER="$ROOT/bin/fm-turnend-guard-grok-deliver.sh"
[ -x "$DELIVER" ] || exit 1
READY="$PENDING.ready"
DELIVERY_LOG="$HANDOFF_DIR/grok-delivery-$TOKEN.log"
[ ! -e "$DELIVERY_LOG" ] && [ ! -L "$DELIVERY_LOG" ] || exit 1
set -o noclobber
if ! { exec 9>"$DELIVERY_LOG"; } 2>/dev/null; then
  set +o noclobber
  exit 1
fi
set +o noclobber
[ -f "$DELIVERY_LOG" ] && [ ! -L "$DELIVERY_LOG" ] || { exec 9>&-; exit 1; }
nohup "$DELIVER" "$PENDING" "$ROOT" "$TOKEN" "$STATE" </dev/null >&9 2>&1 &
WORKER_PID=$!
exec 9>&-
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
exit 1
