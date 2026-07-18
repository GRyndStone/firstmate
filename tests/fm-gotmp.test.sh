#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise behavior directly: fm-teardown is run as a subprocess against a
# fake FM_HOME/FM_ROOT (built so the real script resolves into it), with stub helper scripts.
# Nothing is sourced. The fm-spawn side is verified both structurally (the source has
# the contract lines) and behaviorally (the mkdir + meta-write pattern it uses).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME with an exact owned tmux endpoint and an untracked backlog.
# The real teardown closes that endpoint, confirms the absent worktree, and removes
# tasktmp through its current durable lifecycle path.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id" owner
  mkdir -p "$fake/state" "$fake/data" "$fake/config" "$fake/fakebin"
  git -C "$fake" init -q project
  cp "$ROOT/.tasks.toml" "$fake/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$fake/data/backlog.md"
  owner=$(FM_HOME="$fake" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_home_identity' "$ROOT") \
    || fail "could not compute fake home identity"
  : > "$fake/tmux-live"
  cat > "$fake/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -e "${FM_FAKE_TMUX_STATE:?}" ] || exit 0
    printf '@42\tfm-%s\t%s\t_\n' "${FM_FAKE_TASK_ID:?}" "${FM_FAKE_TMUX_OWNER:?}"
    ;;
  display-message)
    [ -e "${FM_FAKE_TMUX_STATE:?}" ] || { printf 'can\x27t find window\n' >&2; exit 1; }
    printf '@42\tfirstmate\tfm-%s\t%s\n' "${FM_FAKE_TASK_ID:?}" "${FM_FAKE_TMUX_OWNER:?}"
    ;;
  if-shell)
    unlink "${FM_FAKE_TMUX_STATE:?}"
    ;;
  *) exit 0 ;;
esac
SH
cat > "$fake/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf 'tasks-axi 0.2.2\n'; exit 0 ;;
  "update --help") printf '%s\n' '--archive-body'; exit 0 ;;
  "mv --help") printf '%s\n' '[<id>...]'; exit 0 ;;
esac
if [ "${1:-}" = show ]; then
  printf 'code: NOT_FOUND\n'
  exit 1
fi
exit 0
SH
  chmod +x "$fake/fakebin/tmux" "$fake/fakebin/tasks-axi"
  cat > "$fake/state/$id.meta" <<META
window=@42
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$fake/project
harness=claude
kind=ship
mode=local-only
yolo=off
tmux_home_identity=$owner
tmux_session=firstmate
tmux_window_id=@42
META
  [ -z "$tasktmp" ] || printf 'tasktmp=%s\n' "$tasktmp" >> "$fake/state/$id.meta"
  printf '%s' "$fake"
}

run_fake_teardown() {  # <home> <task-id>
  local fake=$1 id=$2 owner
  owner=$(sed -n 's/^tmux_home_identity=//p' "$fake/state/$id.meta")
  FM_HOME="$fake" PATH="$fake/fakebin:$PATH" \
    FM_FAKE_TMUX_STATE="$fake/tmux-live" FM_FAKE_TMUX_OWNER="$owner" FM_FAKE_TASK_ID="$id" \
    "$TEARDOWN" "$id" --force
}

add_gnu_stat_emulator() {
  local fake=$1
  cat > "$fake/fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -f ] && [ "${2:-}" = '%d:%i' ]; then
  # GNU stat treats the BSD format as an operand, emits output for the valid
  # path operand, and then exits non-zero because the format operand is absent.
  printf '  File: "%s"\n    ID: leaked-gnu-filesystem-output\n' "${3:-}"
  exit 1
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = '%d:%i' ]; then
  case "$(uname -s)" in
    Darwin) exec /usr/bin/stat -f '%d:%i' "${3:-}" ;;
    *) exec /usr/bin/stat -c '%d:%i' "${3:-}" ;;
  esac
fi
exec /usr/bin/stat "$@"
SH
  chmod +x "$fake/fakebin/stat"
}

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: mkdir of gotmp under TASK_TMP"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'echo "tasktmp=$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: tasktmp= line in meta write"
  grep -F 'export GOTMPDIR=' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: GOTMPDIR export into pane"
  # Behavioral: the mkdir + meta-write pattern spawn uses must produce a gotmp dir and
  # a meta line whose value the teardown grep (tasktmp=, cut -d= -f2-) reads back whole.
  local id=spawn-sim-z1
  local sim_root="$TMP_ROOT/$id-root"
  local task_tmp="$sim_root/tmp/fm-$id"
  mkdir -p "$sim_root/state"
  # Replicate spawn's exact mkdir + meta-write lines.
  TASK_TMP="$task_tmp"
  mkdir -p "$TASK_TMP/gotmp"
  {
    echo "tasktmp=$TASK_TMP"
  } > "$sim_root/state/$id.meta"
  [ -d "$task_tmp/gotmp" ] || fail "simulated spawn did not create gotmp dir"
  # Teardown reads tasktmp= with `grep '^tasktmp=' | cut -d= -f2-`; round-trip it.
  local read_back
  read_back=$(grep '^tasktmp=' "$sim_root/state/$id.meta" | cut -d= -f2-)
  [ "$read_back" = "$task_tmp" ] \
    || fail "tasktmp value not round-tripped by teardown's grep|cut (got '$read_back')"
  pass "fm-spawn creates gotmp dir and records tasktmp in meta"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  local out status=0
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  add_gnu_stat_emulator "$fake"
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  out=$(run_fake_teardown "$fake" "$id" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "teardown exited non-zero with a valid tasktmp: $out"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes tasktmp with GNU stat fallback output"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake
  fake=$(make_fake_root "$id" "")
  run_fake_teardown "$fake" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  run_fake_teardown "$fake" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_spawn_contract_and_mkdir_pattern
test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
