#!/usr/bin/env bash
# Behavior tests for bin/fm-gsd-run.sh, the visible-herdr-tab launcher for GSD
# driving runs (the drive-gsd visibility contract's launch-mechanics owner).
# Hermetic: uses a small stateless fake `herdr` CLI (canned JSON answers, one
# log line per invocation, mirroring tests/fm-backend-herdr.test.sh's
# fakebin/command-log convention) plus real jq, never a real herdr server.
# Covers: argument validation (not-a-gsd-command refusal, bad flag, bad id),
# fail-closed behavior when herdr is missing, the --no-wait launch path (tab
# labeled gsd-<id>-r<stamp>, never fm-*; pane command cd's into the project,
# runs via env, records the exit code), per-invocation label/exit-file
# uniqueness for same-second runs, relative FM_GSD_RUN_STATE_DIR resolution,
# exit-code propagation through the default wait, and the wait-side aborts
# that all share the reserved exit code 96: the dead-pane abort (including
# honoring an exit code recorded in the instant the tab closed), the loud
# wait-abandon after consecutive unreadable pane states, and the mid-wait
# server-restart abort when status --json exposes a server identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

fm_test_tmproot TMP_ROOT fm-gsd-run
mkdir -p "$TMP_ROOT"

# make_gsd_fake_herdr: a stateless fake `herdr` answering exactly the calls
# fm-gsd-run.sh's flow makes - status, workspace list (one pre-existing
# "firstmate" workspace, so the adopted-workspace path runs and no seeded tab
# is ever pruned), tab list (empty), tab create (fixed ids), pane run
# (silent), pane get / agent get (a live shell pane with no agent, i.e. a
# running non-agent command - or pane_not_found when FM_FAKE_PANE_GONE=1, or
# an unparseable-state error when FM_FAKE_PANE_UNKNOWN=1). When both
# FM_FAKE_PANE_GONE=1 and FM_FAKE_DEAD_EXIT are set, the gone answer first
# records that exit code to the run's exit file (label read back from the
# tab-create line it already logged), reproducing a run that finished in the
# same instant its tab closed. With FM_FAKE_SERVER_RESTART=1, status --json
# reports a server pid of 111 until the first `pane get` has been logged
# (i.e. until the wait loop starts polling) and 222 afterwards, reproducing
# a server restart between launch and the wait; otherwise status exposes no
# pid/start-time, matching the verified real build. Responses stay canned
# JSON; every invocation logs one unit-separated line to $FM_HERDR_LOG.
make_gsd_fake_herdr() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-} ${2:-}" in
  "status --json")
    if [ "${FM_FAKE_SERVER_RESTART:-0}" = 1 ]; then
      if grep -q $'\x1fpane\x1fget' "$LOG" 2>/dev/null; then pid=222; else pid=111; fi
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true,"pid":%s}}\n' "$pid"
    else
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    fi
    ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  "tab list")
    if [ "${FM_FAKE_TAB_CREATE_UNPARSEABLE:-0}" = 1 ] && grep -q $'\x1ftab\x1fcreate' "$LOG" 2>/dev/null; then
      # Include a sibling tab so last-tab-safe rollback can close the created run tab
      # without deleting the whole workspace (real herdr closes the workspace when the
      # last tab goes away).
      printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","workspace_id":"w1"},{"tab_id":"w1:t9","label":"%s","workspace_id":"w1"}]}}\n' "$(tr '\037' '\n' < "$LOG" | sed -n '/^gsd-/p' | head -1)"
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  "tab create")
    if [ "${FM_FAKE_TAB_CREATE_UNPARSEABLE:-0}" = 1 ]; then
      printf '{"result":{}}\n'
    else
      printf '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}\n'
    fi
    ;;
  "pane get")
    if [ "${FM_FAKE_PANE_GONE:-0}" = 1 ]; then
      if [ -n "${FM_FAKE_DEAD_EXIT:-}" ]; then
        label=$(tr '\037' '\n' < "$LOG" | sed -n '/^gsd-/p' | head -1)
        [ -n "$label" ] && printf '%s\n' "$FM_FAKE_DEAD_EXIT" > "${FM_GSD_RUN_STATE_DIR:?}/$label.exit"
      fi
      printf '{"error":{"code":"pane_not_found"}}\n'
    elif [ "${FM_FAKE_PANE_UNKNOWN:-0}" = 1 ]; then
      printf '{"error":{"code":"internal_error"}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    fi
    ;;
  "agent get") printf '{"error":{"code":"agent_not_found"}}\n' ;;
  "pane run") [ "${FM_FAKE_PANE_RUN_FAIL:-0}" = 1 ] && exit 23 ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

test_script_parses_and_help() {
  local help
  bash -n "$ROOT/bin/fm-gsd-run.sh" 2>&1 || fail "bin/fm-gsd-run.sh fails bash -n"
  help=$("$ROOT/bin/fm-gsd-run.sh" --help)
  assert_contains "$help" "VISIBLE herdr tab" "fm-gsd-run.sh --help lost the visibility statement"
  assert_contains "$help" "--no-wait" "fm-gsd-run.sh --help omitted --no-wait"
  assert_contains "$help" "Exit code 96 is RESERVED" "fm-gsd-run.sh --help lost the reserved wait-abort exit code"
  pass "fm-gsd-run.sh: bash -n succeeds and --help renders the header"
}

test_argument_validation() {
  local out status
  out=$("$ROOT/bin/fm-gsd-run.sh" only-id 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "too few arguments must exit 2"
  assert_contains "$out" "usage:" "too-few-arguments error lost its usage hint"

  out=$("$ROOT/bin/fm-gsd-run.sh" task-a1 "$TMP_ROOT" rm -rf / 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a non-gsd command must be refused"
  assert_contains "$out" "must be a gsd invocation" "non-gsd refusal lost its message"

  out=$("$ROOT/bin/fm-gsd-run.sh" --frobnicate task-a1 "$TMP_ROOT" gsd headless status 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an unknown flag must exit 2"

  out=$("$ROOT/bin/fm-gsd-run.sh" 'bad id' "$TMP_ROOT" gsd headless status 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a non-slug task id must be refused"

  out=$("$ROOT/bin/fm-gsd-run.sh" task-a1 "$TMP_ROOT/does-not-exist" gsd headless status 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a missing gsd project dir must be refused"
  pass "fm-gsd-run.sh: argument validation refuses misuse"
}

# Leading NAME=value assignments are allowed before gsd (an operating guide's
# PATH/model setup) and still count as a gsd invocation.
test_env_assignments_allowed_before_gsd() {
  local dir fb log out status
  dir="$TMP_ROOT/env-ok"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-e1 "$TMP_ROOT" PATH=/opt/gsd/bin gsd headless status 2>&1 ) && status=0 || status=$?
  expect_code 0 "$status" "NAME=value before gsd should be accepted"
  assert_contains "$out" "tab=gsd-task-e1-r" "env-assignment launch lost its run line"
  assert_grep "env 'PATH=/opt/gsd/bin' 'gsd' 'headless' 'status'" "$log" \
    "pane command lost the quoted env assignment"
  pass "fm-gsd-run.sh: leading NAME=value assignments precede gsd cleanly"
}

# Without herdr on PATH the helper fails loudly instead of running the
# command invisibly - the caller reports blocked rather than driving raw.
test_missing_herdr_fails_closed() {
  local out status tmpdir
  tmpdir="$TMP_ROOT/missing-herdr-tmp"
  mkdir -p "$tmpdir"
  out=$( /usr/bin/env -u FM_GSD_RUN_STATE_DIR PATH="/usr/bin:/bin" TMPDIR="$tmpdir" \
    "$ROOT/bin/fm-gsd-run.sh" task-h1 "$TMP_ROOT" gsd headless auto 2>&1 ) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "missing herdr must fail, not run invisibly"
  assert_contains "$out" "herdr" "missing-herdr failure does not name herdr"
  [ -z "$(find "$tmpdir" -maxdepth 1 -type d -name 'fm-gsd-run-task-h1.*' -print -quit)" ] \
    || fail "missing-herdr preflight left fm-gsd-run-task-h1.* under isolated TMPDIR"
  pass "fm-gsd-run.sh: missing herdr fails closed"
}

test_state_setup_failure_closes_created_tab() {
  local dir fb log proj state_file out status
  dir="$TMP_ROOT/state-failure"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  state_file="$dir/not-a-directory"; : > "$state_file"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$state_file" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-f1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "state-directory setup failure must fail the launch"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t9' \
    "state-directory setup failure left the created herdr tab open"
  pass "fm-gsd-run.sh: state setup failure closes the created run tab"
}

test_post_create_failure_closes_created_tab() {
  local dir fb log proj out status
  dir="$TMP_ROOT/post-create-failure"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_TAB_CREATE_UNPARSEABLE=1 \
    FM_GSD_RUN_STATE_DIR="$dir/state" "$ROOT/bin/fm-gsd-run.sh" --no-wait task-c1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "post-create parsing failure must fail the launch"
  assert_contains "$out" "could not parse tab/pane id" "post-create failure lost its parsing error"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t9' \
    "post-create failure leaked the created herdr tab"
  assert_absent "$dir/state" "post-create failure created exit state before readiness"
  pass "fm-gsd-run.sh: post-create failures roll back the created run tab"
}

test_ambiguous_send_failure_preserves_tab_and_state() {
  local dir fb log proj state_root out status
  dir="$TMP_ROOT/ambiguous-send"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  state_root="$dir/run-state"
  mkdir -p "$state_root"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" TMPDIR="$state_root" \
    FM_FAKE_PANE_RUN_FAIL=1 /usr/bin/env -u FM_GSD_RUN_STATE_DIR \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-a2 "$proj" gsd headless auto 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "an ambiguous pane-run failure must fail the launch"
  assert_contains "$out" "launch outcome is ambiguous" "ambiguous launch failure lost its warning"
  ! grep -q $'\x1f''tab'$'\x1f''close' "$log" || fail "ambiguous launch failure closed the run tab"
  [ -n "$(find "$state_root" -maxdepth 1 -type d -name 'fm-gsd-run-task-a2.*' -print -quit)" ] \
    || fail "ambiguous launch failure deleted its exit-state directory"
  pass "fm-gsd-run.sh: ambiguous send failure preserves tab and exit state"
}

test_no_wait_launches_visible_tab() {
  local dir fb log proj proj_real state_real out status
  dir="$TMP_ROOT/no-wait"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  proj_real=$(cd "$proj" && pwd -P)
  mkdir -p "$dir/state"
  state_real=$(cd "$dir/state" && pwd -P)
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-n1 "$proj" gsd headless auto --timeout 3600 2>&1 ) && status=0 || status=$?
  expect_code 0 "$status" "--no-wait launch should exit 0"
  assert_contains "$out" "tab=gsd-task-n1-r" "run line lost the gsd-<id>-r<epoch> tab label"
  assert_contains "$out" "target=default:w1:p9" "run line lost the pane target"
  assert_contains "$out" "exit_file=$state_real/gsd-task-n1-r" "run line lost the exit-file path"
  assert_contains "$out" "not waiting" "--no-wait lost its poll hint"
  assert_not_contains "$out" "tab=fm-" "run tab must never squat the fm-* task-tab namespace"
  assert_grep "--label" "$log" "tab create lost its --label flag"
  assert_grep "gsd-task-n1-r" "$log" "tab create lost the run-tab label"
  assert_grep "--no-focus" "$log" "tab create lost --no-focus"
  # The pane command: cd into the (physically resolved) project dir, run via
  # env, record the exit code.
  assert_grep "cd '$proj_real' && env 'gsd' 'headless' 'auto' '--timeout' '3600'; echo \$? > '$state_real/" "$log" \
    "pane run lost the cd+env+exit-record command shape"
  pass "fm-gsd-run.sh: --no-wait opens the visible run tab and returns"
}

# Two runs for the same task id launched within the same second must not
# share a tab label or exit file - a collision would let create_task classify
# the first run's pane as a husk and close it under the live run.
test_same_second_runs_get_unique_labels() {
  local dir fb log proj out1 out2 file1 file2
  dir="$TMP_ROOT/unique"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out1=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-u1 "$proj" gsd headless auto 2>&1 ) || fail "first same-second launch failed"
  out2=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-u1 "$proj" gsd headless auto 2>&1 ) || fail "second same-second launch failed"
  file1=$(printf '%s\n' "$out1" | sed -n 's/.*exit_file=//p' | head -1)
  file2=$(printf '%s\n' "$out2" | sed -n 's/.*exit_file=//p' | head -1)
  [ -n "$file1" ] && [ -n "$file2" ] || fail "same-second launches lost their exit_file lines"
  [ "$file1" != "$file2" ] || fail "same-second runs for one task id shared an exit file: $file1"
  pass "fm-gsd-run.sh: same-second runs get unique labels and exit files"
}

# Default mode waits for the run's exit file and exits with the run's own
# exit code - a drop-in replacement for running the command directly.
test_wait_propagates_exit_code() {
  local dir fb log proj out_file exit_file status
  dir="$TMP_ROOT/wait"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out_file="$dir/out"
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" FM_GSD_RUN_POLL=1 \
    "$ROOT/bin/fm-gsd-run.sh" task-w1 "$proj" gsd headless auto > "$out_file" 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do
    grep -q 'exit_file=' "$out_file" 2>/dev/null && break
    sleep 0.2
  done
  exit_file=$(sed -n 's/.*exit_file=//p' "$out_file" | head -1)
  [ -n "$exit_file" ] || { kill "$pid" 2>/dev/null; fail "wait run never printed its exit_file line"; }
  echo 7 > "$exit_file"
  wait "$pid" && status=0 || status=$?
  expect_code 7 "$status" "wait mode must propagate the run's exit code"
  assert_grep "run finished: exit=7" "$out_file" "wait mode lost its completion line"
  pass "fm-gsd-run.sh: default wait propagates the run's exit code"
}

# A run tab closed underneath a wait (pane_not_found before any exit file)
# aborts loudly instead of polling forever.
test_wait_aborts_on_dead_pane() {
  local dir fb log proj out status
  dir="$TMP_ROOT/dead"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    FM_GSD_RUN_POLL=1 FM_FAKE_PANE_GONE=1 \
    "$ROOT/bin/fm-gsd-run.sh" task-d1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  expect_code 96 "$status" "a dead run pane must abort the wait with the reserved code 96"
  assert_contains "$out" "closed before the run recorded an exit code" "dead-pane abort lost its message"
  pass "fm-gsd-run.sh: a dead run pane aborts the wait loudly"
}

# A run that records its exit code in the same instant its tab closes (exit
# file written between the loop's file check and the dead pane read) must
# have that code honored, not be misreported as closed-without-exit-code.
test_dead_pane_honors_just_recorded_exit_code() {
  local dir fb log proj out status
  dir="$TMP_ROOT/dead-race"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  mkdir -p "$dir/state"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    FM_GSD_RUN_POLL=1 FM_FAKE_PANE_GONE=1 FM_FAKE_DEAD_EXIT=5 \
    "$ROOT/bin/fm-gsd-run.sh" task-d2 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  expect_code 5 "$status" "a dead pane with a just-recorded exit code must propagate that code"
  assert_contains "$out" "run finished: exit=5" "dead-race path lost the completion line"
  assert_not_contains "$out" "closed before the run recorded an exit code" \
    "dead-race path must not report a missing exit code"
  pass "fm-gsd-run.sh: a dead pane still honors a just-recorded exit code"
}

# When the pane state is unreadable poll after poll (e.g. the herdr server
# died under the wait), the helper abandons the WAIT loudly after the
# configured streak instead of polling forever - without touching the run.
test_wait_abandons_after_unknown_streak() {
  local dir fb log proj out status
  dir="$TMP_ROOT/unknown"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    FM_GSD_RUN_POLL=0 FM_FAKE_PANE_UNKNOWN=1 FM_GSD_RUN_UNKNOWN_LIMIT=3 \
    "$ROOT/bin/fm-gsd-run.sh" task-k1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  expect_code 96 "$status" "an unknown-state streak must abandon the wait with the reserved code 96"
  assert_contains "$out" "abandoning the WAIT after 3 consecutive unreadable pane states" \
    "unknown-streak abort lost its message"
  assert_contains "$out" "may still be live" "unknown-streak abort must say the run was not touched"
  ! grep -q "pane.close" "$log" || fail "abandoning the wait must never close the pane"
  pass "fm-gsd-run.sh: an unreadable-state streak abandons only the wait, loudly"
}

# A relative FM_GSD_RUN_STATE_DIR must be resolved to an absolute path at
# launch - the pane command cd's into the project before writing the exit
# file, so a verbatim relative path would split the write and the poll into
# two different directories (and pollute the external project).
test_relative_state_dir_resolved_absolute() {
  local dir fb log proj state_real out status exit_file
  dir="$TMP_ROOT/relative"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  mkdir -p "$dir/rel-state"
  state_real=$(cd "$dir/rel-state" && pwd -P)
  out=$( cd "$dir" && PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="rel-state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-r1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  expect_code 0 "$status" "a relative FM_GSD_RUN_STATE_DIR launch should still exit 0"
  exit_file=$(printf '%s\n' "$out" | sed -n 's/.*exit_file=//p' | head -1)
  [ -n "$exit_file" ] || fail "relative-state-dir launch lost its exit_file line"
  case "$exit_file" in
    /*) : ;;
    *) fail "a relative FM_GSD_RUN_STATE_DIR must be resolved absolute, got: $exit_file" ;;
  esac
  assert_contains "$exit_file" "$state_real/" "resolved exit file left the relative state dir"
  assert_grep "echo \$? > '$state_real/" "$log" "pane command must record to the absolute exit-file path"
  pass "fm-gsd-run.sh: a relative state dir resolves to one absolute exit-file path"
}

# A herdr server restart mid-wait (identity changed between launch and a
# poll) means the run's process died with the server and the exit file can
# never appear: the wait must abort loudly with the reserved code, without
# touching the pane.
test_wait_aborts_on_server_restart() {
  local dir fb log proj out status
  dir="$TMP_ROOT/restart"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    FM_GSD_RUN_POLL=0 FM_FAKE_SERVER_RESTART=1 \
    "$ROOT/bin/fm-gsd-run.sh" task-s1 "$proj" gsd headless auto 2>&1 ) && status=0 || status=$?
  expect_code 96 "$status" "a mid-wait server restart must abort the wait with the reserved code 96"
  assert_contains "$out" "restarted mid-wait (identity 111 -> 222)" "server-restart abort lost its identity message"
  assert_contains "$out" "pane was NOT touched" "server-restart abort must say the pane was not touched"
  ! grep -q "pane.close" "$log" || fail "the server-restart abort must never close the pane"
  pass "fm-gsd-run.sh: a mid-wait server restart abandons only the wait, loudly"
}

test_script_parses_and_help
test_argument_validation
test_env_assignments_allowed_before_gsd
test_missing_herdr_fails_closed
test_state_setup_failure_closes_created_tab
test_post_create_failure_closes_created_tab
test_ambiguous_send_failure_preserves_tab_and_state
test_no_wait_launches_visible_tab
test_same_second_runs_get_unique_labels
test_wait_propagates_exit_code
test_relative_state_dir_resolved_absolute
test_wait_aborts_on_dead_pane
test_dead_pane_honors_just_recorded_exit_code
test_wait_abandons_after_unknown_streak
test_wait_aborts_on_server_restart
