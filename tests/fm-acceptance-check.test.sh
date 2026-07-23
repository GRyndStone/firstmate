#!/usr/bin/env bash
# Behavior tests for criterion-to-evidence acceptance
# (bin/fm-acceptance-check.sh + bin/fm-acceptance-lib.sh).
#
# Covers: full direct-evidence pass, missing handoff, incomplete fields,
# wrong-surface proxy rejection, bare done: cannot advance without a map,
# proportional none: for briefs without AC-*, and the Gryndstone regression
# (Grok active + in catalog but absent from user-facing chooser must fail).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-acceptance-check

CHECK="$ROOT/bin/fm-acceptance-check.sh"
# shellcheck source=bin/fm-acceptance-lib.sh disable=SC1091
. "$ROOT/bin/fm-acceptance-lib.sh"

write_brief() {
  local path=$1
  shift
  cat > "$path" <<EOF
You are a crewmate.

# Task
$*

# Setup
ignored scaffold text that may mention AC-1 as an example format only in other sections.

# Acceptance evidence
Concrete criteria use stable ids (AC-1, AC-2, ...). This instruction must not invent criteria.
EOF
}

run_check() {
  local brief=$1 evidence=$2
  "$CHECK" --brief "$brief" --evidence "$evidence" 2>&1
}

test_script_parses() {
  bash -n "$ROOT/bin/fm-acceptance-check.sh" 2>&1 || fail "fm-acceptance-check.sh fails bash -n"
  bash -n "$ROOT/bin/fm-acceptance-lib.sh" 2>&1 || fail "fm-acceptance-lib.sh fails bash -n"
  pass "acceptance scripts: bash -n succeeds"
}

test_help_renders() {
  local help
  help=$("$CHECK" --help)
  assert_contains "$help" "Exit codes:" "help omitted exit-code contract"
  assert_contains "$help" "docs/acceptance-evidence.md" "help must name the contract owner"
  pass "fm-acceptance-check.sh: --help renders header"
}

test_extract_ids_from_task_only() {
  local brief ids
  brief="$TMP_ROOT/extract-brief.md"
  write_brief "$brief" "$(cat <<'EOF'
Ship: add Grok to Hermes.

## Acceptance
- AC-1: Grok appears in the user-facing model chooser
- AC-2: focused tests pass
Also mentions AC-99 only in Task so it counts: AC-99: bonus
EOF
)"
  ids=$("$CHECK" --extract-ids --brief "$brief")
  assert_contains "$ids" "AC-1" "extract missed AC-1"
  assert_contains "$ids" "AC-2" "extract missed AC-2"
  assert_contains "$ids" "AC-99" "extract missed AC-99"
  # Scaffold text outside # Task mentions AC-1 as format example; must not duplicate noise from Acceptance evidence section alone — already in Task.
  # Ensure a purely instructional mention outside Task is ignored when we use a clean brief:
  cat > "$brief" <<'EOF'
# Task
No criteria here, just work.

# Acceptance evidence
Use ids like AC-1 in the Task section.
EOF
  ids=$("$CHECK" --extract-ids --brief "$brief")
  if [ -n "$ids" ]; then
    fail "extract-ids invented criteria from scaffold instructions: $ids"
  fi
  pass "extract-ids: Task section only"
}

test_full_direct_evidence_passes() {
  local brief evidence out status=0
  brief="$TMP_ROOT/pass-brief.md"
  evidence="$TMP_ROOT/pass-evidence.md"
  write_brief "$brief" "$(cat <<'EOF'
## Acceptance
- AC-1: branch includes the focused unit regression for the parser
- AC-2: docs pointer names the contract owner
EOF
)"
  cat > "$evidence" <<'EOF'
# Acceptance evidence

## AC-1
- statement: branch includes the focused unit regression for the parser
- surface: tests/fm-acceptance-check.test.sh
- class: unit
- command: bash tests/fm-acceptance-check.test.sh
- result: all assertions pass
- relevance: blocks-ideal

## AC-2
- statement: docs pointer names the contract owner
- surface: docs/acceptance-evidence.md
- class: code
- command: rg -n 'fm-acceptance-check' docs/acceptance-evidence.md
- result: file documents the gate and CLI
- relevance: blocks-ideal
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "full direct evidence must pass"
  assert_contains "$out" "PASS: all criteria mapped" "pass message missing"
  pass "full direct evidence passes"
}

test_missing_evidence_fails() {
  local brief evidence out status=0
  brief="$TMP_ROOT/missing-brief.md"
  evidence="$TMP_ROOT/missing-evidence.md"
  write_brief "$brief" "- AC-1: something concrete must work"
  rm -f "$evidence"
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "missing handoff must fail"
  assert_contains "$out" "acceptance evidence handoff missing" "missing-file message absent"
  assert_contains "$out" "repair:" "missing repair direction"
  assert_contains "$out" "bare done:" "must state bare done cannot advance"
  pass "missing evidence fails with repair"
}

test_incomplete_fields_fail() {
  local brief evidence out status=0
  brief="$TMP_ROOT/incomplete-brief.md"
  evidence="$TMP_ROOT/incomplete-evidence.md"
  write_brief "$brief" "- AC-1: unit test covers the helper"
  cat > "$evidence" <<'EOF'
## AC-1
- class: unit
- result: ok
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "incomplete fields must fail"
  assert_contains "$out" "incomplete evidence" "incomplete message missing"
  assert_contains "$out" "repair AC-1:" "precise per-id repair missing"
  pass "incomplete fields fail"
}

test_status_claim_class_rejected() {
  local brief evidence out status=0
  brief="$TMP_ROOT/claim-brief.md"
  evidence="$TMP_ROOT/claim-evidence.md"
  write_brief "$brief" "- AC-1: helper returns zero on success"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: status file
- class: status
- command: echo done
- result: done: shipped
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "status class must fail"
  assert_contains "$out" "claim, not evidence" "claim rejection message missing"
  pass "status/claim class rejected"
}

test_wrong_surface_proxy_fails() {
  local brief evidence out status=0
  brief="$TMP_ROOT/proxy-brief.md"
  evidence="$TMP_ROOT/proxy-evidence.md"
  write_brief "$brief" "- AC-1: option appears in the user-facing model chooser menu"
  cat > "$evidence" <<'EOF'
## AC-1
- statement: option appears in the user-facing model chooser menu
- surface: provider catalog API
- class: catalog
- command: curl catalog endpoint
- result: model id present in catalog JSON
- head: deadbeef
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "catalog proxy for UI must fail"
  assert_contains "$out" "proxy rejected" "proxy rejection missing"
  assert_contains "$out" "required_class=ui" "required class should be ui"
  assert_contains "$out" "offered_class=catalog" "offered class should be catalog"
  pass "wrong-surface proxy fails"
}

test_gryndstone_chooser_regression() {
  local brief evidence out status=0
  brief="$TMP_ROOT/gryndstone-brief.md"
  evidence="$TMP_ROOT/gryndstone-evidence.md"
  write_brief "$brief" "$(cat <<'EOF'
Add Grok 4.5 to Gryndstone Hermes.

## Acceptance
- AC-1: Grok 4.5 is listed and selectable in the existing user-facing model chooser
- AC-2: Grok remains the active/default selection after reload
EOF
)"
  # Worker offers catalog + active config + inference, but not the chooser surface.
  cat > "$evidence" <<'EOF'
# Acceptance evidence

## AC-1
- statement: Grok 4.5 is listed and selectable in the existing user-facing model chooser
- surface: provider model catalog + config/models.yaml active entry
- class: catalog
- command: inspect provider catalog; read active model from config; run one inference
- result: grok-4.5 present in catalog; active=xai-oauth/grok-4.5; inference replies
- head: 2026-07-18T12:00:00Z

## AC-2
- statement: Grok remains the active/default selection after reload
- surface: config active model field after process restart
- class: config
- command: restart hermes; read active model
- result: active model still grok-4.5
- head: 2026-07-18T12:05:00Z
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "Gryndstone-class catalog/active proxy must fail"
  assert_contains "$out" "FAIL AC-1" "AC-1 must fail"
  assert_contains "$out" "proxy rejected" "proxy rejection required"
  assert_contains "$out" "required_class=ui" "chooser criterion requires ui"

  # Same criteria with direct UI evidence for the chooser must pass.
  cat > "$evidence" <<'EOF'
# Acceptance evidence

## AC-1
- statement: Grok 4.5 is listed and selectable in the existing user-facing model chooser
- surface: Hermes Telegram model switcher (user-facing)
- class: ui
- command: open existing model chooser; list selectable entries; select grok-4.5
- result: xai-oauth / grok-4.5 listed and selectable; selection applies
- head: abcdef1 2026-07-18T13:00:00Z
- relevance: blocks-ideal

## AC-2
- statement: Grok remains the active/default selection after reload
- surface: live Hermes after reload via chooser-selected default
- class: live
- command: reload service; open chooser; confirm default and send probe message
- result: default remains grok-4.5; probe answers as Grok
- head: abcdef1 2026-07-18T13:10:00Z
- relevance: blocks-ideal
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "Gryndstone with direct UI/live evidence must pass"
  assert_contains "$out" "PASS AC-1" "AC-1 UI evidence should pass"
  assert_contains "$out" "PASS AC-2" "AC-2 live evidence should pass"
  pass "Gryndstone chooser regression: proxy fails, direct UI/live passes"
}

test_proportional_none_without_criteria() {
  local brief evidence out status=0
  brief="$TMP_ROOT/none-brief.md"
  evidence="$TMP_ROOT/none-evidence.md"
  write_brief "$brief" "Typos in a comment. No concrete acceptance list."
  cat > "$evidence" <<'EOF'
# Acceptance evidence
none: no concrete acceptance criteria
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "proportional none: must pass"
  assert_contains "$out" "proportional none" "none pass message missing"

  # Missing none: when no AC-* still fails (bare done cannot advance).
  cat > "$evidence" <<'EOF'
# Acceptance evidence
I think it is fine.
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "no-AC brief without none: must fail"
  pass "proportional none: works; bare prose without none fails"
}

test_none_with_criteria_rejected() {
  local brief evidence out status=0
  brief="$TMP_ROOT/none-vs-ac-brief.md"
  evidence="$TMP_ROOT/none-vs-ac-evidence.md"
  write_brief "$brief" "- AC-1: tests pass"
  cat > "$evidence" <<'EOF'
none: no concrete acceptance criteria
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "none: must not waive concrete criteria"
  assert_contains "$out" "declares none:" "none-vs-criteria message missing"
  pass "none: rejected when criteria exist"
}

test_ui_requires_head() {
  local brief evidence out status=0
  brief="$TMP_ROOT/ui-head-brief.md"
  evidence="$TMP_ROOT/ui-head-evidence.md"
  write_brief "$brief" "- AC-1: button appears in the user-facing menu"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: settings menu UI
- class: ui
- command: open menu
- result: button visible
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "UI evidence without head must fail"
  assert_contains "$out" "requires head/freshness" "head requirement message missing"
  pass "ui evidence requires head"
}

# A finding cannot close a criterion on truth alone. Every AC-N entry must also
# be classified against the captain-approved ideal state, so a verified but
# out-of-model finding is visibly out-of-model instead of silently setting the
# agenda. Missing or unrecognized values fail closed with a repair line.
test_relevance_classification_required() {
  local brief evidence out status=0 value
  brief="$TMP_ROOT/relevance-brief.md"
  evidence="$TMP_ROOT/relevance-evidence.md"
  write_brief "$brief" "- AC-1: unit test covers the helper"

  # Missing relevance: fails closed, even though every evidence field is present.
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: pass
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "entry without relevance: must fail"
  assert_contains "$out" "relevance" "failure must name the missing relevance classification"
  assert_contains "$out" "repair AC-1:" "precise per-id repair missing"
  assert_contains "$out" "blocks-ideal" "repair must list the allowed values"

  # An unrecognized value fails closed rather than being waved through.
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: pass
- relevance: important
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unrecognized relevance value must fail"
  assert_contains "$out" "relevance" "failure must name the bad relevance value"
  assert_contains "$out" "repair AC-1:" "unrecognized value needs a repair line"

  # Each allowed value passes.
  for value in blocks-ideal later-scope out-of-model; do
    cat > "$evidence" <<EOF
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: pass
- relevance: $value
EOF
    status=0
    out=$(run_check "$brief" "$evidence") || status=$?
    expect_code 0 "$status" "relevance $value must be accepted"
    assert_contains "$out" "PASS AC-1" "relevance $value should pass AC-1"
  done
  pass "acceptance gate requires an ideal-state relevance classification per criterion"
}

# The proportional none: path is for tasks with genuinely no concrete criteria.
# It has no AC-N entries, so the relevance requirement must not reach it.
test_relevance_not_required_for_none_path() {
  local brief evidence out status=0
  brief="$TMP_ROOT/relevance-none-brief.md"
  evidence="$TMP_ROOT/relevance-none-evidence.md"
  write_brief "$brief" "Typo fix in a comment. No concrete acceptance list."
  cat > "$evidence" <<'EOF'
# Acceptance evidence
none: no concrete acceptance criteria
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "none: path must still pass without relevance fields"
  assert_contains "$out" "proportional none" "none pass message missing"
  pass "acceptance gate leaves the proportional none: path unchanged"
}

test_task_id_path_resolution() {
  local home id brief evidence out status=0
  home="$TMP_ROOT/home"
  id="acc-path-t1"
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  evidence="$home/data/$id/acceptance.md"
  write_brief "$brief" "Tiny fix.

## Acceptance
- AC-1: unit test covers the change
"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: pass
- relevance: blocks-ideal
EOF
  out=$(FM_HOME="$home" "$CHECK" "$id" 2>&1) || status=$?
  expect_code 0 "$status" "task-id resolution should find data/<id> paths"
  assert_contains "$out" "PASS AC-1" "task-id path check should pass AC-1"
  pass "task-id path resolution"
}

test_script_parses
test_help_renders
test_extract_ids_from_task_only
test_full_direct_evidence_passes
test_missing_evidence_fails
test_incomplete_fields_fail
test_status_claim_class_rejected
test_wrong_surface_proxy_fails
test_gryndstone_chooser_regression
test_proportional_none_without_criteria
test_none_with_criteria_rejected
test_ui_requires_head
test_relevance_classification_required
test_relevance_not_required_for_none_path
test_task_id_path_resolution

pass "fm-acceptance-check: all cases"
