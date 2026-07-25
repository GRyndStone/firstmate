#!/usr/bin/env bash
# Behavior tests for KURU lived-home read and product verification wrappers.
#
# The fixtures deliberately model the audit failure: the repository passes, the
# lived home can fail independently, and a KURU read command mints a door token
# unless firstmate runs it against a copied home.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
: "${ROOT:?tests/lib.sh did not set ROOT}"

READ="$ROOT/bin/fm-kuru-home-read.sh"
CHECK="$ROOT/bin/fm-kuru-product-check.sh"

tree_snapshot() {
  local root=$1 out=$2
  python3 - "$root" >"$out" <<'PY'
import hashlib
import json
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])

def mtime_ns(st):
    return getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000))

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def record(path, rel):
    st = os.lstat(path)
    mode = st.st_mode
    rec = {"path": rel, "mode": stat.S_IMODE(mode), "mtime_ns": mtime_ns(st)}
    if stat.S_ISLNK(mode):
        rec["type"] = "symlink"
        rec["target"] = os.readlink(path)
    elif stat.S_ISDIR(mode):
        rec["type"] = "dir"
    elif stat.S_ISREG(mode):
        rec["type"] = "file"
        rec["sha256"] = digest(path)
        rec["size"] = st.st_size
    else:
        rec["type"] = "other"
        rec["size"] = st.st_size
    print(json.dumps(rec, sort_keys=True, separators=(",", ":")))

def walk(path, rel):
    record(path, rel)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        return
    for name in sorted(os.listdir(path)):
        child = os.path.join(path, name)
        child_rel = name if rel == "." else f"{rel}/{name}"
        walk(child, child_rel)

walk(root, ".")
PY
}

assert_tree_same() {
  local before=$1 after=$2 label=$3
  cmp -s "$before" "$after" || fail "$label"$'\n'"$(diff -u "$before" "$after" | sed -n '1,60p')"
}

make_home_with_mutating_read() {
  local dir=$1
  mkdir -p "$dir/tools"
  cat >"$dir/tools/read-seat" <<'SH'
#!/usr/bin/env bash
set -eu
mkdir -p state/door-tokens
printf '{"type":"kuru-door-token"}\n' >"state/door-tokens/fixture-token.json"
printf 'seat observed\n'
SH
  chmod +x "$dir/tools/read-seat"
}

make_product_surface() {
  # make_product_surface <dir> <pass|fail> <mint|clean>
  local dir=$1 result=$2 mint=$3
  mkdir -p "$dir"
  cat >"$dir/verify-product" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${MINT_DOOR_TOKEN:-0}" = "1" ]; then
  mkdir -p state/door-tokens
  printf '{"type":"kuru-door-token"}\n' >"state/door-tokens/verify-token.json"
fi
if [ -f FAIL_PRODUCT ]; then
  printf 'fixture product failure\n'
  exit 1
fi
printf 'fixture product pass\n'
SH
  chmod +x "$dir/verify-product"
  if [ "$result" = fail ]; then
    printf 'fail\n' >"$dir/FAIL_PRODUCT"
  fi
  if [ "$mint" = mint ]; then
    cat >"$dir/verify-product.env" <<'EOF'
MINT_DOOR_TOKEN=1
EOF
    cat >"$dir/verify-product-wrapper" <<'SH'
#!/usr/bin/env bash
set -eu
. ./verify-product.env
export MINT_DOOR_TOKEN
exec ./verify-product
SH
    chmod +x "$dir/verify-product-wrapper"
  fi
}

test_legacy_read_path_is_red() {
  local tmp home before after rc
  fm_test_tmproot tmp fm-kuru-read-red
  home="$tmp/home"
  make_home_with_mutating_read "$home"
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  tree_snapshot "$home" "$before"
  rc=0
  (cd "$home" && ./tools/read-seat >/dev/null) || rc=$?
  expect_code 0 "$rc" "legacy fixture read should succeed so mutation is the only failure"
  tree_snapshot "$home" "$after"
  cmp -s "$before" "$after" && fail "legacy read fixture did not mutate the home"
  [ -f "$home/state/door-tokens/fixture-token.json" ] || fail "legacy read did not mint the expected token"
  pass "fm-kuru-home-read: deliberate legacy read fixture is red before the wrapper"
}

test_home_read_wrapper_keeps_source_identical() {
  local tmp home before after out rc
  fm_test_tmproot tmp fm-kuru-read-green
  home="$tmp/home"
  make_home_with_mutating_read "$home"
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  tree_snapshot "$home" "$before"
  rc=0
  out=$("$READ" --home "$home" -- ./tools/read-seat 2>&1) || rc=$?
  expect_code 0 "$rc" "firstmate copied-home read should succeed"
  assert_contains "$out" "FM_KURU_HOME_READ_SOURCE_UNCHANGED=1" "read wrapper must report source unchanged"
  tree_snapshot "$home" "$after"
  assert_tree_same "$before" "$after" "copied-home read changed the source home"
  [ ! -e "$home/state/door-tokens/fixture-token.json" ] || fail "copied-home read leaked a token into the source home"
  pass "fm-kuru-home-read: source home is byte-identical after a mutating KURU read"
}

test_product_check_rejects_divergent_home() {
  local tmp repo home out rc
  fm_test_tmproot tmp fm-kuru-product-red
  repo="$tmp/repo"
  home="$tmp/home"
  make_product_surface "$repo" pass clean
  make_product_surface "$home" fail clean
  rc=0
  out=$("$CHECK" --repo "$repo" --home "$home" --check ./verify-product 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "product check passed even though the lived-home copy failed"$'\n'"$out"
  assert_contains "$out" "surface=repository result=PASS" "divergent check must report repository pass"
  assert_contains "$out" "surface=lived-home-copy result=FAIL" "divergent check must report lived-home failure"
  assert_contains "$out" "FM_KURU_PRODUCT_CHECK_RESULT=not-verified" "divergent check must refuse verified"
  pass "fm-kuru-product-check: repo-green home-red is not verified"
}

test_product_check_verifies_both_surfaces() {
  local tmp repo home out rc
  fm_test_tmproot tmp fm-kuru-product-green
  repo="$tmp/repo"
  home="$tmp/home"
  make_product_surface "$repo" pass clean
  make_product_surface "$home" pass clean
  rc=0
  out=$("$CHECK" --repo "$repo" --home "$home" --check ./verify-product 2>&1) || rc=$?
  expect_code 0 "$rc" "product check should pass when both surfaces pass"
  assert_contains "$out" "surface=repository result=PASS" "verified check must report repository pass"
  assert_contains "$out" "surface=lived-home-copy result=PASS" "verified check must report lived-home pass"
  assert_contains "$out" "FM_KURU_PRODUCT_CHECK_RESULT=verified" "verified check must declare verified"
  pass "fm-kuru-product-check: both surfaces passing is verified"
}

test_product_check_keeps_source_home_identical() {
  local tmp repo home before after out rc
  fm_test_tmproot tmp fm-kuru-product-readonly
  repo="$tmp/repo"
  home="$tmp/home"
  make_product_surface "$repo" pass mint
  make_product_surface "$home" pass mint
  before="$tmp/before.snapshot"
  after="$tmp/after.snapshot"
  tree_snapshot "$home" "$before"
  rc=0
  out=$("$CHECK" --repo "$repo" --home "$home" --check ./verify-product-wrapper 2>&1) || rc=$?
  expect_code 0 "$rc" "product check should pass with a mutating home-side verifier run in a copy"
  assert_contains "$out" "FM_KURU_HOME_READ_SOURCE_UNCHANGED=1" "product check must route home checks through copied-home read"
  tree_snapshot "$home" "$after"
  assert_tree_same "$before" "$after" "product check mutated the source lived home"
  [ ! -e "$home/state/door-tokens/verify-token.json" ] || fail "product check leaked a token into the source home"
  pass "fm-kuru-product-check: home verification does not mutate the source home"
}

test_legacy_read_path_is_red
test_home_read_wrapper_keeps_source_identical
test_product_check_rejects_divergent_home
test_product_check_verifies_both_surfaces
test_product_check_keeps_source_home_identical
