#!/usr/bin/env bash
# Tests for the serialized, lifecycle-aware backlog wrapper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$ROOT/bin/fm-tasks-axi-lib.sh"

BACKLOG="$ROOT/bin/fm-backlog.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog)
TMP_ROOT=$(cd "$(dirname "$TMP_ROOT")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$TMP_ROOT")")

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf 'tasks-axi 0.2.2\n'; exit 0 ;;
  show)
    show_mode=${FM_FAKE_SHOW_MODE:-success}
    if [ -n "${FM_FAKE_SHOW_MODE_FILE:-}" ] && [ -f "$FM_FAKE_SHOW_MODE_FILE" ]; then
      show_mode=$(cat "$FM_FAKE_SHOW_MODE_FILE")
    fi
    case "$show_mode" in
      not_found)
        printf 'error: Task "%s" not found in this backlog\n' "${2:-task-a}"
        printf 'code: NOT_FOUND\n'
        exit 1
        ;;
      operational)
        printf 'error: backend inventory unavailable\n'
        printf 'code: UNKNOWN\n'
        exit 1
        ;;
    esac
    task_state=${FM_FAKE_TASK_STATE:-queued}
    if [ -n "${FM_FAKE_TASK_STATE_FILE:-}" ] && [ -f "$FM_FAKE_TASK_STATE_FILE" ]; then
      task_state=$(cat "$FM_FAKE_TASK_STATE_FILE")
    fi
    printf 'task:\n'
    printf '  id: %s\n' "${2:-task-a}"
    printf '  title: stable task\n'
    printf '  state: %s\n' "$task_state"
    printf '  blocked: %s\n' "${FM_FAKE_BLOCKED:-no}"
    printf '  blocked_by: %s\n' "${FM_FAKE_BLOCKED_BY:-none}"
    printf '  held: %s\n' "${FM_FAKE_HELD:-no}"
    printf '  kind: %s\n' "${FM_FAKE_TASK_KIND:-ship}"
    printf '  body: stable body\n'
    if [ -n "${FM_FAKE_BODY_ACK:-}" ]; then
      printf '  %s\n' "$FM_FAKE_BODY_ACK"
    elif [ -n "${FM_FAKE_DONE_ACK_FILE:-}" ] && [ -f "$FM_FAKE_DONE_ACK_FILE" ]; then
      while IFS= read -r ack_line; do
        printf '  %s\n' "$ack_line"
      done < "$FM_FAKE_DONE_ACK_FILE"
    fi
    printf 'help[1]:\n  - %s\n' "${FM_FAKE_HELP:-inspect ready work}"
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then printf '%s\n' '--archive-body'; exit 0; fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then printf '%s\n' '[<id>...]'; exit 0; fi
    ;;
esac
if [ "${1:-}" = done ] && [ -n "${FM_FAKE_INTERRUPT_MARKER:-}" ]; then
  done_note=
  previous=
  for arg in "$@"; do
    if [ "$previous" = note ]; then
      done_note=$arg
      previous=
      continue
    fi
    [ "$arg" != --note ] || previous=note
  done
  done_ack=$(printf '%s\n' "$done_note" | sed -n '/^fm-done-ack:[0-9a-f][0-9a-f]*$/p' | tail -1)
  if [ -n "${FM_FAKE_DONE_ACK_FILE:-}" ] && [ -n "$done_ack" ]; then
    printf '%s\n' "$done_ack" > "$FM_FAKE_DONE_ACK_FILE"
  fi
  if [ -n "${FM_FAKE_DONE_STATE_FILE:-}" ]; then
    printf 'done\n' > "$FM_FAKE_DONE_STATE_FILE"
  fi
  if [ -n "${FM_FAKE_ARCHIVE_PATH:-}" ]; then
    printf '\n## Archived 2026-07-17\n- [x] %s - stable task (done 2026-07-17)\n' \
      "${2:-task-a}" >> "$FM_FAKE_ARCHIVE_PATH"
    [ -z "$done_ack" ] || printf '  %s\n' "$done_ack" >> "$FM_FAKE_ARCHIVE_PATH"
  fi
  if [ -n "${FM_FAKE_SHOW_MODE_FILE:-}" ] && [ -n "${FM_FAKE_DONE_SHOW_MODE:-}" ]; then
    printf '%s\n' "$FM_FAKE_DONE_SHOW_MODE" > "$FM_FAKE_SHOW_MODE_FILE"
  fi
  : > "$FM_FAKE_INTERRUPT_MARKER"
  sleep 0.5
fi
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
  printf 'pwd=%s home=%s args=%s\n' "$PWD" "$HOME" "$*" >> "$FM_FAKE_ARGS_LOG"
fi
if [ -n "${FM_FAKE_RECEIPT_PATH:-}" ] && [ -n "${FM_FAKE_RECEIPT_STATE_LOG:-}" ]; then
  if [ -e "$FM_FAKE_RECEIPT_PATH" ] || [ -L "$FM_FAKE_RECEIPT_PATH" ]; then
    printf 'present\n' >> "$FM_FAKE_RECEIPT_STATE_LOG"
  else
    printf 'claimed\n' >> "$FM_FAKE_RECEIPT_STATE_LOG"
  fi
fi
if [ -n "${FM_FAKE_MUTATE_BACKLOG_FILE:-}" ]; then
  printf '\nmutation-before-failure\n' >> "$FM_FAKE_MUTATE_BACKLOG_FILE"
fi
if [ -n "${FM_FAKE_MUTATION_WAIT_MARKER:-}" ]; then
  : > "$FM_FAKE_MUTATION_WAIT_MARKER"
  while [ ! -e "${FM_FAKE_MUTATION_WAIT_RELEASE:-}" ]; do
    sleep 0.05
  done
fi
[ "${FM_FAKE_FAIL_MUTATION:-0}" != 1 ] || exit 9
exit 0
SH
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_ENDPOINT_PRESENT:-0}" = 1 ]; then
  printf '%s\n' 'fm-task-a fm-task-a'
  exit 0
fi
printf '%s\n' 'no server running on /tmp/fake' >&2
exit 1
SH
  chmod +x "$home/fakebin/tasks-axi" "$home/fakebin/tmux"
  printf '%s\n' "$home"
}

wait_for_file() {
  local path=$1 seconds=$2 attempts i=0
  attempts=$((seconds * 20))
  while [ "$i" -lt "$attempts" ]; do
    [ ! -e "$path" ] || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

write_completion_proof() {
  local home=$1 id=$2 kind=$3 outcome=$4 record_kind=${5:-$3} done_ack=${6:-0123456789abcdef0123456789abcdef} record checksum
  record=$(printf 'task:\n  id: %s\n  title: stable task\n  state: queued\n  blocked: no\n  blocked_by: none\n  held: no\n  kind: %s\n  body: stable body\n' "$id" "$record_kind")
  checksum=$(printf '%s' "$record" | fm_tasks_axi_task_fingerprint) || fail "could not fingerprint fake task $id"
  {
    printf 'version=2\n'
    printf 'task=%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'outcome=%s\n' "$outcome"
    printf 'record-cksum=%s\n' "$checksum"
    printf 'done-ack=%s\n' "$done_ack"
  } > "$home/state/$id.teardown-complete"
}

write_done_started_stage() {
  local home=$1 id=$2 meta_cksum=$3 record_cksum=$4 done_ack=${5:-0123456789abcdef0123456789abcdef} aux_cksum
  : > "$home/state/$id.teardown-owners"
  aux_cksum=$(cksum < "$home/state/$id.teardown-owners" | awk '{print $1 ":" $2}')
  printf 'version=4\ntask=%s\nmeta-cksum=%s\nphase=backlog-done-started\nowner-identity=absent\nowner-marker=none\nowner-token=none\nforce=0\noutcome=delivered-local\nrecord-cksum=%s\ndone-ack=%s\naux-cksum=%s\n' \
    "$id" "$meta_cksum" "$record_cksum" "$done_ack" "$aux_cksum" > "$home/state/$id.teardown-stage"
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
  rm -f "$home/state/scout-a.tearing-down"
  write_completion_proof "$home" task-a ship delivered-local
  : > "$home/state/task-a.teardown-stage"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" task-a --note local 2>&1) || status=$?
  expect_code 1 "$status" "completion with a durable teardown stage"
  assert_contains "$out" "unresolved owned lifecycle" "teardown stage did not block completion"
  assert_present "$home/state/task-a.teardown-complete" "teardown stage consumed the completion proof"
  assert_absent "$log" "tasks-axi mutation ran despite a durable teardown stage"
  pass "Done cannot be recorded while meta, tombstone, or durable teardown stage remains"
}

test_scout_done_requires_owned_report() {
  local home log out status outside outside_dir inside_dir
  home=$(make_home report)
  log="$home/args.log"
  write_completion_proof "$home" scout-a scout delivered-report
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
  assert_contains "$out" "no regular home-contained report" "missing scout report refusal absent"
  outside="$TMP_ROOT/outside-scout-report.md"
  printf '# Foreign report\n' > "$outside"
  mkdir -p "$home/data/scout-a"
  ln -s "$outside" "$home/data/scout-a/report.md"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md 2>&1) || status=$?
  expect_code 1 "$status" "symlinked scout report"
  assert_contains "$out" "no regular home-contained report" "symlinked scout report escaped home containment"
  rm -rf "$home/data/scout-a"
  outside_dir="$TMP_ROOT/outside-scout-task"
  mkdir -p "$outside_dir"
  printf '# Foreign parent report\n' > "$outside_dir/report.md"
  ln -s "$outside_dir" "$home/data/scout-a"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md 2>&1) || status=$?
  expect_code 1 "$status" "out-of-home scout report parent"
  assert_contains "$out" "no regular home-contained report" "scout report parent escaped home containment"
  rm -f "$home/data/scout-a"
  inside_dir="$home/data/other-task"
  mkdir -p "$inside_dir"
  printf '# Wrong task report\n' > "$inside_dir/report.md"
  ln -s "$inside_dir" "$home/data/scout-a"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md 2>&1) || status=$?
  expect_code 1 "$status" "cross-task scout report parent"
  assert_contains "$out" "no regular home-contained report" "scout report escaped its exact task directory"
  rm -f "$home/data/scout-a"
  mkdir -p "$home/data/scout-a"
  printf '# Report\n' > "$home/data/scout-a/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md
  assert_contains "$(cat "$log")" "args=done scout-a --report data/scout-a/report.md --note fm-done-ack:" \
    "scoped Done call did not reach the owned backlog file"
  assert_contains "$(cat "$log")" "--backend markdown --file $home/data/backlog.md" \
    "scoped Done call escaped the selected home backlog"
  pass "scout completion requires the exact owned report after lifecycle cleanup"
}

test_done_requires_matching_single_use_teardown_proof() {
  local home log out status
  home=$(make_home proof)
  log="$home/args.log"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "never-dispatched Done"
  assert_contains "$out" "no durable successful-teardown proof" "never-dispatched work was not kept outside Done"
  write_completion_proof "$home" task-a ship delivered-local
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    FM_FAKE_BLOCKED=yes FM_FAKE_BLOCKED_BY=dep-a FM_FAKE_HELD=yes FM_FAKE_HELP='changed suggestion' \
    "$BACKLOG" done task-a --note 'local main' 2>&1) || status=$?
  expect_code 1 "$status" "gate-mutated teardown proof"
  assert_contains "$out" "does not match the current backlog record" "gate mutation did not invalidate staged proof"
  assert_present "$home/state/task-a.teardown-complete" "gate mutation consumed the stale proof"
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" FM_FAKE_FAIL_MUTATION=1 \
    "$BACKLOG" done task-a --note 'local main' >/dev/null 2>&1 || status=$?
  expect_code 9 "$status" "backend Done failure"
  assert_present "$home/state/task-a.teardown-complete" "backend failure consumed the retry proof"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" done task-a --note 'local main'
  assert_absent "$home/state/task-a.teardown-complete" "successful Done did not consume its proof"
  write_completion_proof "$home" task-a ship delivered-local
  sed 's/^record-cksum=.*/record-cksum=1:1/' "$home/state/task-a.teardown-complete" \
    > "$home/state/task-a.teardown-complete.tmp"
  mv "$home/state/task-a.teardown-complete.tmp" "$home/state/task-a.teardown-complete"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "stale proof checksum"
  assert_contains "$out" "does not match the current backlog record" "stale proof was accepted for a replacement record"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" rm task-a
  assert_absent "$home/state/task-a.teardown-complete" "successful record removal left a reusable teardown proof"
  pass "Done requires a matching single-use proof and preserves it only for retryable backend failure"
}

test_empty_completion_claim_reconciles_completed_state() {
  local home claim out status ack=0123456789abcdef0123456789abcdef
  home=$(make_home empty-completed-claim)
  claim="$home/state/.task-a.teardown-complete.claimed.empty"
  mkdir "$claim"
  printf '%s\n' "$ack" > "$claim/done-ack"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_STATE=done \
    FM_FAKE_BODY_ACK="fm-done-ack:$ack" \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 0 "$status" "empty completed proof claim recovery"
  assert_contains "$out" "already recorded" "empty completed claim did not reconcile from truthful backlog state"
  assert_absent "$claim" "empty completed proof claim remained stranded"
  pass "empty proof claims reconcile after Done before claim cleanup"
}

test_empty_completion_claim_reconciles_restored_proof() {
  local home claim
  home=$(make_home empty-restored-claim)
  write_completion_proof "$home" task-a ship delivered-local
  claim="$home/state/.task-a.teardown-complete.claimed.empty"
  mkdir "$claim"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a >/dev/null
  assert_absent "$claim" "empty restored proof claim remained stranded"
  assert_absent "$home/state/task-a.teardown-complete" "restored proof was not consumed after claim recovery"
  pass "empty proof claims reconcile after backend failure restores the proof"
}

test_empty_completion_claim_reconciles_exact_finalizing_done() {
  local home claim out status meta_cksum ack=0123456789abcdef0123456789abcdef
  home=$(make_home empty-finalizing-done-claim)
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  : > "$home/state/task-a.tearing-down"
  write_done_started_stage "$home" task-a "$meta_cksum" staged "$ack"
  claim="$home/state/.task-a.teardown-complete.claimed.empty"
  mkdir "$claim"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_STATE=done \
    FM_FAKE_BODY_ACK="fm-done-ack:$ack" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 0 "$status" "empty post-success claim recovery"
  assert_contains "$out" "already recorded" "empty post-success claim did not use exact staged Done acknowledgement"
  assert_absent "$claim" "empty post-success claim remained after exact Done acknowledgement"
  pass "empty post-success claims reconcile through the exact finalizing Done acknowledgement"
}

test_finalizing_stage_allows_guarded_and_idempotent_done() {
  local home out status meta_cksum record_cksum ack=0123456789abcdef0123456789abcdef
  home=$(make_home finalizing-new-done)
  write_completion_proof "$home" task-a ship delivered-local
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  record_cksum=$(sed -n 's/^record-cksum=//p' "$home/state/task-a.teardown-complete")
  : > "$home/state/task-a.tearing-down"
  write_done_started_stage "$home" task-a "$meta_cksum" "$record_cksum"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a >/dev/null
  assert_absent "$home/state/task-a.teardown-complete" "finalizing Done did not consume its receipt"
  home=$(make_home finalizing-idempotent)
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  : > "$home/state/task-a.tearing-down"
  write_done_started_stage "$home" task-a "$meta_cksum" staged
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_STATE=done \
    FM_FAKE_BODY_ACK="fm-done-ack:$ack" \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 0 "$status" "idempotent finalizing Done"
  assert_contains "$out" "already recorded" "finalizing retry did not recognize recorded Done"
  home=$(make_home invalid-finalizing)
  write_completion_proof "$home" task-a ship delivered-local
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  printf 'version=2\ntask=task-a\nmeta-cksum=%s\nrecord-cksum=staged\nphase=finalizing\n' \
    "$meta_cksum" > "$home/state/task-a.teardown-stage"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "invalid finalizing stage"
  assert_contains "$out" "unresolved owned lifecycle" "non-v4 finalizing stage bypassed lifecycle guard"
  home=$(make_home finalizing-live-endpoint)
  write_completion_proof "$home" task-a ship delivered-local
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  record_cksum=$(sed -n 's/^record-cksum=//p' "$home/state/task-a.teardown-complete")
  write_done_started_stage "$home" task-a "$meta_cksum" "$record_cksum"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ENDPOINT_PRESENT=1 \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "finalizing stage with live endpoint"
  assert_contains "$out" "unresolved owned lifecycle" "live endpoint bypassed complete finalization validation"
  pass "only an exact finalizing teardown stage supports guarded idempotent Done"
}

test_completion_recovery_requires_exact_done_ack() {
  local home claim out status meta_cksum current_ack old_ack
  current_ack=0123456789abcdef0123456789abcdef
  old_ack=fedcba9876543210fedcba9876543210

  home=$(make_home finalizing-archive-reuse)
  printf 'window=fm-task-a\n' > "$home/state/task-a.meta"
  meta_cksum=$(cksum < "$home/state/task-a.meta" | awk '{print $1 ":" $2}')
  : > "$home/state/task-a.tearing-down"
  write_done_started_stage "$home" task-a "$meta_cksum" staged "$current_ack"
  printf '\n## Archived 2026-07-17\n- [x] task-a - old task (done 2026-07-17)\n  fm-done-ack:%s\n' \
    "$old_ack" > "$home/data/done-archive.md"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_SHOW_MODE=not_found \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "finalizing retry with reused archived id"
  assert_contains "$out" "no durable successful-teardown proof" \
    "old archived task id bypassed the exact finalization acknowledgement"
  printf '\n- [x] task-a - current task (done 2026-07-17)\n  fm-done-ack:%s\n' \
    "$current_ack" >> "$home/data/done-archive.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_SHOW_MODE=not_found \
    "$BACKLOG" done task-a >/dev/null

  home=$(make_home claim-archive-reuse)
  write_completion_proof "$home" task-a ship delivered-local ship "$current_ack"
  claim="$home/state/.task-a.teardown-complete.claimed.stale"
  mkdir "$claim"
  mv "$home/state/task-a.teardown-complete" "$claim/proof"
  printf '%s\n' "$current_ack" > "$claim/done-ack"
  printf '\n## Archived 2026-07-17\n- [x] task-a - old task (done 2026-07-17)\n  fm-done-ack:%s\n' \
    "$old_ack" > "$home/data/done-archive.md"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_SHOW_MODE=not_found \
    "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "claim recovery with reused archived id"
  assert_contains "$out" "could not determine backlog state" \
    "old archived task id consumed a different claimed teardown receipt"
  assert_present "$claim/proof" "failed exact archive acknowledgement consumed the claimed proof"
  pass "completion retries require the exact teardown acknowledgement in live and archived Done records"
}

test_manual_backend_mutations_stay_serialized_and_receipt_gated() {
  local home log out status
  home=$(make_home manual-completion)
  log="$home/args.log"
  printf 'manual\n' > "$home/config/backlog-backend"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" update task-a --title changed
  assert_contains "$(cat "$log")" "args=update task-a --title changed --backend markdown --file $home/data/backlog.md" \
    "manual routine mutation bypassed the serialized scoped backend"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "manual Done without teardown proof"
  assert_contains "$out" "no durable successful-teardown proof" "manual Done bypassed lifecycle receipt"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" done task-a --note 'local main'
  assert_contains "$(cat "$log")" "args=done task-a --note local main" \
    "manual completion did not pass through the serialized scoped backend"
  assert_contains "$(cat "$log")" "fm-done-ack:0123456789abcdef0123456789abcdef --backend markdown --file $home/data/backlog.md" \
    "manual completion did not preserve its exact teardown acknowledgement"
  assert_absent "$home/state/task-a.teardown-complete" "manual Done did not consume its lifecycle receipt"
  pass "manual mutations use the serialized lifecycle receipt path"
}

test_all_mutation_verbs_and_aliases_invalidate_proofs() {
  local home claim out status args_log receipt_log

  mutation_invalidates() {
    local name=$1
    shift
    home=$(make_home "mutation-$name")
    write_completion_proof "$home" task-a ship delivered-local
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" "$@" >/dev/null
    assert_absent "$home/state/task-a.teardown-complete" "$name left a reusable teardown proof"
  }

  mutation_invalidates block block task-a --by dependency-a
  mutation_invalidates task-unblock task unblock task-a --by dependency-a
  mutation_invalidates create create task-a replacement
  mutation_invalidates task-edit task edit task-a --title replacement
  mutation_invalidates delete delete task-a
  mutation_invalidates unhold unhold task-a
  mutation_invalidates render render
  mutation_invalidates prune prune --keep 10
  mutation_invalidates minted-create create 'minted replacement' --mint

  global_mutation_invalidates_claim() {
    local name=$1
    shift
    home=$(make_home "global-claim-$name")
    write_completion_proof "$home" task-b ship delivered-local
    claim="$home/state/.task-b.teardown-complete.claimed.stale"
    mkdir "$claim"
    mv "$home/state/task-b.teardown-complete" "$claim/proof"
    PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" "$@" >/dev/null
    assert_absent "$claim" "$name left an interrupted completion claim"
  }
  global_mutation_invalidates_claim minted-create create 'minted replacement' --mint
  global_mutation_invalidates_claim render render
  global_mutation_invalidates_claim prune prune --keep 10

  home=$(make_home failed-block)
  write_completion_proof "$home" task-a ship delivered-local
  receipt_log="$home/receipt-state.log"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_FAIL_MUTATION=1 \
    FM_FAKE_RECEIPT_PATH="$home/state/task-a.teardown-complete" \
    FM_FAKE_RECEIPT_STATE_LOG="$receipt_log" \
    "$BACKLOG" block task-a --by dependency-a 2>&1) || status=$?
  expect_code 9 "$status" "failed block mutation"
  assert_contains "$(cat "$receipt_log")" "claimed" "failed mutation reached the backend with live receipt authority"
  assert_present "$home/state/task-a.teardown-complete" "failed mutation invalidated a retryable proof"

  home=$(make_home failed-after-write)
  write_completion_proof "$home" task-a ship delivered-local
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_FAIL_MUTATION=1 \
    FM_FAKE_MUTATE_BACKLOG_FILE="$home/data/backlog.md" \
    "$BACKLOG" block task-a --by dependency-a 2>&1) || status=$?
  expect_code 9 "$status" "failed mutation after backend write"
  assert_absent "$home/state/task-a.teardown-complete" \
    "backend write followed by failure restored stale receipt authority"

  home=$(make_home stale-claimed-delete)
  write_completion_proof "$home" task-a ship delivered-local
  claim="$home/state/.task-a.teardown-complete.claimed.stale"
  mkdir "$claim"
  mv "$home/state/task-a.teardown-complete" "$claim/proof"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" delete task-a >/dev/null
  assert_absent "$claim" "successful delete left an interrupted completion claim"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" create task-a replacement >/dev/null
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "recreated task with stale interrupted claim"
  assert_contains "$out" "no durable successful-teardown proof" \
    "recreated task reused an interrupted claim from the deleted record"

  home=$(make_home unsafe-claim-invalidation)
  write_completion_proof "$home" task-a ship delivered-local
  claim="$home/state/.task-a.teardown-complete.claimed.unsafe"
  mkdir "$claim"
  mv "$home/state/task-a.teardown-complete" "$claim/proof"
  printf 'unexpected\n' > "$claim/extra"
  args_log="$home/args.log"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$args_log" \
    "$BACKLOG" block task-a --by dependency-a 2>&1) || status=$?
  expect_code 1 "$status" "unsafe interrupted claim invalidation"
  assert_contains "$out" "could not be invalidated safely before backlog mutation" \
    "unsafe interrupted claim was not rejected before mutation"
  assert_absent "$args_log" "unsafe interrupted claim reached the mutating backend"
  pass "mutations withdraw receipt authority before write and restore it only without mutation"
}

test_equals_note_completion_is_normalized() {
  local home log
  home=$(make_home equals-note)
  log="$home/args.log"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" done task-a '--note=local main'
  assert_contains "$(cat "$log")" "args=done task-a --note local main" \
    "equals-form completion note was not normalized"
  assert_not_contains "$(cat "$log")" "--note=local main" \
    "equals-form completion note leaked alongside the wrapper acknowledgement"
  assert_contains "$(cat "$log")" "fm-done-ack:0123456789abcdef0123456789abcdef --backend markdown" \
    "equals-form completion note lost its teardown acknowledgement"
  pass "equals and separated completion notes share receipt injection"
}

test_interrupted_completion_claim_reconciles_from_backlog_state() {
  local home marker state_file mode_file archive_file claim out pid status candidate ack_file
  home=$(make_home interrupted-retry)
  marker="$home/done-started"
  ack_file="$home/done-ack"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
    FM_FAKE_DONE_ACK_FILE="$ack_file" \
    "$BACKLOG" done task-a >/dev/null 2>&1 &
  pid=$!
  for _ in {1..100}; do
    [ -f "$marker" ] && break
    sleep 0.01
  done
  [ -f "$marker" ] || fail "interrupted Done did not reach the claimed-proof interval"
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  expect_code 143 "$status" "interrupted Done before backlog mutation"
  assert_present "$home/state/task-a.teardown-complete" "interrupted active task did not recover its retryable proof"
  for candidate in "$home/state"/.task-a.teardown-complete.claimed.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    fail "interrupted active task left a stranded proof claim"
  done
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a >/dev/null
  assert_absent "$home/state/task-a.teardown-complete" "retry after interrupted proof recovery did not consume proof"

  home=$(make_home interrupted-completed)
  marker="$home/done-started"
  ack_file="$home/done-ack"
  state_file="$home/task-state"
  printf 'queued\n' > "$state_file"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
    FM_FAKE_TASK_STATE_FILE="$state_file" FM_FAKE_DONE_STATE_FILE="$state_file" \
    FM_FAKE_DONE_ACK_FILE="$ack_file" \
    "$BACKLOG" done task-a >/dev/null 2>&1 &
  pid=$!
  for _ in {1..100}; do
    [ -f "$marker" ] && break
    sleep 0.01
  done
  [ -f "$marker" ] || fail "completed interrupted Done did not reach the claimed-proof interval"
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  expect_code 143 "$status" "interrupted Done after backlog mutation"
  assert_absent "$home/state/task-a.teardown-complete" "completed interrupted Done restored a consumed proof"
  for candidate in "$home/state"/.task-a.teardown-complete.claimed.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    fail "completed interrupted Done left a stranded proof claim"
  done

  home=$(make_home interrupted-archived)
  marker="$home/done-started"
  ack_file="$home/done-ack"
  mode_file="$home/show-mode"
  archive_file="$home/data/done-archive.md"
  printf 'success\n' > "$mode_file"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
    FM_FAKE_SHOW_MODE_FILE="$mode_file" FM_FAKE_DONE_SHOW_MODE=not_found \
    FM_FAKE_ARCHIVE_PATH="$archive_file" FM_FAKE_DONE_ACK_FILE="$ack_file" \
    "$BACKLOG" done task-a --keep 0 >/dev/null 2>&1 &
  pid=$!
  for _ in {1..100}; do
    [ -f "$marker" ] && break
    sleep 0.01
  done
  [ -f "$marker" ] || fail "archived interrupted Done did not reach the claimed-proof interval"
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  expect_code 143 "$status" "interrupted Done after immediate archival"
  assert_grep '- [x] task-a - ' "$archive_file" "fake Done did not record the canonical archived row"
  assert_absent "$home/state/task-a.teardown-complete" "archived interrupted Done restored a consumed proof"
  for candidate in "$home/state"/.task-a.teardown-complete.claimed.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    fail "archived interrupted Done left a stranded proof claim"
  done

  home=$(make_home interrupted-operational-error)
  mode_file="$home/show-mode"
  archive_file="$home/data/done-archive.md"
  claim="$home/state/.task-a.teardown-complete.claimed.stale"
  printf 'operational\n' > "$mode_file"
  printf '\n## Archived 2026-07-17\n- [x] task-a - stable task (done 2026-07-17)\n' > "$archive_file"
  write_completion_proof "$home" task-a ship delivered-local
  mkdir "$claim"
  mv "$home/state/task-a.teardown-complete" "$claim/proof"
  printf '%s\n' 0123456789abcdef0123456789abcdef > "$claim/done-ack"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_SHOW_MODE_FILE="$mode_file" \
    "$BACKLOG" done task-a --keep 0 2>&1) || status=$?
  expect_code 1 "$status" "claim recovery after operational show failure"
  assert_contains "$out" "could not determine backlog state" \
    "operational show failure did not fail claim recovery closed"
  assert_present "$claim" "operational show failure consumed a claim from archive evidence"
  pass "interrupted proof claims reconcile active, retained Done, and archived Done state"
}

test_default_tasks_kind_matches_legacy_ship_lifecycle() {
  local home
  home=$(make_home default-kind)
  write_completion_proof "$home" legacy-a ship delivered-local task
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=task \
    "$BACKLOG" done legacy-a --note 'local main'
  assert_absent "$home/state/legacy-a.teardown-complete" "default tasks kind did not normalize to ship"
  pass "default tasks kind remains compatible with legacy Firstmate ship tasks"
}

test_done_rejects_noncanonical_id_before_proof_access() {
  local home outside out status
  home=$(make_home invalid-id)
  outside="$home/task-a.teardown-complete"
  printf 'must remain unread\n' > "$outside"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done ../task-a 2>&1) || status=$?
  expect_code 2 "$status" "traversal-shaped completion id"
  assert_contains "$out" "invalid task id" "completion did not reject a noncanonical id"
  assert_present "$outside" "completion accessed a proof path before validating the id"
  pass "Done validates canonical task ids before proof and report path access"
}

test_completion_and_move_aliases_cannot_bypass_guards() {
  local home log out status form
  home=$(make_home aliases)
  log="$home/args.log"
  printf 'window=default:w1:p1\nkind=ship\n' > "$home/state/task-a.meta"
  for form in close 'task done' 'task close'; do
    status=0
    read -r -a words <<< "$form"
    out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
      "$BACKLOG" "${words[@]}" task-a 2>&1) || status=$?
    expect_code 1 "$status" "$form lifecycle guard"
    assert_contains "$out" "unresolved owned lifecycle" "$form bypassed lifecycle refusal"
  done
  assert_absent "$log" "completion alias reached tasks-axi despite unresolved lifecycle"
  for form in mv 'task mv'; do
    status=0
    read -r -a words <<< "$form"
    out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
      "$BACKLOG" "${words[@]}" task-a --to elsewhere 2>&1) || status=$?
    expect_code 2 "$status" "$form handoff refusal"
    assert_contains "$out" "fm-backlog-handoff.sh" "$form did not name the guarded handoff"
  done
  pass "completion and move aliases share the guarded lifecycle grammar"
}

test_tasks_axi_is_scoped_to_selected_home() {
  local home hostile log
  home=$(make_home scoped-home)
  hostile="$TMP_ROOT/hostile-caller"
  log="$home/args.log"
  mkdir -p "$hostile/.tasks-axi" "$hostile/data"
  cat > "$hostile/.tasks.toml" <<'EOF'
backend = "sqlite"
[markdown]
archive = "/tmp/foreign-done-archive.md"
done_keep = 1
EOF
  cat > "$hostile/.tasks-axi/config.toml" <<'EOF'
backend = "sqlite"
[markdown]
archive = "/tmp/global-done-archive.md"
EOF
  (
    cd "$hostile" || exit 1
    PATH="$home/fakebin:$PATH" HOME="$hostile" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
      "$BACKLOG" update task-a --title safe
  )
  assert_contains "$(cat "$log")" "pwd=$home home=$home" "tasks-axi inherited caller cwd or HOME"
  assert_contains "$(cat "$log")" "--backend markdown --file $home/data/backlog.md" "tasks-axi lost explicit backend/file scoping"
  assert_not_contains "$(cat "$log")" "$hostile" "hostile caller configuration reached tasks-axi"
  pass "tasks-axi config and archive resolution stay inside the selected FM_HOME"
}

test_help_does_not_require_home_configuration() {
  local home missing out status
  missing="$TMP_ROOT/help-missing-home"
  status=0
  out=$(FM_HOME="$missing" "$BACKLOG" --help 2>&1) || status=$?
  expect_code 0 "$status" "help without FM_HOME configuration"
  assert_contains "$out" "Usage: fm-backlog.sh" "help output was not available before home validation"
  home=$(make_home done-help)
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "Done help without a task id"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" update --help >/dev/null
  assert_present "$home/state/task-a.teardown-complete" "verb-scoped help consumed a completion receipt"
  if compgen -G "$home/state/.backlog-receipts.claimed.*" >/dev/null; then
    fail "verb-scoped help left a mutation receipt claim"
  fi
  pass "wrapper and verb-scoped help preserve lifecycle receipts"
}

test_interrupted_mutation_receipt_claims_reconcile_from_files() {
  local home marker release wrapper_pid status
  home=$(make_home interrupted-mutation-claim-unchanged)
  marker="$home/backend-started"
  release="$home/backend-release"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_FAKE_MUTATION_WAIT_MARKER="$marker" FM_FAKE_MUTATION_WAIT_RELEASE="$release" \
    "$BACKLOG" block task-a --by dependency-a >/dev/null 2>&1 &
  wrapper_pid=$!
  wait_for_file "$marker" 5 || fail "unchanged mutation never reached the backend"
  kill -KILL "$wrapper_pid"
  status=0
  wait "$wrapper_pid" 2>/dev/null || status=$?
  expect_code 137 "$status" "interrupted unchanged mutation"
  : > "$release"
  sleep 0.2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" show task-a >/dev/null
  assert_present "$home/state/task-a.teardown-complete" \
    "unchanged interrupted mutation did not restore its receipt"
  if compgen -G "$home/state/.backlog-receipts.claimed.*" >/dev/null; then
    fail "unchanged interrupted mutation left an orphan receipt claim"
  fi

  home=$(make_home interrupted-mutation-claim-changed)
  marker="$home/backend-started"
  release="$home/backend-release"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_FAKE_MUTATE_BACKLOG_FILE="$home/data/backlog.md" \
    FM_FAKE_MUTATION_WAIT_MARKER="$marker" FM_FAKE_MUTATION_WAIT_RELEASE="$release" \
    "$BACKLOG" block task-a --by dependency-a >/dev/null 2>&1 &
  wrapper_pid=$!
  wait_for_file "$marker" 5 || fail "changed mutation never reached the backend"
  kill -KILL "$wrapper_pid"
  status=0
  wait "$wrapper_pid" 2>/dev/null || status=$?
  expect_code 137 "$status" "interrupted changed mutation"
  : > "$release"
  sleep 0.2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" show task-a >/dev/null
  assert_absent "$home/state/task-a.teardown-complete" \
    "changed interrupted mutation restored stale receipt authority"
  if compgen -G "$home/state/.backlog-receipts.claimed.*" >/dev/null; then
    fail "changed interrupted mutation left an orphan receipt claim"
  fi
  pass "interrupted mutation claims reconcile from durable before and current file state"
}

test_documented_overrides_remain_compatible() {
  local home state data config log
  home=$(make_home overrides)
  state="$TMP_ROOT/override-state"
  data="$TMP_ROOT/override-data"
  config="$TMP_ROOT/override-config"
  log="$home/args.log"
  mkdir -p "$state" "$data" "$config"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$data/backlog.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" update task-a --title safe
  assert_contains "$(cat "$log")" "pwd=$home home=$home" "override-backed call lost canonical cwd or HOME"
  assert_contains "$(cat "$log")" "--file $data/backlog.md" "FM_DATA_OVERRIDE was not preserved"
  pass "state, data, and config overrides remain compatible with contained tasks-axi execution"
}

test_backlog_and_archive_symlink_escapes_are_rejected() {
  local home outside out status
  home=$(make_home symlink-escapes)
  outside="$TMP_ROOT/outside-backlog.md"
  printf '## Queued\n' > "$outside"
  rm -f "$home/data/backlog.md"
  ln -s "$outside" "$home/data/backlog.md"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" ready 2>&1) || status=$?
  expect_code 1 "$status" "symlink backlog escape"
  assert_contains "$out" "backlog must not be a symlink" "symlink backlog was not rejected"
  rm -f "$home/data/backlog.md"
  printf '## Queued\n' > "$home/data/backlog.md"
  ln -s "$outside" "$home/data/done-archive.md"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" ready 2>&1) || status=$?
  expect_code 1 "$status" "symlink archive escape"
  assert_contains "$out" "markdown.archive must not be a symlink" "symlink archive was not rejected"
  pass "backlog and archive symlink escapes are rejected"
}

test_duplicate_markdown_archive_is_rejected() {
  local home outside out status
  home=$(make_home duplicate-archive)
  outside="$TMP_ROOT/outside-archive.md"
  cat >> "$home/.tasks.toml" <<EOF

archive = '$outside' # later tasks-axi override
EOF
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" ready 2>&1) || status=$?
  expect_code 1 "$status" "duplicate markdown.archive"
  assert_contains "$out" "markdown.archive exactly once (found 2)" "later archive override was not rejected"
  assert_absent "$outside" "duplicate archive override escaped FM_HOME"
  pass "duplicate markdown.archive assignments cannot bypass home containment"
}

test_real_tasks_axi_preserves_done_ack_with_multiline_note() {
  local home task_info checksum note shown archive claim out status ack
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "SKIP (tasks-axi unavailable): real Done acknowledgement format"
    return
  fi
  home=$(make_home real-done-ack)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] task-a - stable task (kind: ship)
  stable body

## Done
EOF
  task_info=$(cd "$home" && HOME="$home" tasks-axi show task-a --full \
    --backend markdown --file "$home/data/backlog.md") || fail "real tasks-axi could not read the completion fixture"
  checksum=$(printf '%s' "$task_info" | fm_tasks_axi_task_fingerprint) \
    || fail "real tasks-axi completion fixture could not be fingerprinted"
  ack=0123456789abcdef0123456789abcdef
  {
    printf 'version=2\n'
    printf 'task=task-a\n'
    printf 'kind=ship\n'
    printf 'outcome=delivered-local\n'
    printf 'record-cksum=%s\n' "$checksum"
    printf 'done-ack=%s\n' "$ack"
  } > "$home/state/task-a.teardown-complete"
  note=$'captain note line one\ncaptain note line two'
  FM_HOME="$home" "$BACKLOG" done task-a --note "$note" --no-prune >/dev/null
  shown=$(cd "$home" && HOME="$home" tasks-axi show task-a --full \
    --backend markdown --file "$home/data/backlog.md") || fail "real Done record was not retained for full inspection"
  assert_contains "$shown" "captain note line one" "real Done dropped the first user note line"
  assert_contains "$shown" "captain note line two" "real Done dropped the second user note line"
  assert_contains "$shown" "fm-done-ack:$ack" "real Done dropped the reserved acknowledgement line"
  FM_HOME="$home" "$BACKLOG" prune --keep 0 >/dev/null
  archive=$(cat "$home/data/done-archive.md")
  assert_contains "$archive" "  captain note line one" "real archive dropped the first user note line"
  assert_contains "$archive" "  captain note line two" "real archive dropped the second user note line"
  assert_contains "$archive" "  fm-done-ack:$ack" "real archive did not retain the parser's exact acknowledgement form"
  claim="$home/state/.task-a.teardown-complete.claimed.archived"
  mkdir "$claim"
  printf '%s\n' "$ack" > "$claim/done-ack"
  status=0
  out=$(FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 0 "$status" "real archived Done acknowledgement recovery"
  assert_contains "$out" "already recorded" "real archive format did not satisfy exact acknowledgement recovery"
  assert_absent "$claim" "real archive acknowledgement left its recovery claim"
  pass "real tasks-axi preserves multiline Done notes and exact acknowledgements through archival"
}

test_same_file_mutations_are_serialized
test_done_refuses_unresolved_meta
test_scout_done_requires_owned_report
test_done_requires_matching_single_use_teardown_proof
test_all_mutation_verbs_and_aliases_invalidate_proofs
test_equals_note_completion_is_normalized
test_interrupted_completion_claim_reconciles_from_backlog_state
test_empty_completion_claim_reconciles_completed_state
test_empty_completion_claim_reconciles_restored_proof
test_empty_completion_claim_reconciles_exact_finalizing_done
test_manual_backend_mutations_stay_serialized_and_receipt_gated
test_finalizing_stage_allows_guarded_and_idempotent_done
test_completion_recovery_requires_exact_done_ack
test_default_tasks_kind_matches_legacy_ship_lifecycle
test_done_rejects_noncanonical_id_before_proof_access
test_completion_and_move_aliases_cannot_bypass_guards
test_tasks_axi_is_scoped_to_selected_home
test_help_does_not_require_home_configuration
test_interrupted_mutation_receipt_claims_reconcile_from_files
test_documented_overrides_remain_compatible
test_backlog_and_archive_symlink_escapes_are_rejected
test_duplicate_markdown_archive_is_rejected
test_real_tasks_axi_preserves_done_ack_with_multiline_note
