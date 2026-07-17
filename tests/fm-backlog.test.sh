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
  if [ -n "${FM_FAKE_DONE_STATE_FILE:-}" ]; then
    printf 'done\n' > "$FM_FAKE_DONE_STATE_FILE"
  fi
  if [ -n "${FM_FAKE_ARCHIVE_PATH:-}" ]; then
    printf '\n## Archived 2026-07-17\n- [x] %s - stable task (done 2026-07-17)\n' \
      "${2:-task-a}" >> "$FM_FAKE_ARCHIVE_PATH"
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
[ "${FM_FAKE_FAIL_MUTATION:-0}" != 1 ] || exit 9
exit 0
SH
  chmod +x "$home/fakebin/tasks-axi"
  printf '%s\n' "$home"
}

write_completion_proof() {
  local home=$1 id=$2 kind=$3 outcome=$4 record_kind=${5:-$3} record checksum
  record=$(printf 'task:\n  id: %s\n  title: stable task\n  state: queued\n  blocked: no\n  blocked_by: none\n  held: no\n  kind: %s\n  body: stable body\n' "$id" "$record_kind")
  checksum=$(printf '%s' "$record" | fm_tasks_axi_task_fingerprint) || fail "could not fingerprint fake task $id"
  {
    printf 'version=1\n'
    printf 'task=%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'outcome=%s\n' "$outcome"
    printf 'record-cksum=%s\n' "$checksum"
  } > "$home/state/$id.teardown-complete"
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
  assert_contains "$out" "has no report" "missing scout report refusal absent"
  mkdir -p "$home/data/scout-a"
  printf '# Report\n' > "$home/data/scout-a/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_TASK_KIND=scout FM_FAKE_ARGS_LOG="$log" \
    "$BACKLOG" "done" scout-a --report data/scout-a/report.md
  assert_contains "$(cat "$log")" "args=done scout-a --report data/scout-a/report.md --backend markdown --file $home/data/backlog.md" \
    "scoped Done call did not reach the owned backlog file"
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
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" FM_FAKE_FAIL_MUTATION=1 \
    FM_FAKE_BLOCKED=yes FM_FAKE_BLOCKED_BY=dep-a FM_FAKE_HELD=yes FM_FAKE_HELP='changed suggestion' \
    "$BACKLOG" done task-a --note 'local main' >/dev/null 2>&1 || status=$?
  expect_code 9 "$status" "backend Done failure"
  assert_present "$home/state/task-a.teardown-complete" "backend failure consumed the retry proof"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_ARGS_LOG="$log" \
    FM_FAKE_BLOCKED=yes FM_FAKE_BLOCKED_BY=dep-a FM_FAKE_HELD=yes FM_FAKE_HELP='another suggestion' \
    "$BACKLOG" done task-a --note 'local main'
  assert_absent "$home/state/task-a.teardown-complete" "successful Done did not consume its proof"
  write_completion_proof "$home" task-a ship delivered-local
  printf 'record changed after teardown\n' >> "$home/state/task-a.teardown-complete"
  printf 'record-cksum=1:1\n' >> "$home/state/task-a.teardown-complete"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" done task-a 2>&1) || status=$?
  expect_code 1 "$status" "stale proof checksum"
  assert_contains "$out" "does not match the current backlog record" "stale proof was accepted for a replacement record"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" rm task-a
  assert_absent "$home/state/task-a.teardown-complete" "successful record removal left a reusable teardown proof"
  pass "Done requires a matching single-use proof and preserves it only for retryable backend failure"
}

test_all_mutation_verbs_and_aliases_invalidate_proofs() {
  local home claim out status

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
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_FAIL_MUTATION=1 \
    "$BACKLOG" block task-a --by dependency-a 2>&1) || status=$?
  expect_code 9 "$status" "failed block mutation"
  assert_present "$home/state/task-a.teardown-complete" "failed mutation invalidated a retryable proof"

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
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BACKLOG" block task-a --by dependency-a 2>&1) || status=$?
  expect_code 1 "$status" "unsafe interrupted claim invalidation"
  assert_contains "$out" "could not be invalidated safely" \
    "unsafe interrupted claim invalidation did not report the partial post-mutation state"
  pass "all successful mutation verbs and aliases invalidate affected teardown proofs"
}

test_interrupted_completion_claim_reconciles_from_backlog_state() {
  local home marker state_file mode_file archive_file claim out pid status candidate
  home=$(make_home interrupted-retry)
  marker="$home/done-started"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
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
  state_file="$home/task-state"
  printf 'queued\n' > "$state_file"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
    FM_FAKE_TASK_STATE_FILE="$state_file" FM_FAKE_DONE_STATE_FILE="$state_file" \
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
  mode_file="$home/show-mode"
  archive_file="$home/data/done-archive.md"
  printf 'success\n' > "$mode_file"
  write_completion_proof "$home" task-a ship delivered-local
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_INTERRUPT_MARKER="$marker" \
    FM_FAKE_SHOW_MODE_FILE="$mode_file" FM_FAKE_DONE_SHOW_MODE=not_found \
    FM_FAKE_ARCHIVE_PATH="$archive_file" \
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
  pass "wrapper and Done help succeed without lifecycle arguments"
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

test_same_file_mutations_are_serialized
test_done_refuses_unresolved_meta
test_scout_done_requires_owned_report
test_done_requires_matching_single_use_teardown_proof
test_all_mutation_verbs_and_aliases_invalidate_proofs
test_interrupted_completion_claim_reconciles_from_backlog_state
test_default_tasks_kind_matches_legacy_ship_lifecycle
test_done_rejects_noncanonical_id_before_proof_access
test_completion_and_move_aliases_cannot_bypass_guards
test_tasks_axi_is_scoped_to_selected_home
test_help_does_not_require_home_configuration
test_documented_overrides_remain_compatible
test_backlog_and_archive_symlink_escapes_are_rejected
test_duplicate_markdown_archive_is_rejected
