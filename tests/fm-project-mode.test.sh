#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh delivery-mode resolution.
#
# Every mode is explicit. Unknown, missing, legacy omitted, and invalid choices
# fail closed with the deliverable question instead of becoming direct-PR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
fm_test_tmproot TMP_ROOT fm-project-mode

write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- bare-proj - legacy omitted mode brackets (added 2026-07-01)
- nm-proj [no-mistakes] - explicit pipeline (added 2026-07-01)
- direct-proj [direct-PR] - ordinary direct PR (added 2026-07-01)
- local-first-proj [local-first] - running local product with backup (added 2026-07-26)
- local-proj [local-only] - local only (added 2026-07-01)
- yolo-proj [direct-PR +yolo] - yolo direct PR (added 2026-07-01)
- weird-proj [spaceship] - unknown mode token (added 2026-07-01)
EOF
}

assert_unresolved() {
  local home=$1 name=$2 why=$3 out status=0 err
  err="$home/mode.err"
  out=$(FM_HOME="$home" "$MODE" "$name" 2>"$err") || status=$?
  expect_code 2 "$status" "$why should fail closed"
  [ -z "$out" ] || fail "$why should not emit a fallback mode, got '$out'"
  assert_grep "Determine the deliverable first: is this project a reference repository or a running local instance?" "$err" \
    "$why did not surface the deciding deliverable question"
}

test_missing_registry_fails_closed() {
  local home
  home="$TMP_ROOT/no-reg"
  mkdir -p "$home/data"
  assert_unresolved "$home" anything "missing registry"
  pass "missing registry fails closed with the deliverable question"
}

test_unknown_project_fails_closed() {
  local home
  home="$TMP_ROOT/unknown"
  write_registry "$home"
  assert_unresolved "$home" not-listed "unknown project"
  pass "unknown project fails closed with the deliverable question"
}

test_legacy_omitted_mode_fails_closed() {
  local home
  home="$TMP_ROOT/legacy"
  write_registry "$home"
  assert_unresolved "$home" bare-proj "omitted mode brackets"
  pass "omitted mode brackets fail closed with the deliverable question"
}

test_explicit_modes() {
  local home out
  home="$TMP_ROOT/explicit"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE" nm-proj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "explicit no-mistakes failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" direct-proj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "explicit direct-PR failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" local-first-proj 2>/dev/null)
  [ "$out" = "local-first off" ] || fail "explicit local-first failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" local-proj 2>/dev/null)
  [ "$out" = "local-only off" ] || fail "explicit local-only failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" yolo-proj 2>/dev/null)
  [ "$out" = "direct-PR on" ] || fail "direct-PR +yolo failed: '$out'"
  pass "all explicit delivery modes and +yolo resolve correctly"
}

test_unknown_mode_token_fails_closed() {
  local home
  home="$TMP_ROOT/weird"
  write_registry "$home"
  assert_unresolved "$home" weird-proj "unknown mode token"
  pass "unknown mode token fails closed with the deliverable question"
}

test_missing_registry_fails_closed
test_unknown_project_fails_closed
test_legacy_omitted_mode_fails_closed
test_explicit_modes
test_unknown_mode_token_fails_closed
