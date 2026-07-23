#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <varname> <prefix>
#   Creates a fresh temp dir under TMPDIR, resolves it to a physical path
#   (pwd -P), assigns that path to <varname> in the caller's shell (via
#   printf -v; works with caller-local variables), and registers it for
#   removal on EXIT. Every registration (re)installs
#   `trap fm_test_cleanup EXIT` so a later `trap - EXIT` cannot silently
#   strand subsequent roots.
#
# fm_test_register_tmp <path>
#   Registers an already-created path for the same EXIT cleanup. Prefer
#   fm_test_tmproot for new roots; use this when a path must be built another
#   way (rare) or when adopting a path from a helper.
#
# fm_test_add_cleanup <function-name>
#   Registers a zero-arg shell function to run on EXIT *before* registered
#   dirs are removed (kill daemons, drop lab sessions, etc.). Prefer this
#   over installing a custom EXIT trap: a raw `trap ... EXIT` that does not
#   call fm_test_cleanup drops every registered root.
#
# fm_test_cleanup
#   Runs registered exit hooks (best-effort), then rm -rf every registered
#   temp path. Safe to call mid-suite; re-registration after that still
#   reinstalls the EXIT trap.
#
# fm-tmproot-static-allow: unsafe historical example `root=$(fm_test_tmproot ...)`
# runs the function in a subshell. The EXIT trap then fires in that subshell and
# deletes the empty root before the caller receives the path; the parent never
# gets the array entry or the trap. Callers that recreate the path (mkdir -p
# under it) then leak the recreated tree. Always call as:
#   fm_test_tmproot TMP_ROOT fm-my-suite
#
# Raw `mktemp -d .../fm-*.XXXXXX` in tests/ is also rejected by the static
# scan unless the preceding line carries `# fm-tmproot-static-allow: <reason>`.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_EXIT_HOOKS=()

fm_test_install_cleanup_trap() {
  # Always (re)install. Bash keeps only one EXIT trap; composing extra work
  # goes through fm_test_add_cleanup, not a second trap line.
  trap fm_test_cleanup EXIT
}

fm_test_cleanup() {
  local hook d
  for hook in "${FM_TEST_EXIT_HOOKS[@]:-}"; do
    if [ -n "$hook" ] && declare -F "$hook" >/dev/null 2>&1; then
      "$hook" || true
    fi
  done
  FM_TEST_EXIT_HOOKS=()
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf -- "$d"
  done
  FM_TEST_CLEANUP_DIRS=()
}

fm_test_add_cleanup() {
  local __hook=$1
  if [ "$#" -ne 1 ] || [ -z "${__hook:-}" ]; then
    printf 'fm_test_add_cleanup: usage: fm_test_add_cleanup FUNCTION_NAME\n' >&2
    return 1
  fi
  if ! declare -F "$__hook" >/dev/null 2>&1; then
    printf 'fm_test_add_cleanup: %s is not a defined function\n' "$__hook" >&2
    return 1
  fi
  FM_TEST_EXIT_HOOKS+=("$__hook")
  fm_test_install_cleanup_trap
}

fm_test_register_tmp() {
  local __path=$1
  if [ "$#" -ne 1 ] || [ -z "${__path:-}" ]; then
    printf 'fm_test_register_tmp: usage: fm_test_register_tmp PATH\n' >&2
    return 1
  fi
  FM_TEST_CLEANUP_DIRS+=("$__path")
  fm_test_install_cleanup_trap
}

fm_test_tmproot() {
  local __varname __prefix __root
  if [ "$#" -ne 2 ]; then
    printf 'fm_test_tmproot: usage: fm_test_tmproot VAR prefix\n' >&2
    return 1
  fi
  __varname=$1
  __prefix=$2
  if [ -z "${__varname:-}" ] || [[ ! "$__varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf 'fm_test_tmproot: need a valid variable name as arg1 (got %q)\n' "${__varname:-}" >&2
    return 1
  fi
  if [ -z "${__prefix:-}" ] || [[ ! "$__prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'fm_test_tmproot: need a safe temp prefix as arg2 (got %q)\n' "${__prefix:-}" >&2
    return 1
  fi
  __root=$(mktemp -d "${TMPDIR:-/tmp}/${__prefix}.XXXXXX") || return 1
  # Physical path: macOS TMPDIR is often a symlink farm; herdr/cwd compares
  # and later leak scans must see the same path the suite will remove.
  __root=$(cd "$__root" && pwd -P) || {
    rm -rf -- "$__root"
    return 1
  }
  FM_TEST_CLEANUP_DIRS+=("$__root")
  fm_test_install_cleanup_trap
  # printf -v assigns through dynamic scope: a caller-local varname is updated.
  printf -v "$__varname" '%s' "$__root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# fm_write_criteria <data-dir> <id> [brief-path]: write a minimal dispatchable
# criteria artifact for <id>, and make sure the brief quotes its claim verbatim
# so bin/fm-criteria-check.sh passes.
#
# Every fixture that spawns a ship or scout task now needs this, because the
# dispatch gate refuses work whose criteria trace to nothing the captain asked
# for. That cost is the point: a fixture that can dispatch without a mandate is
# a fixture that proves the gate does not hold.
fm_write_criteria() {
  local data=$1 id=$2 brief=${3:-$1/$2/brief.md} claim
  claim="fixture criterion for $id"
  mkdir -p "$data/$id"
  cat > "$data/$id/criteria.md" <<EOF
# Ideal state
> fixture: the captain asked for $id

## AC-1
claim:  $claim
source: captain
origin: "fixture: the captain asked for $id"
probe:  fixture probe for $id
anti:   a fixture criterion that cannot fail proves nothing
EOF
  if [ -f "$brief" ]; then
    grep -Fq "$claim" "$brief" || printf '\n## Acceptance\n- AC-1: %s\n' "$claim" >> "$brief"
  fi
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
