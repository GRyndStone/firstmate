#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-brief

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate gsd; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
      gsd)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --gsd >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    if [ "$kind" = gsd ]; then
      # The gsd scaffold uses the pause verb in its idle-wait and handoff lines
      # instead of the generic pause-usage sentence the other scaffolds carry.
      # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
      assert_grep 'awaiting: driving GSD {milestone}, next check {when}' "$brief" \
        "$kind brief did not render the configured pause verb in its idle-wait line"
      assert_grep 'awaiting: context handoff written, requesting relaunch' "$brief" \
        "$kind brief did not render the configured pause verb in its handoff line"
      assert_no_grep 'paused: driving GSD' "$brief" \
        "$kind brief still renders the default paused verb in its idle-wait line"
    else
      # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
      assert_grep 'Use `awaiting: {why}`' "$brief" \
        "$kind brief did not instruct the configured pause status"
      # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
      assert_no_grep '`paused: {why}`' "$brief" \
        "$kind brief still instructs the default paused status"
    fi
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_external_wait_registration_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/external-wait-home"
  mkdir -p "$home/data"
  for kind in ship scout secondmate gsd; do
    id="brief-external-wait-$kind"
    case "$kind" in
      ship) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1 ;;
      scout) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1 ;;
      secondmate) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1 ;;
      gsd) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --gsd >/dev/null 2>&1 ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "FM_STATE_OVERRIDE='$home/state' '$ROOT/bin/fm-external-wait.sh' register-predicate $id" "$brief" \
      "$kind brief did not bind the model-free wait observer to the task's authoritative state home"
    assert_grep 'register-process' "$brief" \
      "$kind brief omitted tracked background-process completion registration"
    assert_grep 'register-command' "$brief" \
      "$kind brief omitted task-owned background-command progress registration"
    assert_grep 'register-background-probe' "$brief" \
      "$kind brief omitted explicit paused background-probe ownership"
    assert_grep 'arm-background-probe-pulse' "$brief" \
      "$kind brief omitted per-pulse background-probe ownership"
    assert_grep 'ordinary paused activity remains actionable' "$brief" \
      "$kind brief weakened generic paused endpoint activity"
    assert_grep 'unobservable parked task wakes as a runtime failure' "$brief" \
      "$kind brief did not state the fail-loud parking contract"
    if [ "$kind" != secondmate ]; then
      assert_grep 'state-owned wait helper' "$brief" \
        "$kind brief did not exempt state-owned wait registration from its worktree boundary"
      assert_grep 'supplied `FM_STATE_OVERRIDE`' "$brief" \
        "$kind brief did not scope its wait-helper boundary exception"
    fi
  done
  pass "fm-brief.sh: every scaffold binds observable waits to the authoritative task state"
}

# --gsd scaffolds the standing GSD-manager contract: drive an external GSD.Pi
# project headless, never hand-edit its .gsd/ state, route NEEDS-HUMAN gates as
# needs-decision, work around the 1.9.0 headless process leak, and finish only
# when the {TASK}-named milestone(s) are driven to completion with evidence.
test_gsd_brief_contract() {
  local home id brief status
  home="$TMP_ROOT/gsd-home"
  mkdir -p "$home/data"
  id="brief-gsd-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" someproject --gsd >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "fm-brief.sh $id someproject --gsd should exit 0"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "gsd brief was not scaffolded"
  assert_grep "{TASK}" "$brief" "gsd brief missing the {TASK} placeholder"
  assert_grep "standing manager of an external GSD project" "$brief" \
    "gsd brief missing the standing-manager role"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'hand GSD the specification with `gsd headless new-project` or `gsd headless new-milestone --context <spec-file>`' "$brief" \
    "gsd brief missing the headless stand-up contract"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'Run units with `gsd headless auto` and an explicit sane `--timeout`; track progress with `gsd headless status` / `gsd headless query`' "$brief" \
    "gsd brief missing the headless auto/status/query drive loop"
  assert_grep "SQLite-authoritative GSD state: never hand-edit anything under it" "$brief" \
    "gsd brief missing the never-hand-edit .gsd/ rule"
  assert_grep "HARD RULE - visible runs: launch every driving invocation" "$brief" \
    "gsd brief missing the visible-runs hard rule"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'bin/fm-gsd-run.sh`, which opens the run in a visible herdr tab; never run a driving invocation as a raw child of your own shell' "$brief" \
    "gsd brief missing the fm-gsd-run.sh visible-tab launch pointer"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'If the helper cannot open the visible tab, append `blocked: {why}` and stop instead of driving invisibly' "$brief" \
    "gsd brief missing the no-invisible-fallback blocked escalation"
  assert_grep "Route every NEEDS-HUMAN gate, every milestone-boundary decision" "$brief" \
    "gsd brief missing the needs-decision routing contract"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'needs-decision [key=gsd-gate-{slug}]:' "$brief" \
    "gsd brief missing the keyed NEEDS-HUMAN gate needs-decision line"
  assert_grep "Slugify every interpolated id or name" "$brief" \
    "gsd brief missing the key-slug grammar hint"
  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'check for leftover `gsd` processes from it and kill them' "$brief" \
    "gsd brief missing the 1.9.0 headless shutdown leak workaround"
  assert_grep "This worktree is scratch, exactly like a scout's" "$brief" \
    "gsd brief missing the scratch-worktree declaration"
  assert_grep "report each completed milestone" "$brief" \
    "gsd brief missing the milestone-completion status events"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_grep 'needs-decision [key=milestone-{id}]: milestone {id} complete' "$brief" \
    "gsd brief missing the keyed milestone-boundary needs-decision line"
  # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
  assert_no_grep '`working: milestone' "$brief" \
    "gsd brief still routes milestone completions through working: lines"
  assert_grep 'handoff note at' "$brief" \
    "gsd brief writable areas missing the handoff note"
  assert_grep 'or a blocker clears' "$brief" \
    "gsd brief missing the keyed durable-resolution contract"
  assert_grep "# Definition of done" "$brief" "gsd brief missing Definition of done section"
  assert_grep "the milestone(s) the task names are driven to completion" "$brief" \
    "gsd brief missing the milestones-with-evidence definition of done"
  assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "gsd brief silently omitted the Herdr declaration"
  assert_no_grep "EOF" "$brief" "gsd brief leaked a heredoc EOF marker (unterminated heredoc)"
  pass "fm-brief.sh: --gsd emits the standing GSD-manager contract"
}

# --gsd is a standalone crewmate contract: combining it with --secondmate or
# --scout must fail loudly and write nothing.
test_gsd_rejects_secondmate_and_scout() {
  local home status
  home="$TMP_ROOT/gsd-guard-home"
  mkdir -p "$home/data"
  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" gsd-sm --secondmate alpha --gsd >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--gsd --secondmate must be rejected"
  assert_absent "$home/data/gsd-sm/brief.md" "rejected --gsd --secondmate still wrote a brief"
  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" gsd-scout someproject --scout --gsd >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--gsd --scout must be rejected"
  assert_absent "$home/data/gsd-scout/brief.md" "rejected --gsd --scout still wrote a brief"
  pass "fm-brief.sh: --gsd rejects --secondmate and --scout combinations"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_external_wait_registration_renders_all_brief_scaffolds
test_gsd_brief_contract
test_gsd_rejects_secondmate_and_scout
