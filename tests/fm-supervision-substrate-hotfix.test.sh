#!/usr/bin/env bash
# End-to-end regression for the 2026-07-18 supervision substrate incident.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SUPERVISION_HOTFIX_TEST_INNER:-0}" != 1 ]; then
  if command -v timeout >/dev/null 2>&1; then
    exec timeout 90 env FM_SUPERVISION_HOTFIX_TEST_INNER=1 bash "$0" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout 90 env FM_SUPERVISION_HOTFIX_TEST_INNER=1 bash "$0" "$@"
  else
    exec perl -e '
      my $seconds = shift;
      my $pid = fork;
      die "fork failed\n" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec failed: $!\n"; }
      local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124; };
      alarm $seconds;
      waitpid $pid, 0;
      exit($? >> 8);
    ' 90 env FM_SUPERVISION_HOTFIX_TEST_INNER=1 bash "$0" "$@"
  fi
fi

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-/Users/cal/firstmate/bin/fm-herdr-lab.sh}
TMP_ROOT=$(fm_test_tmproot fm-supervision-substrate-hotfix)
PRIMARY="$TMP_ROOT/primary"
CREW_WT="$TMP_ROOT/crew-worktree"
FAKEBIN="$TMP_ROOT/fakebin"
LAB_SESSION=${FM_HERDR_LAB_SESSION:-}
LAB_OWNED=0
LAB_WORKSPACE=
CHECKPOINT_PID=
ARM_PID=
FAILURES=0

cleanup() {
  if [ -n "$ARM_PID" ] && kill -0 "$ARM_PID" 2>/dev/null; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  if [ -n "$CHECKPOINT_PID" ] && kill -0 "$CHECKPOINT_PID" 2>/dev/null; then
    kill -TERM "$CHECKPOINT_PID" 2>/dev/null || true
    wait "$CHECKPOINT_PID" 2>/dev/null || true
  fi
  if [ -n "$LAB_WORKSPACE" ]; then
    "$HERDR_LAB_HELPER" run "$LAB_SESSION" workspace close "$LAB_WORKSPACE" >/dev/null 2>&1 || true
  fi
  if [ "$LAB_OWNED" -eq 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_later() {
  printf 'not ok - %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

wait_for_file() {
  local path=$1 attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

run_state_probe() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 "$@"
  else
    perl -e '
      my $seconds = shift;
      my $pid = fork;
      die "fork failed\n" unless defined $pid;
      if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec failed: $!\n"; }
      local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124; };
      alarm $seconds;
      waitpid $pid, 0;
      exit($? >> 8);
    ' 5 "$@"
  fi
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not found"; exit 0; }

if [ -z "$LAB_SESSION" ]; then
  LAB_SESSION=$("$HERDR_LAB_HELPER" name supervision-substrate-hotfix-r4) || fail "could not name Herdr lab session"
  LAB_OWNED=1
  "$HERDR_LAB_HELPER" provision "$LAB_SESSION" || fail "could not provision Herdr lab session"
fi

mkdir -p "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/docs" "$CREW_WT" "$FAKEBIN"
cp -R "$ROOT/bin" "$PRIMARY/bin"
cp -R "$ROOT/docs/supervision-protocols" "$PRIMARY/docs/supervision-protocols"
cp "$ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
git init -q "$PRIMARY"
git -C "$PRIMARY" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init
git init -q "$CREW_WT"
git -C "$CREW_WT" checkout -qb fm/live-idle
git -C "$CREW_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
helper=${HERDR_LAB_HELPER:?}
session=${FM_HERDR_LAB_SESSION:?}
real_path=${FM_REAL_PATH:?}
[ -z "${FM_FAKE_HERDR_DELAY:-}" ] || sleep "$FM_FAKE_HERDR_DELAY"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) shift 2 ;;
    --session=*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="$real_path" exec "$helper" run "$session" "${args[@]}"
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/herdr"

workspace_json=$("$HERDR_LAB_HELPER" run "$LAB_SESSION" workspace create \
  --cwd "$CREW_WT" --label "supervision-hotfix-$$" --no-focus) || fail "could not create live Herdr workspace"
LAB_WORKSPACE=$(printf '%s' "$workspace_json" | jq -r '.result.workspace.workspace_id // empty')
LAB_PANE=$(printf '%s' "$workspace_json" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$LAB_WORKSPACE" ] && [ -n "$LAB_PANE" ] || fail "live Herdr workspace response lacked identities"
"$HERDR_LAB_HELPER" run "$LAB_SESSION" pane report-agent "$LAB_PANE" \
  --source supervision-hotfix-regression --agent codex --state idle --message 'regression idle' >/dev/null \
  || fail "could not report live Herdr idle state"

cat > "$PRIMARY/state/incident.meta" <<EOF
window=$LAB_SESSION:$LAB_PANE
worktree=$CREW_WT
kind=ship
backend=herdr
EOF
printf 'working: stale status from the completed turn\n' > "$PRIMARY/state/incident.status"

crew_rc=0
crew_state=$(run_state_probe env PATH="$FAKEBIN:$PATH" FM_REAL_PATH="$PATH" \
  HERDR_LAB_HELPER="$HERDR_LAB_HELPER" FM_HERDR_LAB_SESSION="$LAB_SESSION" \
  FM_CREW_STATE_BACKEND_TIMEOUT=1 FM_HOME="$PRIMARY" \
  "$PRIMARY/bin/fm-crew-state.sh" incident) || crew_rc=$?
case "$crew_state" in
  'state: idle'*'source: pane'*'status-log working superseded'*)
    pass "live Herdr idle supersedes stale working status history"
    ;;
  *)
    fail_later "live Herdr idle was masked by stale working history (rc=$crew_rc): $crew_state"
    ;;
esac

slow_rc=0
slow_state=$(run_state_probe env PATH="$FAKEBIN:$PATH" FM_REAL_PATH="$PATH" \
  HERDR_LAB_HELPER="$HERDR_LAB_HELPER" FM_HERDR_LAB_SESSION="$LAB_SESSION" \
  FM_FAKE_HERDR_DELAY=3 FM_CREW_STATE_BACKEND_TIMEOUT=1 FM_HOME="$PRIMARY" \
  "$PRIMARY/bin/fm-crew-state.sh" incident) || slow_rc=$?
case "$slow_state" in
  'state: unknown'*'source: none'*'backend current state unavailable'*)
    pass "bounded Herdr state-probe failure returns unknown"
    ;;
  *)
    fail_later "Herdr state probe did not fail closed within its bound (rc=$slow_rc): $slow_state"
    ;;
esac

rm -f "$PRIMARY/state/incident.meta" "$PRIMARY/state/incident.status"
: > "$PRIMARY/state/checkpoint.meta"
checkpoint_out="$TMP_ROOT/checkpoint.out"
checkpoint_err="$TMP_ROOT/checkpoint.err"
FM_HOME="$PRIMARY" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  "$PRIMARY/bin/fm-watch-checkpoint.sh" --seconds 20 >"$checkpoint_out" 2>"$checkpoint_err" &
CHECKPOINT_PID=$!
wait_for_file "$PRIMARY/state/.watch.lock/pid" || fail "foreground checkpoint never acquired the watcher lock"
wait_for_file "$PRIMARY/state/.last-watcher-beat" || fail "foreground checkpoint never wrote a fresh beacon"

guard_out="$TMP_ROOT/guard-checkpoint.out"
guard_rc=0
printf '{"stop_hook_active":false}' | FM_HOME="$PRIMARY" \
  "$PRIMARY/bin/fm-turnend-guard.sh" >"$guard_out" 2>&1 || guard_rc=$?
if [ "$guard_rc" -eq 2 ]; then
  pass "turn end refuses a live foreground checkpoint with non-durable ownership"
else
  fail_later "turn end accepted live foreground checkpoint ownership (rc=$guard_rc): $(cat "$guard_out")"
fi

printf 'done: real checkpoint signal exit\n' > "$PRIMARY/state/checkpoint-signal.status"
wait "$CHECKPOINT_PID" || fail "foreground checkpoint did not return cleanly on its real signal"
CHECKPOINT_PID=
assert_contains "$(cat "$checkpoint_out")" "signal:" "checkpoint did not report its real signal exit"
touch "$PRIMARY/state/.last-watcher-beat"

guard_rc=0
printf '{"stop_hook_active":true}' | FM_HOME="$PRIMARY" \
  "$PRIMARY/bin/fm-turnend-guard.sh" >"$guard_out" 2>&1 || guard_rc=$?
if [ "$guard_rc" -eq 2 ]; then
  pass "turn end remains refused after signal exit with a fresh beacon and queued wake"
else
  fail_later "turn end accepted the post-signal fresh beacon before wake drain (rc=$guard_rc): $(cat "$guard_out")"
fi

FM_HOME="$PRIMARY" "$PRIMARY/bin/fm-wake-drain.sh" >/dev/null
arm_out="$TMP_ROOT/arm.out"
FM_HOME="$PRIMARY" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
  "$PRIMARY/bin/fm-watch-arm.sh" >"$arm_out" 2>&1 &
ARM_PID=$!
wait_for_file "$PRIMARY/state/.watch.lock/pid" || fail "durable arm never acquired the watcher lock"
guard_rc=0
printf '{"stop_hook_active":true}' | FM_HOME="$PRIMARY" \
  "$PRIMARY/bin/fm-turnend-guard.sh" >"$guard_out" 2>&1 || guard_rc=$?
if [ "$guard_rc" -eq 0 ]; then
  pass "turn end is allowed only after wake drain and durable watcher restoration"
else
  fail_later "turn end stayed blocked after wake drain and durable watcher restoration (rc=$guard_rc): $(cat "$guard_out")"
fi

[ "$FAILURES" -eq 0 ] || exit 1
echo "all supervision substrate hotfix tests passed"
