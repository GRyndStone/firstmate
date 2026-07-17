#!/usr/bin/env bash
# Tests for the serialized, lifecycle-aware backlog wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKLOG="$ROOT/bin/fm-backlog.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'tasks-axi 0.2.2\n'; exit 0 ;;
  show) printf 'task:\n  kind: %s\n' "${FM_FAKE_TASK_KIND:-ship}"; exit 0 ;;
  update)
    if [ "${2:-}" = --help ]; then printf '%s\n' '--archive-body'; exit 0; fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then printf '%s\n' '[<id>...]'; exit 0; fi
    ;;
esac
if [ -n "${FM_FAKE_MUTATION_LOG:-}" ]; then
  if ! mkdir "$FM_FAKE_CRITICAL" 2>/dev/null; then
    printf 'overlap %s\n' "$$" >> "$FM_FAKE_MUTATION_LOG"
  fi
  printf 'start %s %s\n' "$$" "${1:-}" >> "$FM_FAKE_MUTATION_LOG"
  sleep 0.2
  printf 'end %s %s\n' "$$" "${1:-}" >> "$FM_FAKE_MUTATION_LOG"
  rmdir "$FM_FAKE_CRITICAL" 2>/dev/null || true
fi
if [ -n "${FM_FAKE_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_ARGS_LOG"
fi
exit 0
SH
  chmod +x "$home/fakebin/tasks-axi"
  printf '%s\n' "$home"
}

test_same_file_mutations_are_serialized() {
  local home log critical status_a status_b
  home=$(make_home serialized)
  log="$home/mutations.log"
  critical="$home/critical"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_MUTATION_LOG="$log" FM_FAKE_CRITICAL="$critical" \
    "$BACKLOG" update task-a --title one &
  pid_a=$!
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_MUTATION_LOG="$log" FM_FAKE_CRITICAL="$critical" \
    "$BACKLOG" hold task-a --reason waiting --kind captain &
  pid_b=$!
  status_a=0
  wait "$pid_a" || status_a=$?
  status_b=0
  wait "$pid_b" || status_b=$?
  expect_code 0 "$status_a" "serialized update"
  expect_code 0 "$status_b" "serialized hold"
  assert_not_contains "$(cat "$log")" "overlap" "update and hold overlapped one backlog critical section"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 4 ] || fail "expected two complete serialized mutations"
  awk '
    $1 == "start" { depth++; if (depth > 1) exit 1 }
    $1 == "end" { depth-- }
    END { if (depth != 0) exit 1 }
  ' "$log" || fail "mutation start/end order was not serialized: $(cat "$log")"
  pass "same-home update and hold mutations are serialized against one backlog file"
}

test_done_refuses_unresolved_meta() {
  local home log out status
  home=$(make_home unresolved)
  log="$home/args.log"
  printf 'window=default:w1:p1\nkind=scout\n' > "$home/state/scout-a.meta"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md 2>&1) || status=$?
  expect_code 1 "$status" "unresolved completion"
  assert_contains "$out" "unresolved owned lifecycle" "completion refusal did not name lifecycle state"
  assert_absent "$log" "tasks-axi mutation ran despite unresolved meta"
  rm -f "$home/state/scout-a.meta"
  : > "$home/state/scout-a.tearing-down"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --note local 2>&1) || status=$?
  expect_code 1 "$status" "completion during teardown"
  assert_contains "$out" "unresolved owned lifecycle" "teardown tombstone did not block completion"
  assert_absent "$log" "tasks-axi mutation ran despite teardown tombstone"
  pass "Done cannot be recorded while owned task meta or teardown state remains"
}

test_scout_done_requires_owned_report() {
  local home log out status
  home=$(make_home report)
  log="$home/args.log"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --note superseded 2>&1) || status=$?
  expect_code 1 "$status" "scout completion without report argument"
  assert_contains "$out" "requires --report" "report-less scout completion was not refused"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/other/report.md 2>&1) || status=$?
  expect_code 1 "$status" "scout completion with foreign report path"
  assert_contains "$out" "must use data/scout-a/report.md" "foreign report path was not refused"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md 2>&1) || status=$?
  expect_code 1 "$status" "missing scout report"
  assert_contains "$out" "has no report" "missing scout report refusal absent"
  mkdir -p "$home/data/scout-a"
  printf '# Report\n' > "$home/data/scout-a/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md
  assert_contains "$(cat "$log")" "done scout-a --report data/scout-a/report.md --file $home/data/backlog.md" \
    "scoped Done call did not reach the owned backlog file"
  pass "scout completion requires the exact owned report after lifecycle cleanup"
}

test_same_file_mutations_are_serialized
test_done_refuses_unresolved_meta
test_scout_done_requires_owned_report
