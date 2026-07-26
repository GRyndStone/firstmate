#!/usr/bin/env bash
# Behavior tests for firstmate's incorporation ledger: bin/fm-deps.sh,
# bin/fm-deps-lib.sh, deps/incorporations.conf, deps/contracts/, and the DEPS:
# lines bin/fm-bootstrap.sh emits on the ordinary session-start path.
#
# Every case is driven by fixtures - fixture probe output, a fake npm, a fake
# registry answer - so nothing here touches the network or the operator's real
# toolchain. That is not only determinism: this suite runs on a machine whose
# live fleet depends on the very tools it is reasoning about, and a test that
# installed something would be a bug with consequences.
#
# The four cases the design has to survive are asserted directly:
#   * a stale component is reported on the path the operator already runs
#   * everything current produces SILENCE
#   * a contract-breaking change is caught while the version comparison and the
#     exit status both look perfectly healthy
#   * nothing upgrades without explicit approval, and a broken upgrade is
#     recovered from
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot TMP_ROOT fm-deps-tests

ASSERTIONS=0
check() { # <description>; increments the assertion count
  ASSERTIONS=$((ASSERTIONS + 1))
  pass "$1"
}

# Asserting "it printed nothing" is worthless on its own: a command that does not
# exist also prints nothing. Every silence assertion here therefore also requires
# that the thing which should have been silent actually RAN and succeeded, and is
# paired with a positive control proving the same code path does speak when it
# should.
assert_silent() { # <output> <status> <msg>
  [ "$2" = 0 ] || fail "$3 (expected a successful run, got exit $2)"$'\n'"--- output ---"$'\n'"$1"
  [ -z "$1" ] || fail "$3 (expected silence)"$'\n'"--- output ---"$'\n'"$1"
}

# The entrypoints must exist before anything asserts what they do, so a missing
# implementation fails here rather than passing an emptiness check downstream.
[ -x "$ROOT/bin/fm-deps.sh" ] || fail "bin/fm-deps.sh must exist and be executable"
[ -f "$ROOT/bin/fm-deps-lib.sh" ] || fail "bin/fm-deps-lib.sh must exist"
[ -f "$ROOT/deps/incorporations.conf" ] || fail "deps/incorporations.conf must exist"

# jq is a hard requirement rather than a skip condition: a json assertion that
# quietly does not run is exactly the "looks like coverage" failure this whole
# system exists to prevent, so its absence fails the suite instead.
command -v jq >/dev/null 2>&1 ||
  fail "jq is required by this suite (json contract assertions must never be skipped)"

# --- fixtures ---------------------------------------------------------------

# A quota-axi document shaped like the real one. $1 is the claude session window
# id, so a caller can rename exactly the identifier firstmate keys on and change
# nothing else - same schema, same field names, same everything.
quota_fixture() { # <claude-session-window-id> [schema-version]
  cat <<EOF
{
  "schemaVersion": ${2:-2},
  "generatedAt": "2026-07-25T22:28:37.262Z",
  "providers": [
    {
      "provider": "claude",
      "state": {"status": "fresh", "stale": false, "refreshedAt": "2026-07-25T22:28:37.037Z"},
      "windows": [
        {"id": "$1", "label": "session", "kind": "session", "percentUsed": 7, "percentRemaining": 93, "resetsAt": "2026-07-26T02:00:00.979165+00:00", "windowSeconds": 18000},
        {"id": "seven_day", "label": "week", "kind": "weekly", "percentUsed": 40, "percentRemaining": 60, "resetsAt": "2026-07-30T02:00:00.000Z", "windowSeconds": 604800},
        {"id": "model:fable", "kind": "model", "percentRemaining": 88, "resetsAt": "2026-07-26T02:00:00.000Z"}
      ]
    },
    {
      "provider": "grok",
      "state": {"status": "fresh", "stale": false, "refreshedAt": "2026-07-25T22:28:37.037Z"},
      "windows": [
        {"id": "credits", "kind": "credits", "percentRemaining": 71, "resetsAt": "2026-07-26T02:00:00.000Z", "windowSeconds": 86400},
        {"id": "product:grok_build", "kind": "credits", "percentRemaining": 71, "resetsAt": "2026-07-26T02:00:00.000Z", "windowSeconds": 86400}
      ]
    },
    {
      "provider": "cursor",
      "state": {"status": "auth_required"},
      "windows": []
    }
  ]
}
EOF
}

FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
quota_fixture five_hour > "$FIXTURES/quota-healthy.json"
quota_fixture five_hours > "$FIXTURES/quota-renamed.json"
quota_fixture five_hour 3 > "$FIXTURES/quota-schema3.json"
# The window whose meaning firstmate reads is intact by name but its measure has
# been restyled from a percent to an absolute count - the other half of a silent
# semantic change.
sed 's/"percentRemaining": 93/"percentRemaining": "93%"/' \
  "$FIXTURES/quota-healthy.json" > "$FIXTURES/quota-restyled.json"

# --- part A: the real inventory and the real pinned contracts ----------------
#
# These run the contract files this repo actually ships, not toy copies, so a
# regression in the shipped pins is caught here.

# shellcheck source=bin/fm-deps-lib.sh disable=SC1091
. "$ROOT/bin/fm-deps-lib.sh"

declare -F fm_deps_validate_inventory >/dev/null ||
  fail "fm_deps_validate_inventory must be defined by bin/fm-deps-lib.sh"
out=$(fm_deps_validate_inventory)
[ -z "$out" ] || fail "the shipped deps/incorporations.conf must validate; got:"$'\n'"$out"
# Positive control: the same validator, on a copy of the shipped file with one
# required field removed, must speak. Silence above is therefore a verdict, not
# an absence of machinery.
CONTROL_DEPS="$TMP_ROOT/control-deps"
mkdir -p "$CONTROL_DEPS/contracts"
grep -v '^purpose   = per-provider usage evidence' "$ROOT/deps/incorporations.conf" \
  > "$CONTROL_DEPS/incorporations.conf"
cp "$ROOT"/deps/contracts/*.contract "$CONTROL_DEPS/contracts/"
out=$(FM_DEPS_DIR="$CONTROL_DEPS" fm_deps_validate_inventory)
assert_contains "$out" "quota-axi: missing required field purpose" \
  "the validator must report a missing required field"
check "shipped inventory validates, and the validator does speak on a bad one"

# Ownership is part of the inventory, not folklore. Every non-system component
# must record who controls it, whether a fix can be landed there, which rung of
# the fallback ladder was chosen, and what breaks if it is wrong or absent.
for dep_id in quota-axi tasks-axi treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi orca; do
  for dep_field in control write-access fallback degrades-to; do
    fm_deps_field "$dep_id" "$dep_field" >/dev/null ||
      fail "$dep_id must declare $dep_field in deps/incorporations.conf"
  done
done
# write-access must carry its verification. "none" on its own is an assumption,
# and the assumption is what cost a merged fix.
out=$(fm_deps_field quota-axi write-access)
assert_contains "$out" "verified" "write-access must record how and when it was checked, not just a verdict"
assert_contains "$out" "none" "quota-axi write access is none on the captain's accounts"
check "every non-system component declares verified ownership and a fallback rung"

# The ladder rung must be a recorded decision, and the reflex answer is not it:
# quota-axi runs an own build BECAUSE a needed fix is blocked, while the rest of
# the same publisher's tools deliberately do not.
assert_contains "$(fm_deps_field quota-axi fallback)" "own-build-of-fork" \
  "quota-axi has a blocked fix in the routing critical path"
assert_contains "$(fm_deps_field tasks-axi fallback)" "upstream-and-wait" \
  "tasks-axi has a first-class degraded mode, so a fork is not justified"
assert_contains "$(fm_deps_field lavish-axi fallback)" "upstream-and-wait" \
  "lavish-axi is not in a critical path, so a fork is not justified"
check "the fallback ladder is a per-dependency decision, not fork-everything"

# The assertions above read the shipped file; this one proves the VALIDATOR is
# what requires those fields, so a future stanza cannot be added without them.
MISSING_OWN_DEPS="$TMP_ROOT/missing-ownership-deps"
mkdir -p "$MISSING_OWN_DEPS/contracts"
cp "$ROOT"/deps/contracts/*.contract "$MISSING_OWN_DEPS/contracts/"
grep -v '^control      = third-party:kunchenguid$' "$ROOT/deps/incorporations.conf" \
  > "$MISSING_OWN_DEPS/incorporations.conf"
out=$(FM_DEPS_DIR="$MISSING_OWN_DEPS" fm_deps_validate_inventory)
assert_contains "$out" "quota-axi: missing required field control" \
  "the validator must require ownership on a non-system component"
# ...and must not demand it of a system package, where firstmate patching git is
# not a real rung on anyone's ladder.
assert_not_contains "$out" "git: missing required field control" \
  "a system package must stay exempt from the ownership requirement"
check "the validator requires ownership on non-system components and exempts system ones"

# An unverified write-access verdict is a validation error, because an assumed
# answer is the thing this field exists to replace.
OWN_DEPS="$TMP_ROOT/ownership-deps"
mkdir -p "$OWN_DEPS/contracts"
cp "$ROOT"/deps/contracts/*.contract "$OWN_DEPS/contracts/"
sed 's/^write-access = none: verified 2026-07-25 - neither captain.*$/write-access = none/' \
  "$ROOT/deps/incorporations.conf" > "$OWN_DEPS/incorporations.conf"
out=$(FM_DEPS_DIR="$OWN_DEPS" fm_deps_validate_inventory)
assert_contains "$out" "quota-axi: write-access must state how it was verified" \
  "a bare write-access verdict must be rejected as an assumption"
sed 's/^fallback     = own-build-of-fork:.*$/fallback     = invent-something/' \
  "$ROOT/deps/incorporations.conf" > "$OWN_DEPS/incorporations.conf"
out=$(FM_DEPS_DIR="$OWN_DEPS" fm_deps_validate_inventory)
assert_contains "$out" "unrecognized fallback rung" "the ladder rungs are a closed set"
check "an assumed access answer or an invented ladder rung fails validation"

# 0.1.5 -> 0.1.13 is the exact pair this system was built after. Compared as
# strings rather than numbers, "5" sorts above "13" and the seven-release gap
# reads as already current - the check would have reported nothing wrong.
out=$(fm_deps_semver_cmp 0.1.5 0.1.13)
[ "$out" = "-1" ] || fail "0.1.5 must compare as older than 0.1.13, got '$out'"
[ "$(fm_deps_semver_cmp 0.1.13 0.1.5)" = "1" ] || fail "0.1.13 must compare as newer than 0.1.5"
[ "$(fm_deps_semver_cmp 0.1.13 0.1.13)" = "0" ] || fail "equal versions must compare equal"
check "version comparison is numeric, so 0.1.5 reads as behind 0.1.13"

# A greedy pattern swallows leading digits: `v24.12.0` extracting as `4.12.0`
# would silently compare a wrong installed version against a right latest.
out=$(printf 'v24.12.0\n' | fm_deps_extract_semver)
[ "$out" = "24.12.0" ] || fail "v24.12.0 must extract as 24.12.0, got '$out'"
out=$(printf 'no-mistakes version v1.37.0-12-g659ef8c (659ef8c)\n' | fm_deps_extract_semver)
[ "$out" = "1.37.0" ] || fail "a decorated version string must extract as 1.37.0, got '$out'"
check "version extraction reads the whole version, not a suffix of it"

# Declared, not inferred: bootstrap's required toolchain must be fully declared.
report_out=$(FM_DEPS_LEDGER=/dev/null FM_DEPS_CACHE="$TMP_ROOT/none.tsv" \
  "$ROOT/bin/fm-deps.sh" report 2>/dev/null)
report_status=$?
expect_code 0 "$report_status" "bin/fm-deps.sh report must run against the shipped inventory"
undeclared=$(printf '%s\n' "$report_out" | grep '^DEPS: undeclared:' || true)
[ -z "$undeclared" ] ||
  fail "every tool bin/fm-bootstrap.sh requires must have a stanza in deps/incorporations.conf; got:"$'\n'"$undeclared"
check "every bootstrap-required tool is declared in the inventory"

# The shipped quota-axi contract holds against a healthy document.
out=$(FM_DEPS_PROBE_QUOTA_AXI_JSON="cat $FIXTURES/quota-healthy.json" \
  fm_deps_contract_check quota-axi)
status=$?
expect_code 0 "$status" "healthy quota-axi document must satisfy the shipped contract (said: $out)"
check "shipped quota-axi contract passes a healthy document"

# THE CASE THIS EXISTS FOR. Same schema, same field names, same exit status,
# same version - one identifier renamed. Firstmate would read nothing and call
# it a legitimate absence.
out=$(FM_DEPS_PROBE_QUOTA_AXI_JSON="cat $FIXTURES/quota-renamed.json" \
  fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "a renamed window identifier must break the contract"
assert_contains "$out" "five_hour" "the failure must name the identifier that moved"
check "renamed window identifier breaks the shipped quota-axi contract"

# A schema bump must be reviewed, not absorbed.
out=$(FM_DEPS_PROBE_QUOTA_AXI_JSON="cat $FIXTURES/quota-schema3.json" \
  fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "a schemaVersion bump must break the contract"
assert_contains "$out" "schemaVersion" "the failure must name the schema version"
check "schemaVersion bump breaks the shipped quota-axi contract"

# A field that keeps its name but changes its type carries the same silence.
out=$(FM_DEPS_PROBE_QUOTA_AXI_JSON="cat $FIXTURES/quota-restyled.json" \
  fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "percentRemaining changing type must break the contract"
assert_contains "$out" "percentRemaining" "the failure must name the restyled field"
check "restyled percentRemaining breaks the shipped quota-axi contract"

# A window id pinned in the contract must still be one the source library
# actually keys on. Two files naming the same identifier can drift, and this
# asserts they cannot drift silently.
#
# The library's owner of that fact moved: window classification is now a
# per-provider role policy in fm_usage_source_registry rather than a general-id
# list. The point matters MORE under role policy, because the policy names ids
# explicitly - an id pinned here but absent from the policy is a window the
# contract guards and the router never classifies.
#
# The pinned ids are read out of the contract file rather than repeated here, so
# changing either side alone breaks this.
# shellcheck source=bin/fm-usage-source-lib.sh disable=SC1091
. "$ROOT/bin/fm-usage-source-lib.sh"
pinned_ids=$(sed -n 's/.*index("\([A-Za-z0-9_]*\)").*/\1/p' \
  "$ROOT/deps/contracts/quota-axi.contract" | sort -u)
[ -n "$pinned_ids" ] ||
  fail "anti-vacuity: no pinned window id could be read out of the quota-axi contract"
claude_policy=$(fm_usage_source_window_policy claude) ||
  fail "fm_usage_source_window_policy claude must resolve (the library surface this pin depends on)"
[ -n "$claude_policy" ] ||
  fail "anti-vacuity: claude's window role policy must not be empty"
for wid in $pinned_ids; do
  case "$claude_policy" in
    *"\"$wid\""*) ;;
    *) fail "deps/contracts/quota-axi.contract pins $wid, but claude's role policy does not name it: $claude_policy" ;;
  esac
done
check "every window id the contract pins is named in the provider role policy"

# The shipped no-mistakes contract pins the axi subcommand vocabulary
# bin/fm-crew-state.sh reads. It deliberately does NOT pin the version floor,
# which bin/fm-bootstrap.sh already owns - so this asserts both halves.
out=$(FM_DEPS_PROBE_NO_MISTAKES_AXI="printf 'Available Commands:\n  respond x\n  run y\n  status z\n'" \
  fm_deps_contract_check no-mistakes)
status=$?
expect_code 0 "$status" "a complete axi surface must satisfy the shipped contract (said: $out)"
check "shipped no-mistakes contract passes a complete axi surface"

out=$(FM_DEPS_PROBE_NO_MISTAKES_AXI="printf 'Available Commands:\n  respond x\n  run y\n'" \
  fm_deps_contract_check no-mistakes)
status=$?
expect_code 1 "$status" "an axi surface missing status must break the contract"
assert_contains "$out" "status" "the failure must name the missing subcommand"
check "shipped no-mistakes contract catches a renamed axi subcommand"

assert_no_grep "min-version" "$ROOT/deps/contracts/no-mistakes.contract" \
  "the no-mistakes version floor is bin/fm-bootstrap.sh's to own; a second copy would double-report it"
assert_absent "$ROOT/deps/contracts/tasks-axi.contract" \
  "tasks-axi compatibility is bin/fm-tasks-axi-lib.sh's to own; a pinned duplicate would double-report it"
assert_absent "$ROOT/deps/contracts/treehouse.contract" \
  "treehouse --lease is bin/fm-bootstrap.sh's to own; a pinned duplicate would double-report it"
check "pins do not duplicate a fact an existing probe already owns"

# The text and min-version assertion kinds still need coverage, so they are
# exercised against a fixture contract rather than by shipping a duplicate pin.
KIND_DEPS="$TMP_ROOT/kind-deps"
mkdir -p "$KIND_DEPS/contracts"
cp "$ROOT/deps/incorporations.conf" "$KIND_DEPS/incorporations.conf"
cat > "$KIND_DEPS/contracts/quota-axi.contract" <<'CONTRACT'
probe version = printf '0.2.2\n'
probe help    = printf 'Usage: thing update [--archive-body]\n'

#: the flag firstmate passes must still exist
text help  --archive-body
#: the version floor must hold
min-version version  0.1.1
CONTRACT
out=$(FM_DEPS_DIR="$KIND_DEPS" fm_deps_contract_check quota-axi)
status=$?
expect_code 0 "$status" "text and min-version assertions must pass a healthy probe (said: $out)"
# Change only the PROBE's output (the bracketed help text), leaving the
# assertion asking for the flag it always asked for - an upstream that dropped it.
sed -i.bak "s/\[--archive-body\]/[--gone]/" "$KIND_DEPS/contracts/quota-axi.contract"
out=$(FM_DEPS_DIR="$KIND_DEPS" fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "a text assertion must fail when its literal is absent"
assert_contains "$out" "--archive-body" "the failure must name the literal it looked for"
sed -i.bak "s/\[--gone\]/[--archive-body]/; s/min-version version  0.1.1/min-version version  9.9.9/" \
  "$KIND_DEPS/contracts/quota-axi.contract"
out=$(FM_DEPS_DIR="$KIND_DEPS" fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "a min-version assertion must fail below its floor"
assert_contains "$out" "installed 0.2.2, floor 9.9.9" "the failure must name both versions"
check "text and min-version assertion kinds hold and fail for their own reasons"

# An unrunnable check has proven nothing and must never be reported as a break.
out=$(FM_DEPS_PROBE_QUOTA_AXI_JSON="printf ''" fm_deps_contract_check quota-axi)
status=$?
expect_code 1 "$status" "empty probe output fails assertions rather than passing them"
check "an empty probe output fails closed instead of passing"

status=0
out=$(fm_deps_contract_check does-not-exist) || status=$?
expect_code 2 "$status" "a component with no contract file reports unevaluable, not broken"
check "a missing contract file reports unevaluable rather than broken"

# A contract file that declares a probe but pins nothing has proven nothing;
# reporting it as a pass would manufacture false coverage.
EMPTY_DEPS="$TMP_ROOT/empty-contract-deps"
mkdir -p "$EMPTY_DEPS/contracts"
cp "$ROOT/deps/incorporations.conf" "$EMPTY_DEPS/incorporations.conf"
printf 'probe json = echo {}\n' > "$EMPTY_DEPS/contracts/quota-axi.contract"
status=0
out=$(FM_DEPS_DIR="$EMPTY_DEPS" fm_deps_contract_check quota-axi) || status=$?
expect_code 2 "$status" "a contract that pins nothing must report unevaluable, not ok"
check "a contract that asserts nothing reports unevaluable rather than passing"

# --- part B: fixture inventory end to end -----------------------------------

FIXTURE_DEPS="$TMP_ROOT/deps"
mkdir -p "$FIXTURE_DEPS/contracts"
cat > "$FIXTURE_DEPS/incorporations.conf" <<'EOF'
[widget-axi]
kind      = npm
purpose   = fixture component with a registry and a pinned contract
relies-on = the shape its --json emits
currency  = npm:widget-axi
contract  = pinned
control      = third-party:fixture
write-access = none: verified in fixture
fallback     = upstream-and-wait: fixture component
degrades-to  = fixture component; nothing real breaks

[anchor]
kind      = binary
purpose   = fixture component whose currency cannot be established
relies-on = nothing that moves
currency  = none: fixture component with no registry to query
contract  = none: fixture component deliberately left unpinned
control      = third-party:fixture
write-access = unknown: not checked in fixture
fallback     = drop-and-degrade: fixture component
degrades-to  = fixture component; nothing real breaks
EOF
cat > "$FIXTURE_DEPS/contracts/widget-axi.contract" <<'EOF'
probe json = widget-axi --json

#: the widgets array firstmate parses is still there
json json  (.widgets | type) == "array"
EOF

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
CACHE="$HOME_DIR/state/dep-currency.tsv"
LEDGER="$HOME_DIR/data/dep-upgrades.md"

# A fake npm: `view` answers from FM_FAKE_REGISTRY_VERSION, `install -g` records
# what it was asked to do into a sentinel and moves the fake tool's version.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  root) printf '%s\n' "$FM_FAKE_NPM_ROOT" ;;
  view)
    # `view <pkg>@<version> dist.fileCount dist.unpackedSize` answers with the
    # PUBLISHED artifact's metadata; `view <pkg> version` answers with latest.
    case "${3:-}" in
      dist.fileCount)
        printf 'dist.fileCount = %s\n' "${FM_FAKE_PUBLISHED_FILES:-1}"
        printf 'dist.unpackedSize = %s\n' "${FM_FAKE_PUBLISHED_BYTES:-11}"
        ;;
      *) printf '%s\n' "${FM_FAKE_REGISTRY_VERSION:-2.0.0}" ;;
    esac
    ;;
  install)
    shift
    while [ "${1:-}" = "-g" ]; do shift; done
    printf '%s\n' "$1" >> "$FM_FAKE_INSTALL_LOG"
    printf '%s\n' "${1##*@}" > "$FM_FAKE_WIDGET_VERSION_FILE"
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/npm"
cat > "$FAKEBIN/widget-axi" <<'SH'
#!/usr/bin/env bash
version=$(cat "$FM_FAKE_WIDGET_VERSION_FILE" 2>/dev/null || echo 1.0.0)
case "${1:-}" in
  --version) printf '%s\n' "$version" ;;
  # 3.0.0 is the fixture's "upstream renamed the thing" release: same exit
  # status, same valid JSON, a different key. FM_FAKE_WIDGET_SHAPE forces that
  # same rename WITHOUT a version change, which is what a same-version swap
  # actually looks like: a local build, a republish, a hand-patched install.
  --json)
    [ -n "${FM_FAKE_PROBE_LOG:-}" ] && printf 'json\n' >> "$FM_FAKE_PROBE_LOG"
    if [ "${FM_FAKE_WIDGET_SHAPE:-}" = gadgets ] || [ "$version" = 3.0.0 ]; then
      printf '%s\n' '{"gadgets":[]}'
    else printf '%s\n' '{"widgets":[]}'
    fi
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/widget-axi"
WIDGET_VERSION_FILE="$TMP_ROOT/widget-version"
INSTALL_LOG="$TMP_ROOT/install-log"
printf '1.0.0\n' > "$WIDGET_VERSION_FILE"
: > "$INSTALL_LOG"
# A fake global npm tree, so the artifact reading has a real directory to read.
# The nested node_modules must be excluded from the reading, and it sits under a
# path that itself contains "node_modules" - the exact shape that makes a naive
# */node_modules/* exclusion silently drop every file.
NPM_ROOT="$TMP_ROOT/npm-root/lib/node_modules"
mkdir -p "$NPM_ROOT/widget-axi/dist" "$NPM_ROOT/widget-axi/node_modules/dep"
printf '{"name":"widget-axi"}\n' > "$NPM_ROOT/widget-axi/package.json"
printf 'published-body\n' > "$NPM_ROOT/widget-axi/dist/index.js"
printf 'not-part-of-the-artifact\n' > "$NPM_ROOT/widget-axi/node_modules/dep/x.js"
# The baseline: what the registry would report for this exact tree, so "the
# installed artifact IS the published artifact" is the fixture's default state
# and any divergence in a case below is that case's own doing.
BASE_READING=$(FM_DEPS_NPM_ROOT="$NPM_ROOT" bash -c ". '$ROOT/bin/fm-deps-lib.sh'; fm_deps_artifact_reading '$NPM_ROOT/widget-axi'")
PUB_FILES=$(printf '%s' "$BASE_READING" | awk '{print $1}')
PUB_BYTES=$(printf '%s' "$BASE_READING" | awk '{print $2}')

deps() { # run bin/fm-deps.sh against the fixture inventory and fixture home
  PATH="$FAKEBIN:$BASE_PATH" \
    FM_DEPS_DIR="${FM_DEPS_DIR:-$FIXTURE_DEPS}" \
    FM_DEPS_CACHE="$CACHE" \
    FM_DEPS_LEDGER="$LEDGER" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_FAKE_WIDGET_VERSION_FILE="$WIDGET_VERSION_FILE" \
    FM_FAKE_INSTALL_LOG="$INSTALL_LOG" \
    FM_FAKE_NPM_ROOT="$NPM_ROOT" \
    FM_FAKE_PUBLISHED_FILES="${FM_FAKE_PUBLISHED_FILES:-$PUB_FILES}" \
    FM_FAKE_PUBLISHED_BYTES="${FM_FAKE_PUBLISHED_BYTES:-$PUB_BYTES}" \
    FM_FAKE_REGISTRY_VERSION="${FM_FAKE_REGISTRY_VERSION:-1.0.0}" \
    FM_FAKE_WIDGET_SHAPE="${FM_FAKE_WIDGET_SHAPE:-}" \
    FM_FAKE_PROBE_LOG="${FM_FAKE_PROBE_LOG:-}" \
    "$ROOT/bin/fm-deps.sh" "$@"
}

# Everything current: the registry says exactly what is installed.
status=0
out=$(FM_FAKE_REGISTRY_VERSION=1.0.0 deps check 2>&1) || status=$?
assert_silent "$out" "$status" "a fully current fleet must produce SILENCE"
check "everything current produces silence"

# ...and the silence is not vacuous: the check really did evaluate the contract.
verdict=$(FM_DEPS_CACHE="$CACHE" awk -F '\t' '$1 == "widget-axi" { print $6 }' "$CACHE")
[ "$verdict" = ok ] || fail "silence must come from a passing contract, not a skipped one (verdict=$verdict)"
check "silence is backed by a recorded passing contract verdict"

# A published release nobody installed: reported on the ordinary path.
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps check 2>&1)
assert_contains "$out" "DEPS: widget-axi behind: installed 1.0.0, latest 1.4.0" \
  "a stale component must be reported"
assert_contains "$out" "bin/fm-deps.sh upgrade widget-axi --approve" \
  "the report must carry the exact deliberate-upgrade command"
check "a stale component is reported with its upgrade command"

# The component whose currency the inventory says cannot be established is never
# nagged about - otherwise the report trains the operator to ignore it.
assert_contains "$out" "widget-axi" \
  "the same report must be speaking, so the absence below is a decision and not an empty run"
assert_not_contains "$out" "anchor" "a declared-unknowable component must never be nagged about"
check "a declared-unknowable currency is never nagged about"

# Offline: a failed lookup must not erase what was already known.
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps refresh --offline 2>&1; FM_FAKE_REGISTRY_VERSION=1.4.0 deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi behind: installed 1.0.0, latest 1.4.0" \
  "an offline refresh must preserve the last known registry answer"
check "an offline refresh preserves the cached currency answer"

# Offline long enough that "we do not know" is itself the news.
old=$(( $(date +%s) - 30 * 86400 ))
awk -F '\t' -v OFS='\t' -v e="$old" '$1 == "widget-axi" { $4 = e } { print }' "$CACHE" > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
out=$(deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi currency unchecked for 30 days" \
  "a long unchecked stretch must surface as its own problem"
check "a long unchecked stretch is reported rather than silently tolerated"

# ...but a short outage is not news.
recent=$(( $(date +%s) - 3600 ))
awk -F '\t' -v OFS='\t' -v e="$recent" '$1 == "widget-axi" { $4 = e; $3 = "1.0.0" } { print }' "$CACHE" > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
status=0
out=$(deps report 2>&1) || status=$?
assert_silent "$out" "$status" "a one-hour outage must stay silent"
check "a short outage stays silent"

# The network phase carries a whole-run budget, not just a per-lookup bound, so
# an unreachable registry costs session start seconds rather than one timeout per
# declared component. With the budget already spent, no lookup may happen at all.
awk -F '\t' -v OFS='\t' -v e="$recent" '$1 == "widget-axi" { $3 = "1.0.0"; $4 = e } { print }' "$CACHE" > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
FM_DEPS_REFRESH_BUDGET=0 FM_FAKE_REGISTRY_VERSION=7.7.7 deps refresh >/dev/null 2>&1
budgeted=$(awk -F '\t' '$1 == "widget-axi" { print $3 }' "$CACHE")
[ "$budgeted" = 1.0.0 ] ||
  fail "an exhausted network budget must skip the lookup entirely (cache says $budgeted)"
# Positive control: the same refresh with a budget does perform it.
FM_FAKE_REGISTRY_VERSION=7.7.7 deps refresh >/dev/null 2>&1
budgeted=$(awk -F '\t' '$1 == "widget-axi" { print $3 }' "$CACHE")
[ "$budgeted" = 7.7.7 ] || fail "a budgeted refresh must perform the lookup (cache says $budgeted)"
awk -F '\t' -v OFS='\t' -v e="$recent" '$1 == "widget-axi" { $3 = "1.0.0"; $4 = e } { print }' "$CACHE" > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
check "an exhausted network budget stops lookups instead of paying one timeout per component"

# An inventory that stops declaring why it opted out is itself a problem.
BROKEN_DEPS="$TMP_ROOT/deps-broken"
mkdir -p "$BROKEN_DEPS/contracts"
sed 's/^contract  = none: fixture component deliberately left unpinned$/contract  = none/' \
  "$FIXTURE_DEPS/incorporations.conf" > "$BROKEN_DEPS/incorporations.conf"
cp "$FIXTURE_DEPS/contracts/widget-axi.contract" "$BROKEN_DEPS/contracts/"
out=$(FM_DEPS_DIR="$BROKEN_DEPS" FM_DEPS_CACHE="$TMP_ROOT/broken.tsv" \
  FM_ROOT_OVERRIDE="$HOME_DIR" "$ROOT/bin/fm-deps.sh" report 2>&1)
assert_contains "$out" "DEPS: inventory invalid: anchor: contract none must state a reason" \
  "an unexplained opt-out must be reported"
check "an unexplained contract opt-out is reported"

# An undeclared dependency is visible, not inferred away.
UNDECLARED_ROOT="$TMP_ROOT/undeclared-root"
mkdir -p "$UNDECLARED_ROOT/bin"
printf '%s\n' '  *) TOOLS="widget-axi anchor mystery-tool" ;;' > "$UNDECLARED_ROOT/bin/fm-bootstrap.sh"
out=$(FM_DEPS_DIR="$FIXTURE_DEPS" FM_DEPS_CACHE="$TMP_ROOT/undeclared.tsv" \
  FM_ROOT_OVERRIDE="$UNDECLARED_ROOT" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-deps.sh" report 2>&1)
assert_contains "$out" "DEPS: undeclared: mystery-tool is required by bin/fm-bootstrap.sh" \
  "a required tool with no stanza must be reported"
assert_not_contains "$out" "DEPS: undeclared: widget-axi" \
  "a declared tool must not be reported as undeclared"
check "an undeclared required tool is reported"

# --- identity: a version number is not identity -----------------------------
#
# The captain's machine currently runs a quota-axi packed from his own fork,
# carrying an unmerged fix, reporting the same 0.1.13 string as the published
# release while containing different code. Everything a currency check looks at
# is intact; what is actually installed has moved.

# The artifact reading must exclude the package's OWN nested node_modules while
# NOT being fooled by the global lib/node_modules prefix in its own path.
reading=$(FM_DEPS_NPM_ROOT="$NPM_ROOT" bash -c ". '$ROOT/bin/fm-deps-lib.sh'; fm_deps_artifact_reading '$NPM_ROOT/widget-axi'")
[ -n "$reading" ] || fail "the artifact reading must find the package's files"
[ "$(printf '%s' "$reading" | awk '{print $1}')" = 2 ] ||
  fail "the reading must count the package's own files and exclude its nested node_modules (got: $reading)"
check "the artifact reading excludes nested node_modules without excluding the package itself"

# Declared published, but the installed bytes are not the published bytes.
: > "$CACHE"
published_bytes=$PUB_BYTES
FM_FAKE_PUBLISHED_FILES="$PUB_FILES" FM_FAKE_PUBLISHED_BYTES=$((published_bytes + 500)) \
  FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
out=$(FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi is NOT the published package it claims to be" \
  "an install that diverges from the published artifact must be reported"
assert_contains "$out" "both calling themselves 1.0.0" \
  "the report must show that the version string is identical while the artifact is not"
assert_not_contains "$out" "widget-axi behind" \
  "the version comparison is perfectly healthy - that is the whole point"
check "an install that is not the published artifact is caught while its version looks current"

# ...and when the inventory declares the local build, it is the known truth and
# says nothing. A declared state is not a finding.
LOCAL_DEPS="$TMP_ROOT/local-build-deps"
mkdir -p "$LOCAL_DEPS/contracts"
cp "$FIXTURE_DEPS/contracts/widget-axi.contract" "$LOCAL_DEPS/contracts/"
sed 's|^contract  = pinned$|contract  = pinned\nprovenance = local-build: fixture fork build carrying an unmerged fix|' \
  "$FIXTURE_DEPS/incorporations.conf" > "$LOCAL_DEPS/incorporations.conf"
status=0
out=$(FM_DEPS_DIR="$LOCAL_DEPS" FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1) || status=$?
assert_silent "$out" "$status" "a declared local build is the known truth and must not be reported"
check "a declared local build is recorded rather than reported"

# THE REGRESSION THAT WOULD OTHERWISE BE INVISIBLE: `npm install -g` replaces the
# local build with the published package, the version string does not move, and
# the fix it carried is silently gone.
: > "$CACHE"
FM_DEPS_DIR="$LOCAL_DEPS" FM_FAKE_PUBLISHED_FILES="$PUB_FILES" FM_FAKE_PUBLISHED_BYTES="$published_bytes" \
  FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
out=$(FM_DEPS_DIR="$LOCAL_DEPS" FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi local build has been replaced by the published package" \
  "a local build silently replaced by the published package must be reported"
assert_contains "$out" "the fix it carried is no longer installed" \
  "the report must say what was actually lost"
check "a local build silently replaced by the published package is caught"

# Continuity: no registry involved at all. The code moves under an unchanged
# version string, and that alone is worth surfacing.
: > "$CACHE"
FM_FAKE_PUBLISHED_FILES="$PUB_FILES" FM_FAKE_PUBLISHED_BYTES="$published_bytes" \
  FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
printf 'a-different-body-entirely\n' > "$NPM_ROOT/widget-axi/dist/index.js"
deps refresh --offline >/dev/null 2>&1
out=$(deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi artifact changed under an unchanged version" \
  "code moving under an unchanged version must be caught with no network at all"
assert_contains "$out" "under an unchanged version 1.0.0" "the report must name the version that did not move"
check "the code moving under an unchanged version is caught offline"
printf 'published-body\n' > "$NPM_ROOT/widget-axi/dist/index.js"

# Currency for a declared local build must not hand over an upgrade command that
# would silently discard it.
: > "$CACHE"
FM_DEPS_DIR="$LOCAL_DEPS" FM_FAKE_PUBLISHED_FILES="$PUB_FILES" FM_FAKE_PUBLISHED_BYTES=$((published_bytes + 500)) \
  FM_FAKE_REGISTRY_VERSION=1.6.0 deps refresh >/dev/null 2>&1
out=$(FM_DEPS_DIR="$LOCAL_DEPS" FM_FAKE_REGISTRY_VERSION=1.6.0 deps report 2>&1)
assert_contains "$out" "upstream released 1.6.0 while this home runs a local build of 1.0.0" \
  "an upstream release must still be reported for a local build"
assert_not_contains "$out" "upgrade widget-axi --approve" \
  "the report must not hand over a command that would silently discard the local build"
check "an upstream release is reported for a local build without offering to discard it"
: > "$CACHE"

# --- the same-version contract regression -----------------------------------
#
# This is the defect the first version of this tool shipped with, and it defeated
# the tool's core purpose. Re-verification was keyed on the version STRING alone
# (installed != contract_version), so once a verdict was cached at version X the
# contract was never re-checked while installed stayed X. Both directions failed:
#   * a same-version swap that BROKE the contract stayed cached as `ok`, and the
#     break was invisible - the exact rename class the contract exists to catch
#   * a verdict latched `broken` never cleared after a same-version repair, and
#     a stuck alarm destroys the trust that makes silence meaningful
# The fix keys re-verification on artifact identity, so both directions re-verify.
#
# verdict_now: read the cached contract verdict (cache field 6) directly, so each
# planted state is OBSERVED rather than inferred from a report line.
verdict_now() { awk -F '\t' '$1 == "widget-axi" { print $6 }' "$CACHE"; }
# The installed artifact, mutated in place. Version string never changes.
swap_artifact() { printf '%s\n' "$1" > "$NPM_ROOT/widget-axi/dist/index.js"; }

: > "$CACHE"
swap_artifact 'published-body'
FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
state_ok=$(verdict_now)
version_at_ok=$(awk -F '\t' '$1 == "widget-axi" { print $2 }' "$CACHE")

# Same version, different build, contract-breaking shape.
swap_artifact 'swapped-body-that-is-a-different-length-entirely'
FM_FAKE_WIDGET_SHAPE=gadgets FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
state_broken=$(verdict_now)
version_at_broken=$(awk -F '\t' '$1 == "widget-axi" { print $2 }' "$CACHE")
out=$(FM_FAKE_WIDGET_SHAPE=gadgets FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1)

# Anti-vacuity: both planted states must actually have been observed, and the
# version must genuinely have been unchanged across the swap. Without this the
# case could pass while the fixture never reached `ok` at all, or while the
# "swap" quietly moved the version and re-verified for the old reason.
[ "$state_ok" = ok ] ||
  fail "anti-vacuity: the pre-swap state must have been observed as ok, got '$state_ok'"
[ "$state_broken" = broken ] ||
  fail "anti-vacuity: the post-swap state must have been observed as broken, got '$state_broken'"
[ -n "$version_at_ok" ] && [ "$version_at_ok" = "$version_at_broken" ] ||
  fail "anti-vacuity: the version must be unchanged across the swap (ok=$version_at_ok broken=$version_at_broken)"
assert_contains "$out" "widget-axi CONTRACT BROKEN"   "a same-version swap that breaks the contract must be reported, not absorbed"
assert_not_contains "$out" "widget-axi behind"   "the version comparison stays healthy across the swap - that is why it cannot be the key"
check "a contract-breaking swap under an UNCHANGED version is re-verified and caught"

# The other direction: repair it, still without moving the version.
swap_artifact 'repaired-body'
FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
state_repaired=$(verdict_now)
version_at_repaired=$(awk -F '\t' '$1 == "widget-axi" { print $2 }' "$CACHE")
out=$(FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1)

[ "$version_at_repaired" = "$version_at_ok" ] ||
  fail "anti-vacuity: the repair must not have moved the version (was $version_at_ok, now $version_at_repaired)"
[ "$state_repaired" = ok ] ||
  fail "a same-version repair must clear the latched broken verdict, got '$state_repaired'"
assert_not_contains "$out" "CONTRACT BROKEN" \
  "a same-version repair must clear the latched broken verdict from the report"
# The report is deliberately NOT silent here, and that is correct: the artifact
# really did change under an unchanged version, and saying so is the identity
# finding doing its job. Silence would mean the swap went unnoticed - the very
# thing this section exists to prevent. So the assertion is "the stale alarm
# cleared", not "everything went quiet".
assert_contains "$out" "widget-axi artifact changed under an unchanged version" \
  "the identity finding must still report the swap the repair did not undo"
check "a same-version repair clears a latched broken verdict without FM_DEPS_FORCE_CONTRACT"

# The operator is told how to force a re-check even so, because someone staring
# at an alarm they believe they already fixed should not have to find this in a
# source file.
swap_artifact 'broken-again-body'
FM_FAKE_WIDGET_SHAPE=gadgets FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
out=$(FM_FAKE_WIDGET_SHAPE=gadgets FM_FAKE_REGISTRY_VERSION=1.0.0 deps report 2>&1)
assert_contains "$out" "FM_DEPS_FORCE_CONTRACT=1"   "a broken verdict must name the way to re-check it now"
check "a broken contract line tells the operator how to force re-verification"

# Keying on identity must not degrade into "re-probe every time". The cache
# exists so the ordinary session-start path costs nothing when nothing moved,
# and an identity that is never RECORDED alongside the verdict would compare
# against an empty value forever - re-running the probe on every refresh while
# still passing every case above. Counting probes is what tells those apart.
PROBE_LOG="$TMP_ROOT/probe-log"
: > "$CACHE"
swap_artifact 'published-body'
: > "$PROBE_LOG"
FM_FAKE_PROBE_LOG="$PROBE_LOG" FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
probes_after_first=$(wc -l < "$PROBE_LOG" | tr -d '[:space:]')
FM_FAKE_PROBE_LOG="$PROBE_LOG" FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
probes_after_second=$(wc -l < "$PROBE_LOG" | tr -d '[:space:]')
swap_artifact 'moved-again-body'
FM_FAKE_PROBE_LOG="$PROBE_LOG" FM_FAKE_REGISTRY_VERSION=1.0.0 deps refresh >/dev/null 2>&1
probes_after_swap=$(wc -l < "$PROBE_LOG" | tr -d '[:space:]')

[ "$probes_after_first" -gt 0 ] ||
  fail "anti-vacuity: the first refresh must actually have run the contract probe"
[ "$probes_after_second" = "$probes_after_first" ] ||
  fail "an unchanged install must not re-run the contract probe (ran $probes_after_first then $probes_after_second)"
[ "$probes_after_swap" -gt "$probes_after_second" ] ||
  fail "anti-vacuity: a changed artifact must re-run the probe (stayed at $probes_after_swap)"
check "an unchanged install costs no probe, while a changed one is re-verified"

# Restore the fixture tree for the cases that follow.
swap_artifact 'published-body'
: > "$CACHE"

# A behind-hint must name a path that actually works. `upgrade` automates npm
# components only, so offering it for a brew or hand-installed component would
# send the operator to a command that declines - and hints that decline teach
# operators to ignore hints.
BREW_DEPS="$TMP_ROOT/brew-deps"
mkdir -p "$BREW_DEPS/contracts"
sed -e 's/^currency  = npm:widget-axi/currency  = brew:widgetformula/' \
  -e 's/^contract  = pinned/contract  = none: fixture component, hint shape is what is under test/' \
  "$FIXTURE_DEPS/incorporations.conf" > "$BREW_DEPS/incorporations.conf"
cat > "$FAKEBIN/brew" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = info ] && printf '{"formulae":[{"versions":{"stable":"9.9.9"}}]}\n'
exit 0
SH
chmod +x "$FAKEBIN/brew"
FM_DEPS_DIR="$BREW_DEPS" FM_DEPS_CACHE="$TMP_ROOT/brew.tsv" deps refresh >/dev/null 2>&1
out=$(FM_DEPS_DIR="$BREW_DEPS" FM_DEPS_CACHE="$TMP_ROOT/brew.tsv" deps report 2>&1)
assert_contains "$out" "widget-axi behind" \
  "anti-vacuity: the brew-sourced component must actually be reported behind"
assert_contains "$out" "brew upgrade widgetformula" \
  "a brew-sourced component must be pointed at the command that actually upgrades it"
assert_not_contains "$out" "fm-deps.sh upgrade widget-axi --approve" \
  "it must not offer an automated upgrade path that install_version refuses"
check "a behind-hint names the upgrade path that actually applies to that component"

# --- part C: upgrade is deliberate, recorded, and recoverable ---------------

printf '1.0.0\n' > "$WIDGET_VERSION_FILE"
: > "$INSTALL_LOG"
FM_FAKE_REGISTRY_VERSION=1.4.0 deps refresh >/dev/null 2>&1

status=0
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps upgrade widget-axi 2>&1) || status=$?
expect_code 2 "$status" "an upgrade without approval must refuse"
assert_contains "$out" "REFUSED" "the refusal must be explicit"
assert_contains "$out" "would move widget-axi from 1.0.0 to 1.4.0" \
  "the refusal must say exactly what it declined to do"
[ ! -s "$INSTALL_LOG" ] || fail "nothing may be installed without approval; installer ran: $(cat "$INSTALL_LOG")"
[ "$(cat "$WIDGET_VERSION_FILE")" = 1.0.0 ] || fail "the installed version must be untouched without approval"
check "an upgrade without approval refuses and installs nothing"

# Approved, but the fleet is live. Changing a tool under running crewmates is
# not a routine call.
touch "$HOME_DIR/state/fix-login-k3.meta"
status=0
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps upgrade widget-axi --approve 2>&1) || status=$?
expect_code 2 "$status" "an approved upgrade must still refuse while the fleet is in flight"
assert_contains "$out" "fix-login-k3" "the refusal must name the work in flight"
[ ! -s "$INSTALL_LOG" ] || fail "nothing may be installed while the fleet is in flight"
check "an approved upgrade refuses while the fleet is in flight"

# The captain can override that, explicitly.
status=0
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps upgrade widget-axi --approve --despite-fleet 2>&1) || status=$?
expect_code 0 "$status" "an explicit --despite-fleet upgrade must proceed (said: $out)"
assert_grep "widget-axi@1.4.0" "$INSTALL_LOG" "the installer must have been asked for the target version"
assert_grep "widget-axi 1.0.0 -> 1.4.0 upgrade contract=ok" "$LEDGER" \
  "the ledger must record what moved from where to where"
check "an explicitly authorized upgrade proceeds and is recorded"
rm -f "$HOME_DIR/state/fix-login-k3.meta"

# THE OTHER CASE THIS EXISTS FOR: an upgrade that succeeds by every ordinary
# measure and breaks the contract anyway.
: > "$INSTALL_LOG"
status=0
out=$(FM_FAKE_REGISTRY_VERSION=3.0.0 deps upgrade widget-axi --approve 2>&1) || status=$?
expect_code 3 "$status" "a contract-breaking upgrade must not exit as a success"
assert_contains "$out" "PINNED CONTRACT BROKE" "the break must be stated plainly"
assert_contains "$out" "bin/fm-deps.sh rollback widget-axi --approve" \
  "the operator must be handed the exact recovery command"
assert_grep "widget-axi 1.4.0 -> 3.0.0 upgrade contract=broken" "$LEDGER" \
  "the ledger must record the break alongside the move"
check "a contract-breaking upgrade fails loudly and hands over the recovery command"

# The break is on the ordinary path too, and it is there while the version
# comparison and the exit status both look healthy.
out=$(FM_FAKE_REGISTRY_VERSION=3.0.0 deps report 2>&1)
assert_contains "$out" "DEPS: widget-axi CONTRACT BROKEN at installed 3.0.0" \
  "a broken contract must be reported on the ordinary path"
assert_not_contains "$out" "widget-axi behind" \
  "the break must surface even though the installed version IS the latest"
status=0
PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_WIDGET_VERSION_FILE="$WIDGET_VERSION_FILE" \
  widget-axi --json >/dev/null 2>&1 || status=$?
expect_code 0 "$status" "the upgraded tool still exits 0 - the exit status proves nothing"
check "a contract break is caught while version and exit status both look healthy"

# Recovery, exercised rather than described.
status=0
out=$(deps rollback widget-axi 2>&1) || status=$?
expect_code 2 "$status" "a rollback without approval must refuse too"
assert_contains "$out" "would move widget-axi from 3.0.0 back to 1.4.0" \
  "the rollback must resolve its target from the ledger"
check "a rollback without approval refuses"

status=0
out=$(deps rollback widget-axi --approve 2>&1) || status=$?
expect_code 0 "$status" "an approved rollback must succeed (said: $out)"
assert_contains "$out" "pinned contract holds again" "the rollback must re-verify the contract"
[ "$(cat "$WIDGET_VERSION_FILE")" = 1.4.0 ] || fail "the rollback must restore the recorded previous version"
assert_grep "widget-axi 3.0.0 -> 1.4.0 rollback contract=ok" "$LEDGER" \
  "the ledger must record the recovery as well as the break"
check "an approved rollback restores the previous version and re-verifies the contract"

status=0
out=$(FM_FAKE_REGISTRY_VERSION=1.4.0 deps report 2>&1) || status=$?
assert_silent "$out" "$status" "after recovery the report must be silent again"
check "the report is silent again after recovery"

# --- access: verified, never assumed ----------------------------------------

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = api ] && [ "${3:-}" = "--jq" ]; then
  printf '%s\n' "${FM_FAKE_PERMISSIONS:-{\"admin\":false,\"maintain\":false,\"push\":false,\"triage\":false,\"pull\":true}}"
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/gh-axi"
ACCESS_DEPS="$TMP_ROOT/access-deps"
mkdir -p "$ACCESS_DEPS/contracts"
cp "$FIXTURE_DEPS/contracts/widget-axi.contract" "$ACCESS_DEPS/contracts/"
sed 's|^currency  = npm:widget-axi$|currency  = npm:widget-axi\nrepo         = someone/widget-axi|' \
  "$FIXTURE_DEPS/incorporations.conf" > "$ACCESS_DEPS/incorporations.conf"

out=$(FM_DEPS_DIR="$ACCESS_DEPS" deps access-check widget-axi 2>&1)
assert_contains "$out" '"push":false' "the check must report the permissions it actually read"
assert_contains "$out" "write-access = none: verified" \
  "it must hand back the exact line to record, with its verification"
check "repository access is read and reported, not assumed"

out=$(FM_FAKE_PERMISSIONS='{"admin":true,"push":true}' FM_DEPS_DIR="$ACCESS_DEPS" deps access-check widget-axi 2>&1)
assert_contains "$out" "write-access = yes: verified" "push access must be recognized"
check "an account that can land a fix is recognized as such"

# An unreadable answer is "unknown", never "yes". Assuming access is exactly the
# failure this check exists to remove.
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/gh-axi"
out=$(FM_DEPS_DIR="$ACCESS_DEPS" deps access-check widget-axi 2>&1)
assert_contains "$out" "unknown: could not read permissions" \
  "an unreadable permission answer must be unknown"
assert_not_contains "$out" "write-access = yes" "an unreadable answer must never read as access"
check "an unreadable access answer is unknown, never assumed to be yes"
rm -f "$FAKEBIN/gh-axi"

# --- part D: it arrives on the path the operator already runs ---------------

bootstrap_deps_lines() { # runs the real bootstrap and keeps only its DEPS lines
  PATH="$FAKEBIN:$BASE_PATH" \
    FM_DEPS_DIR="$FIXTURE_DEPS" \
    FM_DEPS_CACHE="$CACHE" \
    FM_DEPS_NPM="$FAKEBIN/npm" \
    FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_FAKE_WIDGET_VERSION_FILE="$WIDGET_VERSION_FILE" \
    FM_FAKE_INSTALL_LOG="$INSTALL_LOG" \
    FM_FAKE_REGISTRY_VERSION="${FM_FAKE_REGISTRY_VERSION:-1.4.0}" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^DEPS: ' || true
}

# Positive control first: with a stale cache, session start MUST speak. Only
# then does the silence below mean the wiring works and found nothing wrong.
FM_FAKE_REGISTRY_VERSION=9.9.9 deps refresh >/dev/null 2>&1
control=$(bootstrap_deps_lines)
assert_contains "$control" "DEPS: widget-axi behind" \
  "session start must be wired to the report at all"
FM_FAKE_REGISTRY_VERSION=1.4.0 deps refresh >/dev/null 2>&1
out=$(bootstrap_deps_lines)
[ -z "$out" ] || fail "session start must be silent about a current fleet; got:"$'\n'"$out"
check "session start says nothing about dependencies when all are current"

FM_FAKE_REGISTRY_VERSION=1.9.0 deps refresh >/dev/null 2>&1
out=$(bootstrap_deps_lines)
assert_contains "$out" "DEPS: widget-axi behind: installed 1.4.0, latest 1.9.0" \
  "session start must report a stale component without being asked"
check "session start reports a stale component on the ordinary path"

# A read-only session must not perform the refresh write the lock holder owns.
# The read-only path must not perform the lookup the lock holder owns. Age the
# cache so a refresh IS due - otherwise "no lookup happened" would be true for a
# reason that has nothing to do with the read-only rule - then prove the
# detect-only run left the stale answer alone and the locked run does update it.
[ -s "$CACHE" ] || fail "the currency cache must exist before asserting it is untouched"
stale_epoch=$(( $(date +%s) - 30 * 86400 ))
awk -F '\t' -v OFS='\t' -v e="$stale_epoch" '$1 == "widget-axi" { $4 = e } { print }' "$CACHE" > "$CACHE.tmp"
mv "$CACHE.tmp" "$CACHE"
readonly_out=$(FM_FAKE_REGISTRY_VERSION=2.5.0 bootstrap_deps_lines)
assert_contains "$readonly_out" "DEPS: widget-axi behind: installed 1.4.0, latest 1.9.0" \
  "the read-only session must still report the cached answer"
assert_not_contains "$readonly_out" "2.5.0" \
  "a detect-only bootstrap must not perform the registry lookup the lock holder owns"
cached_latest=$(awk -F '\t' '$1 == "widget-axi" { print $3 }' "$CACHE")
[ "$cached_latest" = 1.9.0 ] ||
  fail "a detect-only bootstrap must not rewrite the currency answer (cache now says $cached_latest)"
check "a read-only session reports from cache without performing the lookup"

# Positive control on the same wiring: the locked path DOES refresh, so the
# assertion above is about the read-only rule and not about a refresh that never
# works at all.
PATH="$FAKEBIN:$BASE_PATH" \
  FM_DEPS_DIR="$FIXTURE_DEPS" FM_DEPS_CACHE="$CACHE" FM_DEPS_NPM="$FAKEBIN/npm" \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_FAKE_WIDGET_VERSION_FILE="$WIDGET_VERSION_FILE" FM_FAKE_INSTALL_LOG="$INSTALL_LOG" \
  FM_FAKE_REGISTRY_VERSION=2.5.0 \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
cached_latest=$(awk -F '\t' '$1 == "widget-axi" { print $3 }' "$CACHE")
[ "$cached_latest" = 2.5.0 ] ||
  fail "a locked bootstrap must refresh the due currency answer (cache says $cached_latest)"
check "a locked session does perform the refresh the read-only session skipped"

printf '\n%s assertions passed\n' "$ASSERTIONS"
