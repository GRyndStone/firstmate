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
    if ! command -v perl >/dev/null 2>&1; then
      printf 'perl is required for the fm_test_tmproot static scan\n' >&2
      return 127
    fi
    scan_output=$(perl -MFile::Find -e '
      use strict;
      use warnings;
      my $root = shift;
      my $failed = 0;
      find(
        {
          no_chdir => 1,
          wanted => sub {
            return unless -f $_ && /[.]sh\z/;
            my $file = $File::Find::name;
            open my $fh, "<", $file or do {
              warn "$file: $!\n";
              $failed = 1;
              return;
            };
            local $/;
            my $source = <$fh> // "";
            close $fh or do {
              warn "$file: $!\n";
              $failed = 1;
              return;
            };
            while ($source =~ /(?m:^[\t ]*# fm-tmproot-static-allow:.*(?:\n|$))(*SKIP)(*F)|(?s:\$\((?:(?>\x27[^\x27]*\x27)|(?:"(?:\\.|[^"\\])*")|(?:#[^\n]*(?:\n|$))|(?:\\.)|[^\x27"\\#)])*?\bfm_test_tmproot\b)/g) {
              my $prefix = substr($source, 0, $-[0]);
              my $line = 1 + ($prefix =~ tr/\n//);
              my $line_start = rindex($source, "\n", $-[0] - 1) + 1;
              my $line_end = index($source, "\n", $+[0]);
              $line_end = length($source) if $line_end < 0;
              my $matching_lines = substr($source, $line_start, $line_end - $line_start);
              print "$file:$line:$matching_lines\n";
            }
          },
        },
        $root
      );
      exit $failed;
    ' "$scan_root" 2>&1)
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

  printf 'commented=$%s\n# mid-sub comment\nfm_test_tmproot ROOT worse\n)\n' '(' > "$fixture/comment.sh"
  hits=$(scan_tmproot_command_substitutions "$fixture")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "comment fixture scan failed with $scan_status"
  assert_contains "$hits" "fm_test_tmproot ROOT worse" "comment-separated command substitution bypassed the scanner"

  printf 'wrapped=$%sTMPDIR=/tmp fm_test_tmproot ROOT wrapped; printf ok)\n' '(' > "$fixture/wrapped.sh"
  hits=$(scan_tmproot_command_substitutions "$fixture")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "wrapped fixture scan failed with $scan_status"
  assert_contains "$hits" "TMPDIR=/tmp fm_test_tmproot ROOT wrapped" "wrapped command substitution bypassed the scanner"

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

test_trap_reinstall_after_trap_clear() {
  # Historical gap: trap was installed only when the array was empty, so
  # `trap - EXIT` then another registration stranded every subsequent root.
  local out
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot A fm-tmproot-retrap
      mkdir -p "$A/x"
      trap - EXIT
      fm_test_tmproot B fm-tmproot-retrap
      mkdir -p "$B/y"
      case "$(trap -p EXIT 2>/dev/null || true)" in
        *fm_test_cleanup*) : ;;
        *) echo "no trap after re-register"; exit 1 ;;
      esac
      printf "%s\n%s\n" "$A" "$B"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "trap-reinstall subprocess failed: $out"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ ! -e "$p" ] || fail "retrap root survived EXIT: $p"
  done <<< "$out"
  [ "$(count_prefix_roots fm-tmproot-retrap)" = "0" ] || fail "retrap left prefix entries"
  pass "registration reinstalls EXIT trap after trap - EXIT"
}

test_add_cleanup_hook_runs_before_dir_removal() {
  local out hook_marker root_path
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot ROOT fm-tmproot-hook
      mkdir -p "$ROOT/child"
      marker="$2/hook-marker-$$"
      saw_root_alive="$2/hook-saw-root-$$"
      hook() {
        if [ -d "$ROOT" ]; then
          : > "$saw_root_alive"
        fi
        : > "$marker"
      }
      fm_test_add_cleanup hook
      printf "%s\n%s\n%s\n" "$ROOT" "$marker" "$saw_root_alive"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "add_cleanup subprocess failed"
  root_path=$(printf '%s\n' "$out" | sed -n '1p')
  hook_marker=$(printf '%s\n' "$out" | sed -n '2p')
  saw=$(printf '%s\n' "$out" | sed -n '3p')
  [ ! -e "$root_path" ] || fail "hook suite left root: $root_path"
  [ -f "$hook_marker" ] || fail "exit hook did not run"
  [ -f "$saw" ] || fail "exit hook ran after dir removal (root already gone)"
  rm -f "$hook_marker" "$saw"
  pass "fm_test_add_cleanup runs hooks before registered dir removal"
}

test_register_tmp_and_physical_path() {
  local out
  out=$(
    bash -c '
      set -u
      . "$1/tests/lib.sh"
      export TMPDIR="$2"
      fm_test_tmproot ROOT fm-tmproot-phys
      case "$ROOT" in
        /*) : ;;
        *) echo "not absolute: $ROOT"; exit 1 ;;
      esac
      # Physical: no intermediate symlink components when TMPDIR itself is linked.
      resolved=$(cd "$ROOT" && pwd -P)
      [ "$ROOT" = "$resolved" ] || { echo "not physical: $ROOT vs $resolved"; exit 1; }
      extra="$2/fm-tmproot-regextra.$$"
      mkdir -p "$extra/nested"
      fm_test_register_tmp "$extra"
      printf "%s\n%s\n" "$ROOT" "$extra"
    ' _ "$REPO_ROOT" "$TMPDIR"
  ) || fail "physical/register subprocess failed: $out"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ ! -e "$p" ] || fail "register/phys root survived EXIT: $p"
  done <<< "$out"
  pass "physical path assignment and fm_test_register_tmp cleanup"
}

test_raw_mktemp_fm_prefix_static_rejected() {
  local hits scan_status fixture
  scan_raw_fm_mktemp() {
    local scan_root=$1 scan_output status
    if ! command -v perl >/dev/null 2>&1; then
      printf 'perl is required for the raw mktemp static scan\n' >&2
      return 127
    fi
    scan_output=$(perl -MFile::Find -e '
      use strict;
      use warnings;
      my $root = shift;
      my $failed = 0;
      find(
        {
          no_chdir => 1,
          wanted => sub {
            return unless -f $_ && /[.]sh\z/;
            my $file = $File::Find::name;
            # lib.sh owns the only sanctioned mktemp -d implementation;
            # this regression file embeds fixture strings that look like call sites.
            return if $file =~ m{/tests/lib\.sh\z};
            return if $file =~ m{/tests/fm-test-tmproot\.test\.sh\z};
            open my $fh, "<", $file or do {
              warn "$file: $!\n";
              $failed = 1;
              return;
            };
            local $/;
            my $source = <$fh> // "";
            close $fh or do {
              warn "$file: $!\n";
              $failed = 1;
              return;
            };
            # Skip an allow comment immediately above a mktemp -d line; flag
            # every other mktemp -d that targets an fm-* prefix.
            while ($source =~ /(?m:^[ \t]*# fm-tmproot-static-allow:[^\n]*\n[^\n]*\bmktemp[ \t]+-d[^\n]*\bfm-[A-Za-z0-9._-]*)(*SKIP)(*F)|(?m:^[^\n]*\bmktemp[ \t]+-d[^\n]*\bfm-[A-Za-z0-9._-]*)/g) {
              my $prefix = substr($source, 0, $-[0]);
              my $line = 1 + ($prefix =~ tr/\n//);
              my $line_start = rindex($source, "\n", $-[0] - 1) + 1;
              my $line_end = index($source, "\n", $+[0]);
              $line_end = length($source) if $line_end < 0;
              my $matching_lines = substr($source, $line_start, $line_end - $line_start);
              # Comment-only documentation lines are not call sites.
              next if $matching_lines =~ /^[ \t]*#/;
              print "$file:$line:$matching_lines\n";
            }
          },
        },
        $root
      );
      exit $failed;
    ' "$scan_root" 2>&1)
    status=$?
    case "$status" in
      0|1) printf '%s' "$scan_output" ;;
      *) printf '%s\n' "$scan_output" >&2; return "$status" ;;
    esac
  }

  fixture="$TMPDIR/raw-mktemp-fixture"
  mkdir -p "$fixture/bad" "$fixture/ok"
  # Literal fixture source for the static scanner (not meant to expand here).
  # shellcheck disable=SC2016
  printf 'x=$(mktemp -d "${TMPDIR:-/tmp}/fm-leaky.XXXXXX")\n' > "$fixture/bad/bad.sh"
  hits=$(scan_raw_fm_mktemp "$fixture/bad")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "raw mktemp fixture scan failed with $scan_status"
  assert_contains "$hits" "fm-leaky" "raw mktemp -d of fm-* prefix bypassed scanner"

  # shellcheck disable=SC2016
  printf '# fm-tmproot-static-allow: documented exception\nx=$(mktemp -d "${TMPDIR:-/tmp}/fm-allowed.XXXXXX")\n' > "$fixture/ok/ok.sh"
  hits=$(scan_raw_fm_mktemp "$fixture/ok")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "allowlisted raw mktemp scan failed with $scan_status"
  [ -z "$hits" ] || fail "allowlisted raw mktemp still flagged"$'\n'"$hits"

  hits=$(scan_raw_fm_mktemp "$REPO_ROOT/tests")
  scan_status=$?
  [ "$scan_status" -eq 0 ] || fail "tests/ raw mktemp scan failed with $scan_status"
  [ -z "$hits" ] || fail "static: raw mktemp -d of fm-* prefix remains in tests/"$'\n'"$hits"
  pass "raw mktemp -d of fm-* prefixes rejected (fixture + tests/)"
}

test_focused_suite_leaves_no_known_leak_prefixes() {
  # Run a representative suite that historically leaked under an isolated
  # TMPDIR and assert known prefixes are gone afterward.
  local isolate rc=0 leak
  fm_test_tmproot isolate fm-tmproot-leakproof
  (
    export TMPDIR="$isolate"
    bash "$REPO_ROOT/tests/fm-gotmp.test.sh" >/dev/null
    bash "$REPO_ROOT/tests/fm-cd-pretool-check.test.sh" >/dev/null
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "focused suites failed under isolated TMPDIR (rc=$rc)"
  # Suites must remove every fm-* child they create. The isolate root itself is
  # registered with the parent suite trap and is not a leak.
  leak=$(find "$isolate" -mindepth 1 \( -type d -o -type f \) \
    \( -name 'fm-*' -o -path '*/fm-*' \) 2>/dev/null | head -50)
  [ -z "$leak" ] || fail "focused suites left fm-* paths under isolated TMPDIR"$'\n'"$leak"
  pass "focused suites leave no fm-* leak prefixes under isolated TMPDIR"
}

test_single_root_parent_registration
test_multi_root_cleanup
test_helper_sourced_registration
test_failing_test_still_cleans
test_custom_exit_trap_composition
test_command_substitution_is_unsafe_and_static_rejected
test_local_varname_assignment
test_trap_reinstall_after_trap_clear
test_add_cleanup_hook_runs_before_dir_removal
test_register_tmp_and_physical_path
test_raw_mktemp_fm_prefix_static_rejected
test_focused_suite_leaves_no_known_leak_prefixes

pass "fm_test_tmproot regression suite complete"
