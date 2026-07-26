#!/usr/bin/env bash
# Behavior tests for bin/fm-fold-sweep.sh - enumeration completeness and the
# enforcement ratchet.
#
# AC-2 (amended) requires two things this file proves:
#
#   1. COMPLETENESS. Every firstmate path that reaches an upstream tool name is
#      enumerated and classified. An under-counting sweep fails the criterion
#      outright, so `--coverage` asserts that every TRACKED file is reached by a
#      declared surface class or named in an explicit exclusion list. This is not
#      a comment claiming coverage; it is a computed comparison against
#      `git ls-files`.
#
#      This test exists because the sweep's own header once claimed
#      "tests/fm-fold-sweep.test.sh asserts the list covers the repo" while no
#      such file existed - and the real surface classes were missing every
#      harness hook directory (.claude, .codex, .grok, .opencode, .pi) and the
#      public skills/ tree. The claim was false and the sweep was under-counting.
#
#   2. ENFORCEMENT. "Enforcement that cannot be shown failing is not
#      enforcement." So the ratchet is exercised in both directions on a real
#      repository fixture: a newly introduced reach site must fail `--strict`,
#      and accounting for it must make `--strict` pass again.
#
# Every scenario runs against a throwaway git repo under TMPDIR. Nothing here
# mutates the firstmate checkout.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-fold-sweep.sh"
fm_test_tmproot TMP_ROOT fm-fold-sweep

command -v jq >/dev/null 2>&1 || fail "jq is required by the sweep"
command -v git >/dev/null 2>&1 || fail "git is required by the coverage gate"

# A miniature firstmate: enough repo shape for the sweep to run its own logic
# against, with tracked files we control exactly.
make_fixture() { # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/vendor/gs-demo" "$dir/docs"
  cp "$ROOT/bin/fm-fold-sweep.sh" "$ROOT/bin/fm-fold-lib.sh" "$dir/bin/"
  cat > "$dir/vendor/gs-demo/fold.json" <<'JSON'
{"fold":"gs-demo","command":"gs-demo","upstreamCommand":"demotool","umbrella":"GRyndStone"}
JSON
  printf '# demo\n' > "$dir/docs/notes.md"
  : > "$dir/vendor/sweep-allow.txt"
  ( cd "$dir" && git init -q . && fm_git_identity . && git add -A && git commit -qm init )
}

# The fixture's own surface classes must cover its own tracked files, or the
# coverage gate would fail for reasons unrelated to what is under test. The
# sweep's real class list already covers bin/, docs/, and vendor/.
FIX="$TMP_ROOT/repo"
make_fixture "$FIX"

sweep() { # <args...>
  ( cd "$FIX" && ./bin/fm-fold-sweep.sh "$@" ) 2>"$TMP_ROOT/err.txt"
}

test_coverage_passes_when_every_tracked_file_is_classified() {
  sweep --coverage >"$TMP_ROOT/out.txt" || fail "coverage must pass on a fully classified repo: $(cat "$TMP_ROOT/err.txt")"
  assert_grep 'enumeration complete' "$TMP_ROOT/out.txt" "coverage must state completeness explicitly"
  pass "coverage passes when every tracked file is reached by a surface class"
}

# The paired negative. Without it, --coverage could be a function that always
# succeeds, and the completeness claim would rest on nothing.
test_coverage_fails_on_an_unclassified_tracked_file() {
  local out status
  printf 'stray\n' > "$FIX/UNCLASSIFIED.md"
  ( cd "$FIX" && git add -A && git commit -qm stray ) >/dev/null 2>&1
  out=$(sweep --coverage) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "coverage must fail when a tracked file is reached by no surface class"
  assert_contains "$out" "UNCLASSIFIED.md" "the uncovered file must be named, not just counted"
  assert_contains "$out" "UNCOVERED" "the failure must say what kind of gap it is"
  # Restore the fixture to a complete state for the enforcement tests below.
  ( cd "$FIX" && git rm -q UNCLASSIFIED.md && git commit -qm unstray ) >/dev/null 2>&1
  sweep --coverage >/dev/null || fail "fixture should be complete again after removing the stray file"
  pass "coverage fails, and names the file, when a tracked file is unclassified"
}

test_strict_passes_when_every_reach_site_is_accounted_for() {
  sweep --strict >/dev/null || fail "strict must pass when no un-accounted reach site exists"
  pass "strict passes on a baseline with every reach site accounted for"
}

# The enforcement half of AC-2, shown failing rather than asserted.
test_strict_fails_on_a_newly_introduced_reach_site() {
  local out status
  cat > "$FIX/bin/fm-new-dependency.sh" <<'SH'
#!/usr/bin/env bash
demotool get --lease
SH
  ( cd "$FIX" && git add -A && git commit -qm newdep ) >/dev/null 2>&1
  out=$(sweep --strict) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "strict must exit 1 on a new un-accounted reach site; got $status"
  assert_contains "$out" "REACH" "the new site must be classified as REACH"
  assert_contains "$out" "fm-new-dependency.sh" "the new site must be named"
  assert_grep 'can still reach an upstream name' "$TMP_ROOT/err.txt" "the failure must be loud on stderr"
  pass "strict fails, and names the file, on a newly introduced reach site"
}

test_strict_passes_once_the_new_site_is_accounted_for() {
  local out
  printf '%s\n' "bin/fm-new-dependency.sh  accounted for by this test" >> "$FIX/vendor/sweep-allow.txt"
  out=$(sweep --strict) || fail "strict must pass once the new reach site is accounted for"
  assert_contains "$out" "ALLOWED" "an accounted site must be reported as ALLOWED"
  assert_contains "$out" "fm-new-dependency.sh" "an accounted site must stay visible, not disappear"
  # Accounting must not silently swallow a DIFFERENT new site.
  cat > "$FIX/bin/fm-second-dependency.sh" <<'SH'
#!/usr/bin/env bash
demotool status
SH
  ( cd "$FIX" && git add -A && git commit -qm seconddep ) >/dev/null 2>&1
  sweep --strict >/dev/null && fail "accounting for one site must not exempt another"
  pass "strict passes once accounted for, and still catches the next new site"
}

# The real repository must satisfy the completeness gate, not just the fixture.
# This is the assertion that would have caught the missing hook directories.
test_real_repo_enumeration_is_complete() {
  "$SWEEP" --coverage >"$TMP_ROOT/real.txt" 2>&1 ||
    fail "the firstmate repo itself must satisfy the coverage gate: $(cat "$TMP_ROOT/real.txt")"
  assert_grep 'enumeration complete' "$TMP_ROOT/real.txt" "the real repo must report completeness"
  pass "the firstmate repo's own enumeration is complete"
}

# Hook directories are the specific surface AC-2's anti-clause calls out, and the
# specific surface this sweep originally missed. Pin them by name so a future
# edit cannot quietly drop them again.
test_hook_surfaces_are_declared() {
  local classes
  classes=$(grep -A16 '^surface_classes()' "$SWEEP")
  for dir in .claude .codex .grok .opencode .pi; do
    assert_contains "$classes" "$dir" "hook surface $dir must be a declared surface class"
  done
  assert_contains "$classes" "skills" "the public skills/ tree must be a declared surface class"
  pass "harness hook directories and public skills are declared surfaces"
}

test_coverage_passes_when_every_tracked_file_is_classified
test_coverage_fails_on_an_unclassified_tracked_file
test_strict_passes_when_every_reach_site_is_accounted_for
test_strict_fails_on_a_newly_introduced_reach_site
test_strict_passes_once_the_new_site_is_accounted_for
test_real_repo_enumeration_is_complete
test_hook_surfaces_are_declared
