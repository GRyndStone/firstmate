#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod +x "$home/state/env-check.check.sh"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for the foreground fm-watch.sh"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_interrupted_checkpoint_reaps_only_its_watcher() {
  local home out err checkpoint_pid watcher_pid unrelated i status
  home=$(make_home interrupted)
  out="$home/out.txt"
  err="$home/err.txt"
  sleep 30 &
  unrelated=$!
  FM_HOME="$home" FM_POLL=10 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 30 >"$out" 2>"$err" &
  checkpoint_pid=$!
  watcher_pid=
  i=0
  while [ "$i" -lt 100 ]; do
    watcher_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher_pid" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "$watcher_pid" ] || fail "interrupted checkpoint never recorded its watcher child"
  [ "$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')" = "$checkpoint_pid" ] \
    || fail "watcher $watcher_pid was not the checkpoint's direct child"
  [ "$(cat "$home/state/.watch.lock/owner-kind" 2>/dev/null || true)" = checkpoint ] \
    || fail "checkpoint watcher did not record foreground ownership provenance"
  [ "$(cat "$home/state/.watch.lock/owner-pid" 2>/dev/null || true)" = "$checkpoint_pid" ] \
    || fail "checkpoint watcher ownership did not name the checkpoint process"
  [ -s "$home/state/.watch.lock/owner-identity" ] \
    || fail "checkpoint watcher ownership omitted the checkpoint process identity"

  kill -TERM "$checkpoint_pid"
  status=0
  wait "$checkpoint_pid" || status=$?
  expect_code 143 "$status" "interrupted checkpoint exit"
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "watcher child $watcher_pid survived its interrupted checkpoint"
  fi
  assert_absent "$home/state/.watch.lock/pid" "interrupted checkpoint left a watcher lock"
  kill -0 "$unrelated" 2>/dev/null || fail "checkpoint cleanup killed an unrelated process"
  kill -TERM "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "interrupted checkpoint reaps only its exact watcher child instead of orphaning it"
}

test_timeout_marks_then_kills_only_term_resistant_watcher() {
  local home out err watcher pid_file order_file unrelated status started elapsed watcher_pid
  home=$(make_home resistant-timeout)
  out="$home/out.txt"
  err="$home/err.txt"
  watcher="$home/term-resistant-watch.sh"
  pid_file="$home/watcher.pid"
  order_file="$home/term-order"
  cat > "$watcher" <<'SH'
#!/usr/bin/env bash
trap 'if [ -e "${FM_WATCH_CHECKPOINT_TIMEOUT_MARKER:-}" ]; then printf "marker-before-term\n" > "$WATCH_ORDER_FILE"; else printf "term-before-marker\n" > "$WATCH_ORDER_FILE"; fi' TERM
printf '%s\n' "$$" > "$WATCH_PID_FILE"
while :; do sleep 0.1; done
SH
  chmod +x "$watcher"
  sleep 30 &
  unrelated=$!
  started=$SECONDS
  status=0
  WATCH_PID_FILE="$pid_file" WATCH_ORDER_FILE="$order_file" FM_WATCH_CHECKPOINT_WATCHER="$watcher" \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  elapsed=$((SECONDS - started))
  expect_code 124 "$status" "TERM-resistant timeout exit"
  [ "$(cat "$order_file" 2>/dev/null || true)" = marker-before-term ] \
    || fail "timeout signaled the watcher before publishing its timeout marker"
  watcher_pid=$(cat "$pid_file" 2>/dev/null || true)
  [ -n "$watcher_pid" ] || fail "TERM-resistant watcher did not record its pid"
  if kill -0 "$watcher_pid" 2>/dev/null; then
    fail "TERM-resistant watcher $watcher_pid survived bounded KILL escalation"
  fi
  [ "$elapsed" -lt 10 ] || fail "TERM-resistant timeout was not bounded (${elapsed}s)"
  kill -0 "$unrelated" 2>/dev/null || fail "timeout escalation killed an unrelated process"
  kill -TERM "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  pass "timeout marks before TERM, escalates exact watcher to KILL, and reaps it"
}

test_timeout_revalidates_watcher_birth_identity_before_escalation() {
  local home out err watcher fakebin flip identity_log status
  home=$(make_home identity-recheck)
  out="$home/out.txt"
  err="$home/err.txt"
  watcher="$home/identity-changing-watch.sh"
  fakebin="$home/fakebin"
  flip="$home/identity-flipped"
  identity_log="$home/identity.log"
  mkdir -p "$fakebin"
  cat > "$watcher" <<'SH'
#!/usr/bin/env bash
trap ': > "$WATCH_IDENTITY_FLIP"' TERM
while :; do sleep 0.1; done
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" -o lstart= "* ]] && [ -e "$WATCH_IDENTITY_FLIP" ]; then
  printf 'birth-identity-probed\n' >> "$WATCH_IDENTITY_LOG"
fi
exec /bin/ps "$@"
SH
  chmod +x "$watcher" "$fakebin/ps"
  status=0
  PATH="$fakebin:$PATH" WATCH_IDENTITY_FLIP="$flip" WATCH_IDENTITY_LOG="$identity_log" \
    FM_WATCH_CHECKPOINT_WATCHER="$watcher" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "identity-changing timeout exit"
  assert_contains "$(cat "$identity_log" 2>/dev/null || true)" "birth-identity-probed" \
    "timeout escalation did not revalidate watcher birth identity after TERM"
  pass "timeout escalation revalidates stable watcher birth identity before every later signal"
}

test_checkpoint_polls_process_identity_coarsely() {
  local home out err fakebin probe_log status probe_count
  home=$(make_home coarse-identity-poll)
  out="$home/out.txt"
  err="$home/err.txt"
  fakebin="$home/fakebin"
  probe_log="$home/identity-probes.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" -o lstart= "* ]]; then
  printf 'probe\n' >> "$WATCH_IDENTITY_PROBE_LOG"
fi
exec /bin/ps "$@"
SH
  chmod +x "$fakebin/ps"
  status=0
  PATH="$fakebin:$PATH" WATCH_IDENTITY_PROBE_LOG="$probe_log" FM_HOME="$home" \
    FM_POLL=10 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 2 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "coarse identity polling checkpoint"
  probe_count=$(wc -l < "$probe_log" | tr -d '[:space:]')
  [ "$probe_count" -le 12 ] \
    || fail "checkpoint hot-polled process identity $probe_count times during two seconds"
  pass "checkpoint polls process identity coarsely outside signal-time revalidation"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_interrupted_checkpoint_reaps_only_its_watcher
test_timeout_marks_then_kills_only_term_resistant_watcher
test_timeout_revalidates_watcher_birth_identity_before_escalation
test_checkpoint_polls_process_identity_coarsely
