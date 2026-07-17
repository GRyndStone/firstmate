#!/usr/bin/env bash
# Tests for deterministic, same-home duplicate recovery endpoint reporting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-endpoint-audit.sh"
TMP_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
TMP_ROOT=$(TMPDIR="$TMP_BASE" fm_test_tmproot fm-endpoint-audit)

make_fixture() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
workspace=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" != --workspace ] || workspace=${args[$((i+1))]:-}
done
case "${1:-} ${2:-}" in
  "pane get")
    case "${FM_HERDR_PANE_STATE:-present}" in
      present) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
      absent) printf '{"error":{"code":"pane_not_found"}}\n' >&2; exit 1 ;;
      unknown) printf '{"error":{"code":"transport_error"}}\n' >&2; exit 1 ;;
    esac
    ;;
  "workspace get")
    if [ "${FM_HERDR_WORKSPACE_NOT_FOUND:-0}" = 1 ]; then
      printf '{"error":{"code":"workspace_not_found","message":"gone"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"2ndmate-sub-a1"}}}\n' "${3:-}"
    ;;
  "tab list")
    if [ "${FM_HERDR_PARTIAL_TAB:-0}" = 1 ]; then
      printf '{"result":{"tabs":[{"tab_id":"subw:t1"}]}}\n'
      exit 0
    fi
    if [ "$workspace" = subw ]; then
      if [ "${FM_HERDR_SINGLETON:-0}" = 1 ]; then
        printf '{"result":{"tabs":[{"tab_id":"subw:t1","label":"fm-dup-task"}]}}\n'
      else
        printf '{"result":{"tabs":[{"tab_id":"subw:t1","label":"fm-dup-task"},{"tab_id":"subw:t2","label":"fm-dup-task"}]}}\n'
      fi
    else
      printf '{"result":{"tabs":[{"tab_id":"mainw:t1","label":"fm-other-task"}]}}\n'
    fi
    ;;
  "pane list")
    if [ "${FM_HERDR_PARTIAL_PANE:-0}" = 1 ]; then
      printf '{"result":{"panes":[{"pane_id":"subw:p1"}]}}\n'
      exit 0
    fi
    if [ "${FM_HERDR_UNRESOLVED_PANE:-0}" = 1 ]; then
      printf '{"result":{"panes":[{"pane_id":"subw:p-hidden","tab_id":"subw:t-hidden"}]}}\n'
      exit 0
    fi
    if [ "$workspace" = subw ]; then
      if [ "${FM_HERDR_SINGLETON:-0}" = 1 ]; then
        printf '{"result":{"panes":[{"pane_id":"subw:p1","tab_id":"subw:t1"}]}}\n'
      else
        printf '{"result":{"panes":[{"pane_id":"subw:p1","tab_id":"subw:t1"},{"pane_id":"subw:p2","tab_id":"subw:t2"}]}}\n'
      fi
    else
      printf '{"result":{"panes":[{"pane_id":"mainw:p1","tab_id":"mainw:t1"}]}}\n'
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$home"
}

test_duplicate_is_reported_inside_owned_workspace_only() {
  local home log out
  home=$(make_fixture scoped)
  log="$home/herdr.log"
  printf 'sub-a1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    . == [{
      kind:"duplicate_recovery_endpoints",
      backend:"herdr",
      task:"dup-task",
      worktree:"/owned/worktree",
      recorded_endpoint:"default:subw:p2",
      live_endpoints:["default:subw:p1","default:subw:p2"],
      action:"inspect; do not auto-close"
    }]
  ' >/dev/null || fail "duplicate endpoint JSON was incomplete or unstable: $out"
  assert_contains "$(cat "$log")" 'tab list --workspace subw' "audit did not inspect the active home's workspace"
  assert_contains "$(cat "$log")" 'workspace get subw' "audit did not query the exact meta-owned workspace"
  assert_not_contains "$(cat "$log")" 'workspace list' "audit enumerated the shared Herdr session"
  assert_not_contains "$(cat "$log")" 'close' "read-only audit attempted destructive endpoint cleanup"
  pass "duplicate endpoints are deterministic, same-home scoped, and inspect-only"
}

test_inventory_failure_is_loud() {
  local home out status
  home=$(make_fixture unreadable)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/herdr"
  chmod +x "$home/fakebin/herdr"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" "$AUDIT" --json 2>&1) || status=$?
  expect_code 1 "$status" "unreadable Herdr inventory"
  assert_contains "$out" "cannot read Herdr workspace default:subw" "inventory failure was silently treated as no anomalies"
  pass "unreadable same-home inventory fails loudly instead of hiding duplicates"
}

test_singleton_mismatch_is_reported() {
  local home log out
  home=$(make_fixture singleton-mismatch)
  log="$home/herdr.log"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_SINGLETON=1 "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    . == [{
      kind:"endpoint_ownership_mismatch",
      backend:"herdr",
      task:"dup-task",
      worktree:"/owned/worktree",
      recorded_endpoint:"default:subw:p2",
      live_endpoints:["default:subw:p1"],
      action:"inspect; do not auto-close"
    }]
  ' >/dev/null || fail "singleton ownership mismatch was not reported: $out"
  assert_not_contains "$(cat "$log")" 'workspace list' "singleton audit enumerated the session"
  pass "a singleton live endpoint differing from meta is an ownership anomaly"
}

test_missing_owned_workspace_is_an_empty_inventory() {
  local home log out
  home=$(make_fixture missing-workspace)
  log="$home/herdr.log"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_WORKSPACE_NOT_FOUND=1 "$AUDIT" --json)
  [ "$out" = '[]' ] || fail "missing owned workspace was not treated as an empty inventory: $out"
  assert_contains "$(cat "$log")" 'workspace get subw' "missing workspace did not use exact workspace get"
  assert_not_contains "$(cat "$log")" 'workspace list' "missing workspace path enumerated the shared session"
  assert_not_contains "$(cat "$log")" 'tab list' "missing workspace still queried tabs"
  pass "structured workspace_not_found is an absent owned workspace"
}

test_partial_herdr_inventory_fails_closed() {
  local home mode out status
  home=$(make_fixture partial-herdr)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  for mode in TAB PANE; do
    status=0
    out=$(env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
      "FM_HERDR_PARTIAL_$mode=1" "$AUDIT" --json 2>&1) || status=$?
    expect_code 1 "$status" "partial Herdr $mode inventory"
    assert_contains "$out" "invalid" "partial Herdr $mode inventory was silently excluded"
  done
  pass "partial Herdr tab and pane records fail closed before duplicate joining"
}

test_unresolved_herdr_pane_tab_fails_closed() {
  local home out status
  home=$(make_fixture unresolved-herdr-pane)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
    FM_HERDR_UNRESOLVED_PANE=1 "$AUDIT" --json 2>&1) || status=$?
  expect_code 1 "$status" "unresolved Herdr pane tab reference"
  assert_contains "$out" "unresolved pane tab reference" "unresolved Herdr pane vanished from duplicate accounting"
  pass "Herdr panes must resolve to tabs in the exact workspace inventory"
}

test_tmux_duplicates_use_exact_recorded_session_and_task() {
  local home log out identity
  home=$(make_fixture tmux-exact-session)
  log="$home/tmux.log"
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  fm_write_meta "$home/state/dup-task.meta" \
    'window=@12' \
    "tmux_home_identity=$identity" \
    'tmux_session=owned-session' \
    'tmux_window_id=@12' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  list-windows)
    printf '@11\tfm-dup-task\t%s\t_\n@12\tfm-dup-task\t%s\t_\n' "${FM_TMUX_OWNER:?}" "$FM_TMUX_OWNER"
    ;;
  *) exit 8 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_TMUX_OWNER="$identity" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    . == [{
      kind:"duplicate_recovery_endpoints",
      backend:"tmux",
      task:"dup-task",
      worktree:"/owned/worktree",
      recorded_endpoint:"@12",
      live_endpoints:["@11","@12"],
      action:"inspect; do not auto-close"
    }]
  ' >/dev/null || fail "tmux duplicate endpoint JSON was incomplete: $out"
  assert_contains "$(cat "$log")" 'list-windows -t =owned-session -f #{==:#{window_name},fm-dup-task}' \
    "tmux audit did not query the exact recorded home identity and task label"
  assert_not_contains "$(cat "$log")" ' -a ' "tmux audit enumerated other sessions"
  assert_not_contains "$(cat "$log")" 'kill' "tmux audit attempted automatic closure"
  pass "tmux duplicate audit returns only exact-home identified task windows"
}

test_tmux_untagged_legacy_window_is_ambiguous() {
  local home out identity status
  home=$(make_fixture tmux-legacy-untagged)
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  fm_write_meta "$home/state/dup-task.meta" \
    'window=@12' \
    "tmux_home_identity=$identity" \
    'tmux_session=owned-session' \
    'tmux_window_id=@12' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '@11\tfm-dup-task\t\t_\n' ;;
  new-window) printf 'unexpected endpoint creation\n' >&2; exit 91 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 1 and .[0].kind == "inventory_unavailable" and
    (.[0].reason | contains("untagged legacy tmux window"))
  ' >/dev/null || fail "untagged tmux audit did not fail closed: $out"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" bash -c '
    FM_BACKEND_LIB_DIR="$1/bin"; . "$1/bin/fm-backend.sh"
    fm_backend_source tmux
    fm_backend_tmux_create_task owned-session fm-dup-task /tmp "$2"
  ' _ "$ROOT" "$identity" 2>&1) || status=$?
  expect_code 1 "$status" "untagged legacy tmux creation"
  assert_contains "$out" "ambiguous Firstmate-home ownership" "spawn did not refuse the legacy untagged label"
  pass "untagged legacy tmux labels are ambiguous for audit and creation"
}

test_symlinked_meta_is_not_read_across_homes() {
  local home outside out
  home=$(make_fixture symlinked-meta)
  outside="$TMP_ROOT/symlinked-meta-outside.meta"
  printf 'backend=herdr\nwindow=default:foreign\nworktree=/foreign\n' > "$outside"
  ln -s "$outside" "$home/state/foreign.meta"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    . == [{kind:"inventory_unavailable",backend:"unknown",task:"foreign",worktree:"",recorded_endpoint:"",live_endpoints:[],reason:"task metadata is symlinked or non-regular; cross-home read refused",action:"inspect; do not auto-close"}]
  ' >/dev/null || fail "symlinked metadata did not produce a scoped unavailable result: $out"
  [ ! -e "$home/herdr.log" ] || [ ! -s "$home/herdr.log" ] || fail "audit followed symlinked metadata into a backend query"
  pass "symlinked metadata is reported without reading another home's endpoint fields"
}

test_symlinked_state_path_component_is_refused_before_enumeration() {
  local home outside out status
  home=$(make_fixture symlinked-state-path)
  outside="$TMP_ROOT/symlinked-state-path-outside"
  mkdir -p "$outside"
  fm_write_meta "$outside/foreign.meta" \
    'backend=herdr' 'window=default:foreign' 'worktree=/foreign'
  rm -rf "$home/state"
  ln -s "$outside" "$home/state"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
    "$AUDIT" --json 2>&1) || status=$?
  expect_code 1 "$status" "symlinked effective state path"
  assert_contains "$out" "symlinked effective state path component refused" \
    "audit did not reject the symlinked state directory before enumeration"
  [ ! -e "$home/herdr.log" ] || [ ! -s "$home/herdr.log" ] \
    || fail "audit queried a backend through foreign state metadata"
  pass "endpoint audit rejects symlinked effective state path components"
}

test_tmux_unscoped_meta_reports_inventory_unavailable() {
  local home log out
  home=$(make_fixture tmux-unscoped)
  log="$home/tmux.log"
  fm_write_meta "$home/state/dup-task.meta" \
    'window=fm-dup-task' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
exit 99
SH
  chmod +x "$home/fakebin/tmux"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 1
      and .[0].kind == "inventory_unavailable"
      and .[0].backend == "tmux"
      and (.[0].reason | contains("recorded endpoint identity; shared-session sweep refused"))
  ' >/dev/null || fail "unscoped tmux meta did not fail closed: $out"
  [ ! -s "$log" ] || fail "unscoped tmux audit enumerated shared inventory: $(cat "$log")"
  pass "tmux metadata without an exact session fails closed without a cross-session sweep"
}

test_orca_reports_unavailable_without_app_global_inventory() {
  local home log out
  home=$(make_fixture orca-no-sweep)
  log="$home/orca.log"
  fm_write_meta "$home/state/orca-task.meta" \
    'backend=orca' \
    'window=term-a' \
    'terminal=term-a' \
    'orca_worktree_id=wt-a' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/orca" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ORCA_LOG:?}"
exit 99
SH
  chmod +x "$home/fakebin/orca"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ORCA_LOG="$log" "$AUDIT" --json)
  printf '%s\n' "$out" | jq -e '
    length == 1 and
    .[0].kind == "inventory_unavailable" and
    .[0].backend == "orca" and
    .[0].recorded_endpoint == "term-a" and
    .[0].reason == "orca has no verified exact-worktree terminal inventory; app-global sweep refused"
  ' >/dev/null || fail "Orca audit did not emit its structured unavailable finding: $out"
  [ ! -s "$log" ] || fail "Orca audit enumerated app-global terminal inventory: $(cat "$log")"
  pass "Orca duplicate audit reports unavailable without app-global enumeration"
}

test_text_output_includes_inventory_unavailable_reason() {
  local home out
  home=$(make_fixture text-reason)
  fm_write_meta "$home/state/cmux-task.meta" \
    'backend=cmux' \
    'window=ws-a:sf-a' \
    'worktree=/owned/worktree'
  out=$(FM_HOME="$home" "$AUDIT")
  assert_contains "$out" 'reason=cmux has no exact-home duplicate inventory; app-global sweep refused' \
    "text endpoint audit dropped the structured inventory-unavailable reason"
  pass "text endpoint audit preserves the operator-facing anomaly reason"
}

test_zellij_reports_unavailable_without_cross_home_inventory() {
  local home log out status
  home=$(make_fixture zellij-no-sweep)
  log="$home/zellij.log"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=zellij' \
    'window=fm:42' \
    'zellij_session=fm' \
    'zellij_tab_id=7' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ZELLIJ_LOG:?}"
exit 99
SH
  chmod +x "$home/fakebin/zellij"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" FM_ZELLIJ_LOG="$log" \
    "$AUDIT" --json 2>&1) || status=$?
  expect_code 0 "$status" "zellij exact-home inventory report"
  printf '%s\n' "$out" | jq -e '
    length == 1 and
    .[0].kind == "inventory_unavailable" and
    .[0].backend == "zellij" and
    .[0].task == "dup-task" and
    .[0].worktree == "/owned/worktree" and
    .[0].recorded_endpoint == "fm:42" and
    .[0].live_endpoints == [] and
    .[0].reason == "zellij has no exact-home duplicate inventory; shared-session sweep refused"
  ' >/dev/null || fail "zellij audit did not emit its structured unavailable finding: $out"
  [ ! -s "$log" ] || fail "zellij audit enumerated shared-session inventory: $(cat "$log")"
  pass "Zellij duplicate audit reports unavailable without enumerating another home's tabs"
}

test_cmux_reports_unavailable_without_cross_home_inventory() {
  local home log out status
  home=$(make_fixture cmux-no-sweep)
  log="$home/cmux.log"
  fm_write_meta "$home/state/cmux-task.meta" \
    'backend=cmux' \
    'window=ws-a:sf-a' \
    'cmux_workspace_id=ws-a' \
    'cmux_surface_id=sf-a' \
    'worktree=/owned/worktree'
  cat > "$home/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_CMUX_LOG:?}"
exit 99
SH
  chmod +x "$home/fakebin/cmux"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_CMUX_LOG="$log" "$AUDIT" --json 2>&1) || status=$?
  expect_code 0 "$status" "cmux exact-home inventory report"
  printf '%s\n' "$out" | jq -e '
    length == 1 and
    .[0].kind == "inventory_unavailable" and
    .[0].backend == "cmux" and
    .[0].task == "cmux-task" and
    .[0].worktree == "/owned/worktree" and
    .[0].recorded_endpoint == "ws-a:sf-a" and
    .[0].live_endpoints == [] and
    .[0].reason == "cmux has no exact-home duplicate inventory; app-global sweep refused"
  ' >/dev/null || fail "cmux audit did not emit its structured unavailable finding: $out"
  [ ! -s "$log" ] || fail "cmux audit enumerated app-global inventory: $(cat "$log")"
  pass "cmux duplicate audit reports unavailable without enumerating another home's windows"
}

test_herdr_endpoint_probe_distinguishes_absent_from_unreadable() {
  local home log actual
  home=$(make_fixture herdr-tristate)
  log="$home/herdr.log"
  actual=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    bash -c '. "$1"; fm_backend_target_state herdr default:subw:p2 fm-dup-task subw' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = present ] || fail "present Herdr endpoint read $actual"
  actual=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_SINGLETON=1 \
    bash -c '. "$1"; fm_backend_target_state herdr default:subw:p2 fm-dup-task subw' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = absent ] || fail "absent Herdr endpoint read $actual"
  actual=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    bash -c '. "$1"; fm_backend_target_state herdr default:subw:p2 fm-wrong-task subw' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = unknown ] || fail "mismatched-owner Herdr endpoint read $actual"
  pass "Herdr endpoint probe binds the recorded pane to its exact workspace and task label"
}

test_duplicate_is_reported_inside_owned_workspace_only
test_inventory_failure_is_loud
test_singleton_mismatch_is_reported
test_missing_owned_workspace_is_an_empty_inventory
test_partial_herdr_inventory_fails_closed
test_unresolved_herdr_pane_tab_fails_closed
test_tmux_duplicates_use_exact_recorded_session_and_task
test_tmux_untagged_legacy_window_is_ambiguous
test_tmux_unscoped_meta_reports_inventory_unavailable
test_symlinked_meta_is_not_read_across_homes
test_symlinked_state_path_component_is_refused_before_enumeration
test_zellij_reports_unavailable_without_cross_home_inventory
test_cmux_reports_unavailable_without_cross_home_inventory
test_orca_reports_unavailable_without_app_global_inventory
test_text_output_includes_inventory_unavailable_reason
test_herdr_endpoint_probe_distinguishes_absent_from_unreadable
