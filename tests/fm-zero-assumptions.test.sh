#!/usr/bin/env bash
# Regression tests for the zero-assumptions starting mandate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-zero-assumptions
BRIEF="$ROOT/bin/fm-brief.sh"
SUPERVISION="$ROOT/bin/fm-supervision-instructions.sh"

MANDATE=$(cat <<'EOF'
## Starting mandate: zero assumptions

Every claim, question, and action must cite the captain's words, thoughts, opinions, determinations, or decisions, or reality: what code actually does or tests directly prove, never an abstraction, plausible reading, or guess.
Read documentation when it has the answer; when research, another document, or a test can find it, go find it; when first principles can derive it, derive it.
Ask only when the answer exists only in the captain's head.
Do exactly what the captain told you to do.
Act only with evidenced, explicitly given authority; infer no standing authorization from context or convenience.
Never discard or condense this mandate or replace it with a reference.
EOF
)

assert_starts_with_mandate() {
  local text=$1 label=$2
  case "$text" in
    "$MANDATE"*) : ;;
    *) fail "$label does not start with the full zero-assumptions mandate" ;;
  esac
}

skill_body() {
  awk '
    /^---$/ {
      delimiters++
      next
    }
    delimiters >= 2 {
      if (!started && $0 == "") {
        next
      }
      started=1
      print
    }
  ' "$1"
}

test_mandate_is_compact_and_complete() {
  local words
  words=$(printf '%s\n' "$MANDATE" | wc -w | tr -d ' ')
  [ "$words" -le 120 ] || fail "starting mandate grew past the 120-word skim-resistance ceiling"
  assert_contains "$MANDATE" "Every claim, question, and action must cite the captain's words" "mandate lost its evidence rule"
  assert_contains "$MANDATE" "what code actually does or tests directly prove" "mandate lost its reality rule"
  assert_contains "$MANDATE" "Read documentation when it has the answer" "mandate lost its documentation rule"
  assert_contains "$MANDATE" "research, another document, or a test can find it, go find it" "mandate lost its find-and-test rule"
  assert_contains "$MANDATE" "when first principles can derive it, derive it" "mandate lost its derivation rule"
  assert_contains "$MANDATE" "Ask only when the answer exists only in the captain's head" "mandate lost its ask rule"
  assert_contains "$MANDATE" "Do exactly what the captain told you to do" "mandate lost the captain-direction rule"
  assert_contains "$MANDATE" "evidenced, explicitly given authority" "mandate lost its authority rule"
  assert_contains "$MANDATE" "Never discard or condense this mandate" "mandate lost its persistence rule"
  pass "zero-assumptions mandate stays compact and carries every load-bearing rule"
}

test_primary_and_skill_surfaces_start_with_mandate() {
  local agents expected skill body count=0
  agents=$(cat "$ROOT/AGENTS.md")
  expected="# Firstmate

$MANDATE"
  case "$agents" in
    "$expected"*) : ;;
    *) fail "AGENTS.md does not start with the full mandate after its title" ;;
  esac

  [ "$(readlink "$ROOT/CLAUDE.md")" = "AGENTS.md" ] \
    || fail "CLAUDE.md is not the verified AGENTS.md symlink"
  [ "$(readlink "$ROOT/.claude/skills")" = "../.agents/skills" ] \
    || fail ".claude/skills is not the verified internal-skills symlink"

  for skill in "$ROOT"/.agents/skills/*/SKILL.md; do
    [ -f "$skill" ] || continue
    count=$((count + 1))
    body=$(skill_body "$skill")
    assert_starts_with_mandate "$body" "${skill#"$ROOT"/}"
  done
  [ "$count" -gt 0 ] || fail "no firstmate agent-only skills were discovered"
  pass "AGENTS.md, its symlink, and every discovered agent-only skill start with the mandate"
}

test_every_brief_shape_opens_with_mandate() {
  local home id brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- nm-proj [no-mistakes] - zero-assumptions fixture
- direct-proj [direct-PR] - zero-assumptions fixture
- local-first-proj [local-first] - zero-assumptions fixture
- local-proj [local-only] - zero-assumptions fixture
EOF

  generate_and_check() {
    id=$1
    shift
    FM_HOME="$home" "$BRIEF" "$id" "$@" >/dev/null
    brief="$home/data/$id/brief.md"
    assert_starts_with_mandate "$(cat "$brief")" "generated brief $id"
  }

  generate_and_check ship-nm nm-proj
  generate_and_check ship-direct direct-proj
  generate_and_check ship-local-first local-first-proj
  generate_and_check ship-local local-proj
  generate_and_check ship-herdr direct-proj --herdr-lab
  generate_and_check scout direct-proj --scout
  generate_and_check scout-herdr direct-proj --scout --herdr-lab
  generate_and_check gsd direct-proj --gsd
  generate_and_check gsd-herdr direct-proj --gsd --herdr-lab
  FM_SECONDMATE_CHARTER='fixture charter' generate_and_check secondmate --secondmate direct-proj
  FM_SECONDMATE_CHARTER='fixture charter' generate_and_check secondmate-no-projects --secondmate --no-projects

  pass "all ship modes, scout, GSD, Herdr-lab variants, and secondmate charters open with the mandate"
}

test_supervision_instruction_surface_starts_with_mandate() {
  local protocol out body headings harness count=0
  for protocol in "$ROOT"/docs/supervision-protocols/*.md; do
    [ -f "$protocol" ] || continue
    count=$((count + 1))
    assert_starts_with_mandate "$(cat "$protocol")" "${protocol#"$ROOT"/}"
  done
  [ "$count" -gt 0 ] || fail "no supervision protocol sources were discovered"

  for harness in claude codex grok opencode pi unknown; do
    out=$("$SUPERVISION" --harness "$harness")
    body=$(printf '%s\n' "$out" | sed -n '4,$p')
    assert_starts_with_mandate "$body" "rendered $harness supervision block"
    headings=$(printf '%s\n' "$out" | grep -Fc "## Starting mandate: zero assumptions")
    [ "$headings" -eq 1 ] || fail "rendered $harness supervision block contains $headings mandate headings"
  done
  pass "every protocol source and rendered session-start supervision block starts with one full mandate"
}

test_instruction_loading_paths_are_concrete() {
  # shellcheck disable=SC2016 # The spawn source must retain this literal command substitution.
  assert_grep '$(cat __BRIEF__)' "$ROOT/bin/fm-spawn.sh" \
    "spawn no longer passes generated brief contents to launched agents"
  # shellcheck disable=SC2016 # The session-start source must retain this literal variable reference.
  assert_grep '"$SCRIPT_DIR/fm-supervision-instructions.sh"' "$ROOT/bin/fm-session-start.sh" \
    "session start no longer invokes the supervision instruction renderer"
  # shellcheck disable=SC2016 # The renderer source must retain this literal variable reference.
  assert_grep 'done < "$SNIPPET"' "$SUPERVISION" \
    "supervision renderer no longer reads the selected protocol source"
  # shellcheck disable=SC2016 # Backticks are literal Markdown from AGENTS.md.
  assert_grep 'Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface' "$ROOT/AGENTS.md" \
    "AGENTS.md no longer defines the running instruction surface"
  # shellcheck disable=SC2016 # Backticks are literal Markdown from AGENTS.md.
  assert_grep 'public `skills/` is tracked for installers and is not loaded by firstmate' "$ROOT/AGENTS.md" \
    "public-skill exclusion is no longer evidenced"
  pass "the covered surfaces and public-skill exclusion remain tied to concrete repository loading paths"
}

test_mandate_is_compact_and_complete
test_primary_and_skill_surfaces_start_with_mandate
test_every_brief_shape_opens_with_mandate
test_supervision_instruction_surface_starts_with_mandate
test_instruction_loading_paths_are_concrete
