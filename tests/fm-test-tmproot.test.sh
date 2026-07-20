#!/usr/bin/env bash
# tests/fm-test-tmproot.test.sh - regression coverage for the parent-shell
# fm_test_tmproot caller-assignment API and static rejection of the obsolete
# command-substitution form that leaked recreated fixture roots.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT=$ROOT
# Isolate this suite's own TMPDIR so leak proofs do not see host pollution.
SUITE_PARENT=
fm_test_tmproot SUITE_PARENT fm-tmproot-suite
export TMPDIR="$SUITE_PARENT"
# Clear registrations from the suite parent itself before child cases: each
# nested proof runs in a subprocess with a fresh shell, so the suite root stays
# registered here for final teardown only.
# (Child suites re-source lib.sh and get their own arrays.)

count_prefix_roots() {
  local prefix=$1 base=${TMPDIR:-/tmp}
  find "$base" -maxdepth 1 -type d -name "${prefix}.*" 2>/dev/null | wc -l | tr -d ' '
}

test_single_root_parent_registration() {
  local out root_path
  out=$(
    # Fresh shell: source lib, create one root, assert parent state, exit cleanly.
    bash -c '
      set -u
      # shellcheck source=tests/lib.sh
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot ROOT fm-tmproot-single
      [ -d "$ROOT" ] || { echo "missing root"; exit 1; }
      [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 1 ] || { echo "array_len=${#FM_TEST_CLEANUP_DIRS[@]}"; exit 1; }
      [ "${FM_TEST_CLEANUP_DIRS[0]}" = "$ROOT" ] || { echo "array mismatch"; exit 1; }
      # Bash 3.2 (macOS) prints nothing from `trap -p` when stdout is a pipe;
      # capture via command substitution instead.
      case "$(trap -p EXIT 2>/dev/null || true)" in
        *fm_test_cleanup*) : ;;
        *) echo "no trap"; exit 1 ;;
      esac
      mkdir -p "$ROOT/child"
      printf "%s\n" "$ROOT"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "single-root parent registration subprocess failed"
  root_path=$out
  [ ! -e "$root_path" ] || fail "single root survived EXIT: $root_path"
  [ "$(count_prefix_roots fm-tmproot-single)" = "0" ] || fail "single-root left prefix entries"
  pass "single-root: parent registration, trap, and EXIT cleanup"
}

test_multi_root_cleanup() {
  local out
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot A fm-tmproot-multi
      fm_test_tmproot B fm-tmproot-multi
      mkdir -p "$A/x" "$B/y"
      [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 2 ] || exit 1
      printf "%s\n%s\n" "$A" "$B"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "multi-root subprocess failed"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ ! -e "$p" ] || fail "multi root survived EXIT: $p"
  done <<< "$out"
  [ "$(count_prefix_roots fm-tmproot-multi)" = "0" ] || fail "multi-root left prefix entries"
  pass "multi-root: both roots removed on EXIT"
}

test_helper_sourced_registration() {
  # wake-helpers sources lib and calls fm_test_tmproot for FM_ROOT_OVERRIDE and
  # the wedge recorder. Prove those roots clean up with the parent trap.
  local out
  out=$(
    bash -c '
      set -u
      export TMPDIR="$2"
      # Provide TMP_ROOT before wake-helpers fixtures that assume it.
      . "$1/tests/lib.sh"
      fm_test_tmproot TMP_ROOT fm-tmproot-wake
      . "$1/tests/wake-helpers.sh"
      [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ -d "$FM_ROOT_OVERRIDE" ] || { echo "override missing"; exit 1; }
      [ -n "${_fm_wedge_rec_dir:-}" ] && [ -d "$_fm_wedge_rec_dir" ] || { echo "wedge missing"; exit 1; }
      [ "${#FM_TEST_CLEANUP_DIRS[@]}" -ge 2 ] || { echo "array too small ${#FM_TEST_CLEANUP_DIRS[@]}"; exit 1; }
      printf "%s\n" "$TMP_ROOT" "$FM_ROOT_OVERRIDE" "$_fm_wedge_rec_dir"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "helper-sourced subprocess failed: $out"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ ! -e "$p" ] || fail "helper-sourced root survived EXIT: $p"
  done <<< "$out"
  pass "helper-sourced: wake-helpers roots cleaned on EXIT"
}

test_failing_test_still_cleans() {
  local marker rc=0
  marker=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot ROOT fm-tmproot-fail
      mkdir -p "$ROOT/leaky"
      printf "%s\n" "$ROOT"
      exit 1
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected failing child exit 1, got $rc"
  [ ! -e "$marker" ] || fail "failed-test root survived EXIT: $marker"
  [ "$(count_prefix_roots fm-tmproot-fail)" = "0" ] || fail "failing-test left prefix entries"
  pass "failing test still removes registered roots on EXIT"
}

test_custom_exit_trap_composition() {
  local out root_path marker
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot ROOT fm-tmproot-custom
      mkdir -p "$ROOT/child"
      # Marker lives under TMPDIR (not under ROOT) so writing it after
      # fm_test_cleanup removes ROOT still works.
      marker="$2/custom-marker-$$"
      cleanup() {
        fm_test_cleanup
        : > "$marker"
      }
      trap cleanup EXIT
      printf "%s\n%s\n" "$ROOT" "$marker"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "custom-EXIT subprocess failed"
  root_path=$(printf '%s\n' "$out" | sed -n '1p')
  marker=$(printf '%s\n' "$out" | sed -n '2p')
  [ ! -e "$root_path" ] || fail "custom-EXIT left root: $root_path"
  [ -f "$marker" ] || fail "custom EXIT body did not run"
  rm -f "$marker"
  pass "custom EXIT trap composition still cleans registered dirs"
}

test_command_substitution_is_unsafe_and_static_rejected() {
  # Historical defect: command-substitution of the old echo-path helper left the
  # parent with no array entry and no trap; recreating the path leaked. The new
  # API requires the caller-assignment variable and prefix as separate args.
  local rc=0 err hits scan_status fixture
  err=$(bash -c '
    set -u
    . "$1/tests/lib.sh"
    export TMPDIR="$2"
    fm_test_tmproot tmp 2>&1
  ' _ "$REPO_ROOT" "$TMPDIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "one-argument fm_test_tmproot call should fail"
  assert_contains "$err" "fm_test_tmproot VAR prefix" "old shape error message"

  scan_tmproot_command_substitutions() {
    local scan_root=$1 scan_output status
    if ! command -v rg >/dev/null 2>&1; then
      printf 'rg is required for the fm_test_tmproot static scan\n' >&2
      return 127
    fi
    scan_output=$(rg -U -n --pcre2 \
      '(?m)^[\t ]*# fm-tmproot-static-allow:.*(?:\n|$)(*SKIP)(*F)|\$\(\s*fm_test_tmproot\b' \
      "$scan_root" --glob '*.sh' 2>&1)
    status=$?
    case "$status" in
      0|1) printf '%s' "$scan_output" ;;
      *) printf '%s\n' "$scan_output" >&2; return "$status" ;;
    esac
  }

  fixture="$TMPDIR/tmproot-static-fixture"
  mkdir -p "$fixture"
  printf 'unsafe=$%s\n  fm_test_tmproot ROOT bad\n)\n' '(' > "$fixture/unsafe.sh"
  hits=$(scan_tmproot_command_substitutions "$fixture")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "multiline fixture scan failed with $scan_status"
  assert_contains "$hits" "fm_test_tmproot ROOT bad" "multiline command substitution bypassed the scanner"

  hits=$(PATH="$fixture/no-rg" scan_tmproot_command_substitutions "$fixture" 2>&1)
  scan_status=$?
  [ "$scan_status" -eq 127 ] || fail "missing-rg scan must fail closed, got $scan_status"

  hits=$(scan_tmproot_command_substitutions "$REPO_ROOT/tests")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "static scan failed with $scan_status"
  [ -z "$hits" ] || fail "static: non-comment command-sub of fm_test_tmproot remains"$'\n'"$hits"
  pass "command-substitution form rejected (runtime + static)"
}

test_local_varname_assignment() {
  local out
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      f() {
        local dir
        fm_test_tmproot dir fm-tmproot-local
        [ -d "$dir" ] || exit 1
        printf "%s\n" "$dir"
      }
      f
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "local varname assignment failed"
  [ ! -e "$out" ] || fail "local-root survived EXIT: $out"
  pass "printf -v assigns into caller-local variables"
}

test_single_root_parent_registration
test_multi_root_cleanup
test_helper_sourced_registration
test_failing_test_still_cleans
test_custom_exit_trap_composition
test_command_substitution_is_unsafe_and_static_rejected
test_local_varname_assignment

pass "fm_test_tmproot regression suite complete"
