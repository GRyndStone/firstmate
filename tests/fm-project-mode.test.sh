#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh delivery-mode defaults.
#
# no-mistakes is explicit opt-in only. Unknown/missing/legacy fallbacks are
# direct-PR off.
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
- local-proj [local-only] - local only (added 2026-07-01)
- yolo-proj [direct-PR +yolo] - yolo direct PR (added 2026-07-01)
- weird-proj [spaceship] - unknown mode token (added 2026-07-01)
EOF
}

test_missing_registry_defaults_direct_pr() {
  local home out
  home="$TMP_ROOT/no-reg"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$MODE" anything 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "missing registry should yield direct-PR off, got '$out'"
  pass "missing registry defaults to direct-PR off"
}

test_unknown_project_defaults_direct_pr() {
  local home out
  home="$TMP_ROOT/unknown"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE" not-listed 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "unknown project should yield direct-PR off, got '$out'"
  pass "unknown project defaults to direct-PR off"
}

test_legacy_omitted_mode_is_direct_pr() {
  local home out
  home="$TMP_ROOT/legacy"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE" bare-proj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "omitted brackets should yield direct-PR off, got '$out'"
  pass "legacy omitted mode brackets default to direct-PR off"
}

test_explicit_modes() {
  local home out
  home="$TMP_ROOT/explicit"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE" nm-proj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "explicit no-mistakes failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" direct-proj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "explicit direct-PR failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" local-proj 2>/dev/null)
  [ "$out" = "local-only off" ] || fail "explicit local-only failed: '$out'"
  out=$(FM_HOME="$home" "$MODE" yolo-proj 2>/dev/null)
  [ "$out" = "direct-PR on" ] || fail "direct-PR +yolo failed: '$out'"
  pass "explicit no-mistakes, direct-PR, local-only, and +yolo resolve correctly"
}

test_unknown_mode_token_defaults_direct_pr() {
  local home out
  home="$TMP_ROOT/weird"
  write_registry "$home"
  out=$(FM_HOME="$home" "$MODE" weird-proj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "unknown mode token should yield direct-PR off, got '$out'"
  pass "unknown mode token defaults to direct-PR off"
}

test_missing_registry_defaults_direct_pr
test_unknown_project_defaults_direct_pr
test_legacy_omitted_mode_is_direct_pr
test_explicit_modes
test_unknown_mode_token_defaults_direct_pr
