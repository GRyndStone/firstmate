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
# uniqueness for same-second runs, exit-code propagation through the default
# wait, the dead-pane abort during a wait (including honoring an exit code
# recorded in the instant the tab closed), and the loud wait-abandon after
# consecutive unreadable pane states.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-gsd-run)
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
# same instant its tab closed. Responses stay canned JSON; every invocation
# logs one unit-separated line to $FM_HERDR_LOG.
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
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  "tab list") printf '{"result":{"tabs":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}\n' ;;
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
  local out status
  out=$( PATH="/usr/bin:/bin" "$ROOT/bin/fm-gsd-run.sh" task-h1 "$TMP_ROOT" gsd headless auto 2>&1 ) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "missing herdr must fail, not run invisibly"
  assert_contains "$out" "herdr" "missing-herdr failure does not name herdr"
  pass "fm-gsd-run.sh: missing herdr fails closed"
}

test_no_wait_launches_visible_tab() {
  local dir fb log proj proj_real out status
  dir="$TMP_ROOT/no-wait"
  fb=$(make_gsd_fake_herdr "$dir")
  log="$dir/calls.log"; : > "$log"
  proj="$dir/gsd-proj"; mkdir -p "$proj"
  proj_real=$(cd "$proj" && pwd -P)
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_GSD_RUN_STATE_DIR="$dir/state" \
    "$ROOT/bin/fm-gsd-run.sh" --no-wait task-n1 "$proj" gsd headless auto --timeout 3600 2>&1 ) && status=0 || status=$?
  expect_code 0 "$status" "--no-wait launch should exit 0"
  assert_contains "$out" "tab=gsd-task-n1-r" "run line lost the gsd-<id>-r<epoch> tab label"
  assert_contains "$out" "target=default:w1:p9" "run line lost the pane target"
  assert_contains "$out" "exit_file=$dir/state/gsd-task-n1-r" "run line lost the exit-file path"
  assert_contains "$out" "not waiting" "--no-wait lost its poll hint"
  assert_not_contains "$out" "tab=fm-" "run tab must never squat the fm-* task-tab namespace"
  assert_grep "--label" "$log" "tab create lost its --label flag"
  assert_grep "gsd-task-n1-r" "$log" "tab create lost the run-tab label"
  assert_grep "--no-focus" "$log" "tab create lost --no-focus"
  # The pane command: cd into the (physically resolved) project dir, run via
  # env, record the exit code.
  assert_grep "cd '$proj_real' && env 'gsd' 'headless' 'auto' '--timeout' '3600'; echo \$? > '$dir/state/" "$log" \
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
  expect_code 1 "$status" "a dead run pane must abort the wait with exit 1"
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
  expect_code 1 "$status" "an unknown-state streak must abandon the wait with exit 1"
  assert_contains "$out" "abandoning the WAIT after 3 consecutive unreadable pane states" \
    "unknown-streak abort lost its message"
  assert_contains "$out" "may still be live" "unknown-streak abort must say the run was not touched"
  ! grep -q "pane.close" "$log" || fail "abandoning the wait must never close the pane"
  pass "fm-gsd-run.sh: an unreadable-state streak abandons only the wait, loudly"
}

test_script_parses_and_help
test_argument_validation
test_env_assignments_allowed_before_gsd
test_missing_herdr_fails_closed
test_no_wait_launches_visible_tab
test_same_second_runs_get_unique_labels
test_wait_propagates_exit_code
test_wait_aborts_on_dead_pane
test_dead_pane_honors_just_recorded_exit_code
test_wait_abandons_after_unknown_streak
