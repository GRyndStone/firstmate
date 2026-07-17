#!/usr/bin/env bash
# Tests for deterministic, same-home duplicate recovery endpoint reporting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-endpoint-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-audit)

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
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"mainw","label":"firstmate"},{"workspace_id":"subw","label":"2ndmate-sub-a1"}]}}\n'
    ;;
  "tab list")
    if [ "$workspace" = subw ]; then
      printf '{"result":{"tabs":[{"tab_id":"subw:t1","label":"fm-dup-task"},{"tab_id":"subw:t2","label":"fm-dup-task"}]}}\n'
    else
      printf '{"result":{"tabs":[{"tab_id":"mainw:t1","label":"fm-other-task"}]}}\n'
    fi
    ;;
  "pane list")
    if [ "$workspace" = subw ]; then
      printf '{"result":{"panes":[{"pane_id":"subw:p1","tab_id":"subw:t1"},{"pane_id":"subw:p2","tab_id":"subw:t2"}]}}\n'
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
  assert_not_contains "$(cat "$log")" 'tab list --workspace mainw' "audit crossed into another home's workspace"
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
  assert_contains "$out" "cannot read Herdr session default" "inventory failure was silently treated as no duplicates"
  pass "unreadable same-home inventory fails loudly instead of hiding duplicates"
}

test_duplicate_is_reported_inside_owned_workspace_only
test_inventory_failure_is_loud
