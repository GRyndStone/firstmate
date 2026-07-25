#!/usr/bin/env bash
# Tests for task worktree ownership: spawn records the actual treehouse lease,
# teardown refuses a clean-but-wrong recorded worktree, and existing metas can
# be audited without flagging detached worktrees merely for being detached.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
AUDIT="$ROOT/bin/fm-worktree-audit.sh"
fm_git_identity fmtest fmtest@example.invalid
fm_test_tmproot TMP_ROOT fm-worktree-ownership

write_fake_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  list-windows) exit 0 ;;
  new-window) printf '%s\n' '@fixture-window'; exit 0 ;;
  set-window-option) exit 0 ;;
  kill-window) exit 0 ;;
  display-message)
    fmt=
    for arg in "$@"; do fmt=$arg; done
    case "$fmt" in
      '#{pane_current_path}')
        count=0
        [ -f "${FM_FAKE_TMUX_CWD_COUNT:?}" ] && count=$(cat "$FM_FAKE_TMUX_CWD_COUNT")
        count=$((count + 1))
        printf '%s\n' "$count" > "$FM_FAKE_TMUX_CWD_COUNT"
        if [ "$count" -eq 1 ]; then
          printf '%s\n' "${FM_FAKE_WRONG_WT:?}"
        else
          printf '%s\n' "${FM_FAKE_REAL_WT:?}"
        fi
        exit 0
        ;;
      '#{pane_id}') printf '%s\n' '%fixture-pane'; exit 0 ;;
      '#S') printf '%s\n' 'firstmate'; exit 0 ;;
    esac
    exit 0
    ;;
  send-keys)
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
    case "$*" in
      *"--lease-holder "*)
        holder=$(printf '%s\n' "$*" | sed -n "s/.*--lease-holder '\([^']*\)'.*/\1/p")
        [ -n "$holder" ] && printf '%s\n' "$holder" > "${FM_FAKE_HOLDER_FILE:?}"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

write_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get)
    printf '%s\n' "${FM_FAKE_REAL_WT:?}"
    exit 0
    ;;
  status)
    holder=${FM_FAKE_HOLDER:-}
    [ -f "${FM_FAKE_HOLDER_FILE:-/nonexistent}" ] && holder=$(cat "$FM_FAKE_HOLDER_FILE")
    printf '4     available    %s\n' "${FM_FAKE_WRONG_WT:?}"
    printf '8     leased       %s  (held by %s)\n' "${FM_FAKE_REAL_WT:?}" "${holder:?}"
    exit 0
    ;;
  return)
    printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_RETURN_LOG:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

write_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
}

make_project_case() {
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/data/$id" "$case_dir/config" "$fakebin"
  printf '# fixture brief\n\n## Acceptance\n- AC-1: fixture criterion for %s\n' "$id" > "$case_dir/data/$id/brief.md"
  fm_write_criteria "$case_dir/data" "$id" "$case_dir/data/$id/brief.md"
  printf '%s\n' '- project [direct-PR] - Fixture project (added 2026-07-25)' > "$case_dir/data/projects.md"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/README.md"
  git -C "$case_dir/_seed" add README.md
  git -C "$case_dir/_seed" commit -q -m "base"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wrong" main
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/real" main

  write_fake_tmux "$fakebin"
  write_fake_treehouse "$fakebin"
  write_fake_gh "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_spawn_fixture() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_BACKEND=tmux \
  FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_WRONG_WT="$case_dir/wrong" \
  FM_FAKE_REAL_WT="$case_dir/real" \
  FM_FAKE_HOLDER="$id-" \
  FM_FAKE_HOLDER_FILE="$case_dir/holder" \
  FM_FAKE_TMUX_CWD_COUNT="$case_dir/cwd-count" \
  FM_FAKE_TMUX_LOG="$case_dir/tmux.log" \
  FM_FAKE_TREEHOUSE_RETURN_LOG="$case_dir/treehouse-return.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" codex
}

write_task_meta() {
  local case_dir=$1 id=$2 wt=$3
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "generation=fixturegen" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "provider=codex" \
    "harness=codex" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off" \
    "tasktmp=$case_dir/tmp-$id" \
    "model=default" \
    "effort=default"
}

run_teardown_fixture() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_FAKE_WRONG_WT="$case_dir/wrong" \
  FM_FAKE_REAL_WT="$case_dir/real" \
  FM_FAKE_HOLDER="$id-fixturegen" \
  FM_FAKE_HOLDER_FILE="$case_dir/holder" \
  FM_FAKE_TMUX_CWD_COUNT="$case_dir/cwd-count" \
  FM_FAKE_TMUX_LOG="$case_dir/tmux.log" \
  FM_FAKE_TREEHOUSE_RETURN_LOG="$case_dir/treehouse-return.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id"
}

run_audit_fixture() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_FAKE_WRONG_WT="$case_dir/wrong" \
  FM_FAKE_REAL_WT="$case_dir/real" \
  FM_FAKE_HOLDER="diverged-b2-fixturegen" \
  FM_FAKE_HOLDER_FILE="$case_dir/holder" \
  PATH="$case_dir/fakebin:$PATH" \
    "$AUDIT"
}

test_spawn_records_treehouse_holder_under_pool_turnover() {
  local id case_dir out rc recorded real
  id='diverge-task-x1'
  case_dir=$(make_project_case spawn-turnover "$id")
  rm -f "$case_dir/cwd-count"

  set +e
  out=$(run_spawn_fixture "$case_dir" "$id" 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "spawn-turnover: spawn should succeed after pane reaches real lease"
  recorded=$(sed -n 's/^worktree=//p' "$case_dir/state/$id.meta")
  real=$(cd "$case_dir/real" && pwd -P)
  [ "$recorded" = "$real" ] \
    || fail "spawn-turnover: meta recorded '$recorded', but holder lease and launched cwd were '$real'. output: $out"
  pass "spawn records the treehouse holder path after simulated concurrent pool turnover"
}

test_teardown_refuses_clean_wrong_recorded_worktree() {
  local id case_dir rc out
  id='teardown-mismatch-y2'
  case_dir=$(make_project_case teardown-mismatch "$id")
  printf 'real dirty work\n' > "$case_dir/real/uncommitted.txt"
  write_task_meta "$case_dir" "$id" "$case_dir/wrong"

  set +e
  out=$(run_teardown_fixture "$case_dir" "$id" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown-mismatch: teardown passed using a clean wrong worktree"
  assert_contains "$out" "MISMATCH: task $id" "teardown mismatch refusal must name the task"
  assert_contains "$out" "$case_dir/real" "teardown mismatch refusal must name the real task branch worktree"
  [ -f "$case_dir/state/$id.meta" ] || fail "teardown-mismatch: refused teardown must preserve metadata"
  pass "teardown refuses when recorded worktree is clean but the task branch is elsewhere"
}

test_teardown_allows_recorded_task_branch() {
  local id case_dir rc out
  id='teardown-healthy-z3'
  case_dir=$(make_project_case teardown-healthy "$id")
  write_task_meta "$case_dir" "$id" "$case_dir/real"

  set +e
  run_teardown_fixture "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown-healthy: teardown should succeed for recorded task branch"
  [ ! -f "$case_dir/state/$id.meta" ] || fail "teardown-healthy: meta should be removed after successful teardown"
  grep -F "teardown $id complete" "$case_dir/stdout" >/dev/null \
    || fail "teardown-healthy: success output did not name completed teardown"
  pass "teardown still allows a recorded worktree that holds the task branch"
}

test_existing_meta_audit_reports_only_proven_mismatch() {
  local case_dir diverged healthy detached out rc
  diverged='diverged-b2'
  healthy='healthy-a1'
  detached='detached-ok-c3'
  case_dir=$(make_project_case audit-existing "$diverged")
  git -C "$case_dir/project" worktree add -q -b "fm/$healthy" "$case_dir/healthy" main
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/detached" main
  write_task_meta "$case_dir" "$diverged" "$case_dir/wrong"
  write_task_meta "$case_dir" "$healthy" "$case_dir/healthy"
  fm_write_meta "$case_dir/state/$detached.meta" \
    "window=firstmate:fm-$detached" \
    "worktree=$case_dir/detached" \
    "project=$case_dir/project" \
    "provider=codex" \
    "harness=codex" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"

  set +e
  out=$(run_audit_fixture "$case_dir" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "audit-existing: audit should exit nonzero when a mismatch is found"
  assert_contains "$out" "MISMATCH: task $diverged" "audit must name the diverged existing task"
  assert_contains "$out" "$case_dir/real" "audit must name where the task branch actually lives"
  assert_not_contains "$out" "$healthy" "audit must not flag the healthy task"
  assert_not_contains "$out" "$detached" "audit must not flag a merely detached recorded worktree"
  pass "existing meta audit reports the diverged task and avoids healthy/detached noise"
}

case "${FM_WORKTREE_OWNERSHIP_TEST_ONLY:-all}" in
  spawn) test_spawn_records_treehouse_holder_under_pool_turnover ;;
  teardown-mismatch) test_teardown_refuses_clean_wrong_recorded_worktree ;;
  teardown-healthy) test_teardown_allows_recorded_task_branch ;;
  audit) test_existing_meta_audit_reports_only_proven_mismatch ;;
  all)
    test_spawn_records_treehouse_holder_under_pool_turnover
    test_teardown_refuses_clean_wrong_recorded_worktree
    test_teardown_allows_recorded_task_branch
    test_existing_meta_audit_reports_only_proven_mismatch
    ;;
  *) fail "unknown FM_WORKTREE_OWNERSHIP_TEST_ONLY=${FM_WORKTREE_OWNERSHIP_TEST_ONLY:-}" ;;
esac
