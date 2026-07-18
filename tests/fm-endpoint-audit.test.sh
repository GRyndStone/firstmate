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
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"}}}\n' \
      "${3:-}" "${FM_HERDR_WORKSPACE_LABEL:-firstmate}"
    ;;
  "tab list")
    if [ "${FM_HERDR_PARTIAL_TAB:-0}" = 1 ]; then
      printf '{"result":{"tabs":[{"tab_id":"subw:t1"}]}}\n'
      exit 0
    fi
    if [ "$workspace" = subw ]; then
      if [ "${FM_HERDR_RENAMED:-0}" = 1 ]; then
        printf '{"result":{"tabs":[{"tab_id":"subw:t1","label":"fm-other-task"},{"tab_id":"subw:t2","label":"fm-dup-task"},{"tab_id":"subw:t3","label":"fm-dup-task"}]}}\n'
      elif [ "${FM_HERDR_SINGLETON:-0}" = 1 ]; then
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
      if [ "${FM_HERDR_RENAMED:-0}" = 1 ]; then
        printf '{"result":{"panes":[{"pane_id":"subw:p1","tab_id":"subw:t1"},{"pane_id":"subw:p2","tab_id":"subw:t2"},{"pane_id":"subw:p3","tab_id":"subw:t3"}]}}\n'
      elif [ "${FM_HERDR_SINGLETON:-0}" = 1 ]; then
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
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" \
    FM_HERDR_WORKSPACE_LABEL=2ndmate-sub-a1 "$AUDIT" --json)
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

test_herdr_recorded_target_owner_mismatch_keeps_replacements() {
  local home out
  home=$(make_fixture herdr-recorded-mismatch)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p1' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p1' \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
    FM_HERDR_RENAMED=1 "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 2
      and .[0].kind == "duplicate_recovery_endpoints"
      and .[0].live_endpoints == ["default:subw:p2","default:subw:p3"]
      and .[1].kind == "endpoint_ownership_mismatch"
      and .[1].live_endpoints == ["default:subw:p2","default:subw:p3"]
      and (.[1].reason | contains("recorded Herdr pane ownership could not be confirmed"))
  ' >/dev/null || fail "renamed Herdr target hid its scoped replacements: $out"
  assert_not_contains "$(cat "$home/herdr.log")" 'workspace list' \
    "recorded-target ownership check enumerated the shared Herdr session"
  pass "recorded Herdr mismatches preserve exact-workspace replacement duplicates"
}

test_herdr_workspace_label_must_match_home() {
  local home out status
  home=$(make_fixture workspace-owner-mismatch)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
    FM_HERDR_WORKSPACE_LABEL=foreign-home "$AUDIT" --json 2>&1) || status=$?
  expect_code 1 "$status" "mismatched Herdr workspace home label"
  assert_contains "$out" "invalid exact workspace response" \
    "audit accepted a workspace that was not labeled for this home"
  assert_not_contains "$(cat "$home/herdr.log")" 'tab list' \
    "audit inventoried a workspace owned by another home"
  pass "Herdr workspace inventory is bound to the home-derived label"
}

test_herdr_window_fields_must_be_consistent() {
  local home out
  home=$(make_fixture herdr-meta-consistency)
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=other:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 1 and .[0].kind == "inventory_unavailable"
      and (.[0].reason | contains("consistent exact window/session/workspace/pane identity"))
  ' >/dev/null || fail "inconsistent Herdr endpoint fields were accepted: $out"
  [ ! -s "$home/herdr.log" ] || fail "inconsistent Herdr meta triggered a backend probe"
  pass "Herdr endpoint fields must describe one exact recorded owner"
}

test_missing_owned_workspace_is_inventory_unavailable() {
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
  printf '%s' "$out" | jq -e '
    length == 1 and .[0].kind == "inventory_unavailable"
      and (.[0].reason | contains("recorded Herdr workspace is missing"))
  ' >/dev/null || fail "missing owned workspace licensed a clean inventory: $out"
  assert_contains "$(cat "$log")" 'workspace get subw' "missing workspace did not use exact workspace get"
  assert_not_contains "$(cat "$log")" 'workspace list' "missing workspace path enumerated the shared session"
  assert_not_contains "$(cat "$log")" 'tab list' "missing workspace still queried tabs"
  pass "a missing Herdr workspace cannot license replacement cleanup"
}

test_herdr_secondmate_workspace_uses_validated_meta_home() {
  local home secondmate_home out
  home=$(make_fixture herdr-secondmate-home)
  secondmate_home="$home/secondmate-home"
  mkdir -p "$secondmate_home"
  printf 'dup-task\n' > "$secondmate_home/.fm-secondmate-home"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'kind=secondmate' \
    "home=$secondmate_home" \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" \
    FM_HERDR_WORKSPACE_LABEL=2ndmate-dup-task "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 1 and .[0].kind == "duplicate_recovery_endpoints"
      and .[0].task == "dup-task"
  ' >/dev/null || fail "valid primary-owned Herdr secondmate was rejected: $out"
  pass "Herdr secondmate ownership derives from its validated meta home"
}

test_herdr_secondmate_marker_must_be_safe_and_exact() {
  local home secondmate_home outside out
  home=$(make_fixture herdr-secondmate-marker)
  secondmate_home="$home/secondmate-home"
  outside="$home/foreign-marker"
  mkdir -p "$secondmate_home"
  printf 'dup-task\n' > "$outside"
  ln -s "$outside" "$secondmate_home/.fm-secondmate-home"
  fm_write_meta "$home/state/dup-task.meta" \
    'backend=herdr' \
    'window=default:subw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=subw' \
    'herdr_pane_id=subw:p2' \
    'kind=secondmate' \
    "home=$secondmate_home" \
    'worktree=/owned/worktree'
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$home/herdr.log" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 1 and .[0].kind == "inventory_unavailable"
      and (.[0].reason | contains("home marker is unsafe"))
  ' >/dev/null || fail "unsafe Herdr secondmate marker authorized inventory: $out"
  [ ! -s "$home/herdr.log" ] || fail "unsafe Herdr marker triggered an endpoint query"
  pass "Herdr secondmate markers are regular and task-identity bound"
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
  display-message)
    printf '@12\towned-session\tfm-dup-task\t%s\n' "${FM_TMUX_OWNER:?}"
    ;;
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
  display-message) printf '@12\towned-session\tfm-dup-task\t%s\n' "${FM_TMUX_OWNER:?}" ;;
  list-windows)
    case "$*" in
      *'#{window_id},@12}'*) ;;
      *) printf '@11\tfm-dup-task\t\t_\n@13\tfm-dup-task\t%s\t_\n@14\tfm-dup-task\t%s\t_\n' "$FM_TMUX_OWNER" "$FM_TMUX_OWNER" ;;
    esac
    ;;
  new-window) printf 'unexpected endpoint creation\n' >&2; exit 91 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_OWNER="$identity" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 2
      and .[0].kind == "duplicate_recovery_endpoints"
      and .[0].live_endpoints == ["@13","@14"]
      and .[1].kind == "inventory_unavailable"
      and (.[1].reason | contains("untagged legacy tmux window"))
  ' >/dev/null || fail "untagged tmux ambiguity hid tagged duplicates: $out"
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

test_tmux_recorded_target_owner_mismatch_keeps_replacements() {
  local home out identity
  home=$(make_fixture tmux-recorded-mismatch)
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
  display-message) printf '@12\towned-session\tfm-recycled-task\t%s\n' "${FM_TMUX_OWNER:?}" ;;
  list-windows) printf '@11\tfm-dup-task\t%s\t_\n@13\tfm-dup-task\t%s\t_\n' "${FM_TMUX_OWNER:?}" "$FM_TMUX_OWNER" ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_OWNER="$identity" "$AUDIT" --json)
  printf '%s' "$out" | jq -e '
    length == 2
      and .[0].kind == "duplicate_recovery_endpoints"
      and .[0].live_endpoints == ["@11","@13"]
      and .[1].kind == "endpoint_ownership_mismatch"
      and .[1].live_endpoints == ["@11","@13"]
      and (.[1].reason | contains("recorded tmux window ownership could not be confirmed"))
  ' >/dev/null || fail "recycled tmux target hid its scoped replacements: $out"
  pass "recorded tmux mismatches preserve exact-session replacement duplicates"
}

test_tmux_moved_window_is_unknown_not_absent() {
  local home identity actual
  home=$(make_fixture tmux-moved-window)
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  printf '@12\tmoved-session\tfm-dup-task\t%s\n' "${FM_TMUX_OWNER:?}"
  exit 0
fi
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  actual=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_OWNER="$identity" \
    bash -c '. "$1"; fm_backend_target_state tmux @12 fm-dup-task "$2" /owned/worktree owned-session' \
      _ "$ROOT/bin/fm-backend.sh" "$identity")
  [ "$actual" = unknown ] || fail "moved tmux window was misclassified as $actual"
  pass "tmux container loss is unknown and cannot license a raw kill"
}

test_tmux_owned_kill_is_conditioned_inside_server_action() {
  local home identity log status
  home=$(make_fixture tmux-owned-kill)
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  log="$home/tmux.log"
  fm_write_meta "$home/state/owned.meta" \
    'window=@12' \
    'tmux_window_id=@12' \
    'tmux_session=owned-session' \
    "tmux_home_identity=$identity" \
    'kind=secondmate'
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  display-message) printf '@12\towned-session\tfm-owned\t%s\n' "${FM_TMUX_OWNER:?}" ;;
  if-shell) printf 'ownership-mismatch\n' ;;
  kill-window) exit 97 ;;
esac
SH
  chmod +x "$home/fakebin/tmux"
  status=0
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TMUX_LOG="$log" FM_TMUX_OWNER="$identity" \
    bash -c '. "$1"; fm_backend_kill_owned_meta "$2" fm-owned' \
      _ "$ROOT/bin/fm-backend.sh" "$home/state/owned.meta" || status=$?
  [ "$status" -ne 0 ] || fail "an action-time tmux ownership mismatch licensed closure"
  assert_contains "$(cat "$log")" 'if-shell -F -t @12' \
    "owned tmux close did not bind validation and kill in one server action"
  [ "$(grep -c '^kill-window ' "$log")" -eq 0 ] \
    || fail "owned tmux close fell back to a raw kill command"
  pass "tmux liveness cleanup binds ownership inside the close action"
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

test_absent_final_state_directory_is_an_empty_read_only_audit() {
  local home out status
  home=$(make_fixture absent-final-state)
  rm -rf "$home/state"
  status=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$AUDIT" --json 2>&1) || status=$?
  expect_code 0 "$status" "absent final state directory audit"
  [ "$out" = '[]' ] || fail "absent final state directory did not return an empty audit: $out"
  assert_absent "$home/state" "read-only endpoint audit created an absent state directory"
  pass "endpoint audit accepts an absent final state directory after validating its ancestors"
}

test_absent_state_requires_an_existing_home_parent() {
  local home out status
  home="$TMP_ROOT/missing-home/never-created"
  status=0
  out=$(FM_HOME="$home" "$AUDIT" --json 2>&1) || status=$?
  expect_code 1 "$status" "absent state with missing home"
  assert_contains "$out" "missing effective state path parent" \
    "audit treated a missing home as an empty scoped fleet"
  assert_absent "$home" "read-only endpoint audit created a missing home"
  pass "endpoint audit accepts only a missing final state under an existing home"
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
  actual=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_WORKSPACE_NOT_FOUND=1 \
    bash -c '. "$1"; fm_backend_target_state herdr default:subw:p2 fm-dup-task subw' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = unknown ] || fail "missing Herdr workspace was misclassified as $actual"
  pass "Herdr endpoint probe binds the recorded pane to its exact workspace and task label"
}

test_duplicate_is_reported_inside_owned_workspace_only
test_inventory_failure_is_loud
test_singleton_mismatch_is_reported
test_herdr_recorded_target_owner_mismatch_keeps_replacements
test_herdr_workspace_label_must_match_home
test_herdr_window_fields_must_be_consistent
test_missing_owned_workspace_is_inventory_unavailable
test_herdr_secondmate_workspace_uses_validated_meta_home
test_herdr_secondmate_marker_must_be_safe_and_exact
test_partial_herdr_inventory_fails_closed
test_unresolved_herdr_pane_tab_fails_closed
test_tmux_duplicates_use_exact_recorded_session_and_task
test_tmux_untagged_legacy_window_is_ambiguous
test_tmux_recorded_target_owner_mismatch_keeps_replacements
test_tmux_moved_window_is_unknown_not_absent
test_tmux_owned_kill_is_conditioned_inside_server_action
test_tmux_unscoped_meta_reports_inventory_unavailable
test_symlinked_meta_is_not_read_across_homes
test_symlinked_state_path_component_is_refused_before_enumeration
test_absent_final_state_directory_is_an_empty_read_only_audit
test_absent_state_requires_an_existing_home_parent
test_zellij_reports_unavailable_without_cross_home_inventory
test_cmux_reports_unavailable_without_cross_home_inventory
test_orca_reports_unavailable_without_app_global_inventory
test_text_output_includes_inventory_unavailable_reason
test_herdr_endpoint_probe_distinguishes_absent_from_unreadable
