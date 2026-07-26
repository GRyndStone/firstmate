#!/usr/bin/env bash
# Behavior tests for the custody identity guard (bin/fm-fold.sh, bin/fm-fold-lib.sh).
#
# THE PROBLEM BEING PROVEN AGAINST, measured on the captain's machine:
#
#   published npm quota-axi 0.1.13 dist sha256: 65f7a483142eb03...
#   locally built quota-axi 0.1.13 dist sha256: 18088837e9e9726...
#
# Identical version strings, different code. Any guard that compares version
# strings calls the wrong build current, so identity here is a CONTENT DIGEST.
#
# Every install below happens under FM_FOLD_PREFIX in a temp dir. Nothing touches
# the captain's real ~/.local/bin or npm prefix, and no test needs the network.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FOLD="$ROOT/bin/fm-fold.sh"
fm_test_tmproot TMP_ROOT fm-fold-identity

command -v jq >/dev/null 2>&1 || fail "jq is required by the custody machinery"

PREFIX="$TMP_ROOT/prefix"
mkdir -p "$PREFIX"
export FM_FOLD_PREFIX="$PREFIX"

# A stand-in for a real built artifact. The identity guard is about what is on
# disk at a path, so a script with known bytes proves it exactly as a 13MB Go
# binary would, without a two-minute build inside the test suite.
make_artifact() { # <path> <marker>
  cat > "$1" <<SH
#!/usr/bin/env bash
echo "$2"
SH
  chmod +x "$1"
}

test_install_records_a_digest_not_a_version() {
  local art="$TMP_ROOT/ours" identity
  make_artifact "$art" "ours-build-A"
  "$FOLD" install gs-quota --artifact "$art" >/dev/null || fail "install failed"
  identity=$("$FOLD" identity gs-quota) || fail "identity failed"
  assert_contains "$identity" '"sha256"' "identity must record a content digest"
  # The guard must not rest on a version string, which is the exact thing that
  # cannot distinguish the two 0.1.13 builds above.
  printf '%s' "$identity" | jq -e '.artifact.sha256 | test("^[0-9a-f]{64}$")' >/dev/null ||
    fail "identity sha256 must be a real 64-hex digest"
  pass "install records a content digest as identity"
}

test_verify_passes_on_our_own_artifact() {
  "$FOLD" verify gs-quota >/dev/null || fail "verify must pass on the artifact we installed"
  pass "verify passes on our own artifact"
}

# The core anti-replacement property: something else landing on our exact path is
# caught even when it is a plausible build. This is the paired negative to the
# test above - without it, verify could be a function that always returns 0.
test_verify_fails_when_the_artifact_is_replaced() {
  local target out status
  target=$(jq -r '.artifact.path' "$PREFIX/.gs-fold/gs-quota.identity.json")
  make_artifact "$target" "upstream-build-B"
  out=$("$FOLD" verify gs-quota 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "verify must fail when the artifact is replaced"
  assert_contains "$out" "NOT our artifact" "the failure must name the problem plainly"
  # Restore so later tests run against a verified install.
  make_artifact "$target" "ours-build-A"
  "$FOLD" verify gs-quota >/dev/null || fail "restore should re-verify"
  pass "verify fails loudly when our artifact is replaced in place"
}

# THE REQUIRED PROOF: an ordinary upstream-name install, performed for real with
# npm into a prefix that already holds ours, must leave ours untouched.
#
# The package is built locally so the test needs no network and installs nothing
# from the public registry. What is being proven is a NAME property - upstream
# occupies `quota-axi`, ours occupies `gs-quota` - so a local package with the
# upstream name proves it exactly as the published one would.
test_ordinary_upstream_install_cannot_replace_ours() {
  local before after npm_prefix pkg
  command -v npm >/dev/null 2>&1 || fail "npm is required for the anti-replacement proof"
  before=$(jq -r '.artifact.sha256' "$PREFIX/.gs-fold/gs-quota.identity.json")

  pkg="$TMP_ROOT/upstream-pkg"
  mkdir -p "$pkg/bin"
  cat > "$pkg/package.json" <<'JSON'
{"name":"quota-axi","version":"0.1.13","bin":{"quota-axi":"bin/quota-axi.js"}}
JSON
  cat > "$pkg/bin/quota-axi.js" <<'JS'
#!/usr/bin/env node
console.log("upstream quota-axi 0.1.13");
JS
  chmod +x "$pkg/bin/quota-axi.js"

  # A real `npm install -g` against a prefix holding ours.
  npm_prefix="$TMP_ROOT/npm-prefix"
  mkdir -p "$npm_prefix/bin"
  cp "$PREFIX/gs-quota" "$npm_prefix/bin/gs-quota"
  npm install -g --prefix "$npm_prefix" "$pkg" >/dev/null 2>&1 ||
    fail "the upstream-name install itself failed; the proof needs it to succeed"

  # It must have actually installed, or this proves nothing.
  assert_present "$npm_prefix/bin/quota-axi" "the upstream package must really have installed"
  # And ours must be byte-identical afterwards.
  after=$(shasum -a 256 "$npm_prefix/bin/gs-quota" | awk '{print $1}')
  [ "$after" = "$before" ] ||
    fail "an ordinary upstream install changed our artifact ($before -> $after)"
  "$FOLD" verify gs-quota >/dev/null ||
    fail "verify must still pass after an ordinary upstream install"
  pass "a real 'npm install -g quota-axi' leaves gs-quota byte-identical and verified"
}

# Name collision is the actual mechanism, so assert it rather than assuming it.
test_our_name_differs_from_upstream() {
  local ours upstream
  ours=$(jq -r '.command' "$ROOT/vendor/gs-quota/fold.json")
  upstream=$(jq -r '.upstreamCommand' "$ROOT/vendor/gs-quota/fold.json")
  [ "$ours" != "$upstream" ] ||
    fail "our command name must differ from upstream's or an install can overwrite it"
  [ "$ours" = "gs-quota" ] || fail "expected the proposed name gs-quota, got $ours"
  pass "our command name ($ours) cannot collide with upstream's ($upstream)"
}

test_uninstalled_fold_reports_honestly() {
  local out status
  out=$("$FOLD" verify gs-treehouse 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "verify must not pass for a fold that was never installed"
  assert_contains "$out" "not installed" "an uninstalled fold must say so plainly"
  pass "an uninstalled custody record reports honestly instead of passing"
}

test_install_records_a_digest_not_a_version
test_verify_passes_on_our_own_artifact
test_verify_fails_when_the_artifact_is_replaced
test_ordinary_upstream_install_cannot_replace_ours
test_our_name_differs_from_upstream
test_uninstalled_fold_reports_honestly
