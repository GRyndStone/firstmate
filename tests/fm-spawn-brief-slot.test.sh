#!/usr/bin/env bash
# Behavior tests for the unfilled-brief-slot dispatch gate in fm-spawn.sh.
#
# A crewmate was once launched on a brief whose Task section still held the raw
# {TASK} placeholder: the substitution had failed and nothing stopped the launch,
# so the worker began on an empty brief. This gate closes that at dispatch.
#
# The slot definition is load-bearing. fm-brief.sh emits every fill-in slot as a
# line whose ENTIRE content is the placeholder token, while the scaffold's own
# prose may mention the same token inline. Only a whole-line occurrence is a
# slot, so the gate must refuse the former and ignore the latter - a naive
# substring count is exactly what let the original failure through.
#
# Every case here points at a project that does not exist, so a brief that clears
# the gate fails immediately afterwards on project resolution. That keeps the
# suite instant and side-effect free (no windows, worktrees, or treehouse leases)
# and additionally pins the gate ahead of project resolution: the refusal cases
# must still report the unfilled slot rather than the missing project.
# FM_SPAWN_NO_GUARD=1 keeps the tests off the live watcher guard.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-brief-slot
export FM_BACKEND=tmux

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects"

# Clear ambient firstmate overrides so the behavior test owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Write a brief for <id> from the body passed on stdin.
write_brief() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md"
}

# An unfilled slot line must refuse the launch, name the file and the token, and
# exit non-zero - the same fail-closed shape as the isolated-worktree assertion.
test_unfilled_slot_refuses_ship_and_scout() {
  local out status id

  for kind in ship scout; do
    id="slot-unfilled-$kind"
    write_brief "$id" <<'EOF'
You are a crewmate.

# Operating context
{OPERATING_CONTEXT}

# Task
build the thing
EOF
    status=0
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$id" projects/no-such-project --scout) || status=$?
    else
      out=$(run_spawn "$id" projects/no-such-project) || status=$?
    fi
    [ "$status" -ne 0 ] || fail "$kind: unfilled slot must refuse the launch"
    assert_contains "$out" "unfilled" "$kind: refusal must say the brief has an unfilled slot"
    assert_contains "$out" "{OPERATING_CONTEXT}" "$kind: refusal must name the unfilled token"
    assert_contains "$out" "$HOME_DIR/data/$id/brief.md" "$kind: refusal must name the brief file"
  done

  # The originally-observed failure: an unreplaced {TASK} slot.
  id="slot-unfilled-task"
  write_brief "$id" <<'EOF'
You are a crewmate.

# Task
{TASK}
EOF
  status=0
  out=$(run_spawn "$id" projects/no-such-project) || status=$?
  [ "$status" -ne 0 ] || fail "unreplaced {TASK} slot must refuse the launch"
  assert_contains "$out" "{TASK}" "refusal must name the unreplaced {TASK} token"
  pass "fm-spawn.sh: an unfilled brief slot refuses ship and scout dispatch"
}

# A brief that merely MENTIONS a token inline is fully filled in and must launch
# normally. Refusing it would make the gate unusable, since fm-brief.sh's own
# Herdr declaration mentions the task token in prose.
test_prose_mention_is_not_a_slot() {
  local out status id
  id="slot-prose-mention"
  write_brief "$id" <<'EOF'
You are a crewmate.

# Operating context
Runs in a single-tenant CLI with no untrusted input; only crashes block.

# Task
Fix the parser.

# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
Firstmate replaces {OPERATING_CONTEXT} and {TASK} when it fills the brief in.
EOF
  status=0
  out=$(run_spawn "$id" projects/no-such-project) || status=$?
  # The gate must not be what stops this brief. It may still fail later for
  # unrelated environment reasons, but never with the unfilled-slot refusal.
  case "$out" in
    *"unfilled"*) fail "prose mention of a token must not be treated as an unfilled slot: $out" ;;
  esac
  pass "fm-spawn.sh: a prose mention of a placeholder token is not an unfilled slot"
}

# A fully filled brief passes the gate. Asserted the same way: whatever else the
# sandbox does, the unfilled-slot refusal must not be the thing that stops it.
test_filled_brief_passes_the_gate() {
  local out status id
  id="slot-filled"
  write_brief "$id" <<'EOF'
You are a crewmate.

# Operating context
Batch job, no live traffic; only data loss blocks, style findings are informational.

# Task
Fix the parser.
EOF
  status=0
  out=$(run_spawn "$id" projects/no-such-project) || status=$?
  case "$out" in
    *"unfilled"*) fail "a fully filled brief must clear the slot gate: $out" ;;
  esac
  pass "fm-spawn.sh: a fully filled brief clears the slot gate"
}

test_unfilled_slot_refuses_ship_and_scout
test_prose_mention_is_not_a_slot
test_filled_brief_passes_the_gate
