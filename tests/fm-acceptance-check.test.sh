#!/usr/bin/env bash
# Behavior tests for criterion-to-evidence acceptance
# (bin/fm-acceptance-check.sh + bin/fm-acceptance-lib.sh).
#
# Covers: full direct-evidence pass, declared result verdicts, missing handoff,
# incomplete fields, wrong-surface proxy rejection, bare done: cannot advance
# without a map, proportional none: for briefs without AC-*, and the
# Gryndstone regression (Grok active + in catalog but absent from user-facing
# chooser must fail).
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
  assert_contains "$help" "declares PASS" "help omitted result-verdict contract"
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
- result: PASS - all assertions pass

## AC-2
- statement: docs pointer names the contract owner
- surface: docs/acceptance-evidence.md
- class: code
- command: rg -n 'fm-acceptance-check' docs/acceptance-evidence.md
- result: PASS - file documents the gate and CLI
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "full direct evidence must pass"
  assert_contains "$out" "PASS: all criteria mapped" "pass message missing"
  pass "full direct evidence passes"
}

test_declared_nonpassing_and_ambiguous_verdicts_fail() {
  local brief evidence out shape_out status shape_status result expected_message label case_count=0
  brief="$TMP_ROOT/verdict-brief.md"
  evidence="$TMP_ROOT/verdict-evidence.md"
  write_brief "$brief" "- AC-1: the focused test succeeds"

  while IFS='|' read -r label result expected_message; do
    case_count=$((case_count + 1))
    cat > "$evidence" <<EOF
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: $result
EOF

    # This direct library call recreates the old shape-only checker.
    shape_status=0
    shape_out=$(fm_acceptance_check "$brief" "$evidence" 2>&1) || shape_status=$?
    expect_code 0 "$shape_status" "$label must demonstrate the verdict-blind shape gate"
    assert_contains "$shape_out" "PASS AC-1" "$label shape gate did not reach its blind pass"

    status=0
    out=$(run_check "$brief" "$evidence") || status=$?
    expect_code 1 "$status" "$label must fail the verdict-aware checker"
    assert_contains "$out" "$expected_message" "$label verdict failure was not distinguished"
    assert_contains "$out" "repair AC-1:" "$label verdict repair guidance missing"
    assert_not_contains "$out" "PASS AC-1" "$label must never report the failed criterion PASS"
    assert_not_contains "$out" "PASS: all criteria" "$label must never report aggregate PASS"
  done <<'EOF'
self-declared partial|PARTIAL - two platforms succeeded, but the compatibility run did not finish cleanly|verdict not achieved (declared=PARTIAL)
self-declared failure|FAIL - the release probe returned a nonzero status|verdict not achieved (declared=FAIL)
self-declared unknown|UNKNOWN - the observation ended without a decisive outcome|verdict not achieved (declared=UNKNOWN)
ambiguous near-success|completed every check except the final cross-version scenario|verdict ambiguous
EOF

  expect_code 4 "$case_count" "anti-vacuity requires every planted negative to run"
  pass "declared nonpassing and ambiguous verdicts fail after shape validation"
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
  assert_not_contains "$out" "verdict" "missing handoff must retain its own failure class"
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
  assert_not_contains "$out" "verdict" "incomplete fields must retain their own failure class"
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
  assert_not_contains "$out" "verdict" "proxy rejection must retain its own failure class"
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
- result: PASS - xai-oauth / grok-4.5 listed and selectable; selection applies
- head: abcdef1 2026-07-18T13:00:00Z

## AC-2
- statement: Grok remains the active/default selection after reload
- surface: live Hermes after reload via chooser-selected default
- class: live
- command: reload service; open chooser; confirm default and send probe message
- result: PASS - default remains grok-4.5; probe answers as Grok
- head: abcdef1 2026-07-18T13:10:00Z
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
- result: PASS
EOF
  out=$(FM_HOME="$home" "$CHECK" "$id" 2>&1) || status=$?
  expect_code 0 "$status" "task-id resolution should find data/<id> paths"
  assert_contains "$out" "PASS AC-1" "task-id path check should pass AC-1"
  pass "task-id path resolution"
}

test_present_heading_unparsed_fields_distinct_from_absent() {
  local brief evidence out status=0
  brief="$TMP_ROOT/heading-brief.md"
  evidence="$TMP_ROOT/heading-evidence.md"
  write_brief "$brief" "- AC-1: focused unit test covers the helper
- AC-2: docs pointer names the contract owner"

  # Present heading, bare (non-bullet) fields — must NOT claim the section is absent.
  cat > "$evidence" <<'EOF'
## AC-1
surface: tests/example.test.sh
class: unit
command: bash tests/example.test.sh
result: PASS - ok

## AC-2
- surface: docs/acceptance-evidence.md
- class: code
- command: rg contract docs/acceptance-evidence.md
- result: PASS - present
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unparsed bare fields must still fail"
  assert_contains "$out" "section present but fields did not parse" "must diagnose unparsed fields"
  assert_contains "$out" "- key: value bullets" "must name the bullet requirement"
  assert_contains "$out" "repair AC-1:" "must give AC-1 repair"
  assert_contains "$out" "markdown bullets" "repair must mention bullet rewrite"
  assert_not_contains "$out" "no ## AC-1 section" "must not report present heading as absent"
  assert_not_contains "$out" "proxy rejected" "unparsed fields are not a proxy failure"

  # Genuinely absent ## AC-2 while AC-1 is well-formed.
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: PASS - ok
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "missing section must fail"
  assert_contains "$out" "no ## AC-2 section in evidence handoff" "absent section message"
  assert_contains "$out" "repair AC-2: add a ## AC-2 section" "absent section repair"
  assert_not_contains "$out" "fields did not parse" "absent section must not use unparsed-fields wording"
  pass "present-but-unparsed vs genuinely-absent headings are distinct"
}

test_unrecognised_class_not_proxy() {
  local brief evidence out status=0
  brief="$TMP_ROOT/unknown-class-brief.md"
  evidence="$TMP_ROOT/unknown-class-evidence.md"
  write_brief "$brief" "- AC-1: helper returns zero on success"

  cat > "$evidence" <<'EOF'
## AC-1
- surface: live CLI observation
- class: runtime
- command: run the CLI probe
- result: PASS - ok
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unknown class token must fail"
  assert_contains "$out" "unrecognised class token runtime" "must say unrecognised"
  assert_contains "$out" "valid:" "must name the valid set"
  assert_contains "$out" "ui" "valid set includes ui"
  assert_contains "$out" "live" "valid set includes live"
  assert_contains "$out" "code" "valid set includes code"
  assert_contains "$out" "repair AC-1:" "must repair with known vocabulary"
  assert_not_contains "$out" "proxy rejected" "unknown token is not a proxy rejection"
  assert_not_contains "$out" "config/catalog/api" "must not emit proxy repair text for unknown class"

  # Second natural unknown token crews actually used.
  cat > "$evidence" <<'EOF'
## AC-1
- surface: live CLI
- class: live-cli
- command: probe
- result: PASS - ok
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "live-cli must fail as unrecognised"
  assert_contains "$out" "unrecognised class token live-cli" "live-cli unrecognised"
  assert_not_contains "$out" "proxy rejected" "live-cli is not proxy"

  # Genuine proxy (known weaker class) must still use the proxy message unchanged.
  write_brief "$brief" "- AC-1: option appears in the user-facing model chooser menu"
  cat > "$evidence" <<'EOF'
## AC-1
- statement: option appears in the user-facing model chooser menu
- surface: provider catalog API
- class: catalog
- command: curl catalog
- result: PASS - listed
- head: deadbeef
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "genuine proxy must still fail"
  assert_contains "$out" "proxy rejected" "genuine proxy message preserved"
  assert_contains "$out" "required_class=ui" "proxy still requires ui"
  assert_contains "$out" "offered_class=catalog" "proxy still names catalog"
  assert_contains "$out" "config/catalog/api" "proxy repair text preserved"
  assert_not_contains "$out" "unrecognised class token" "known weaker class is not unrecognised"
  pass "unrecognised class vs genuine proxy are distinct"
}

test_required_class_whole_token_not_incidental() {
  local brief evidence out status=0 inferred

  # Real incident: "configured" must not force config; live evidence must pass.
  brief="$TMP_ROOT/incidental-brief.md"
  evidence="$TMP_ROOT/incidental-evidence.md"
  write_brief "$brief" "- AC-1: the router reads every configured provider's live usage meter"
  inferred=$(fm_acceptance_required_class "the router reads every configured provider's live usage meter")
  [ "$inferred" = "code" ] || fail "incidental 'configured' must not force config (got $inferred)"

  cat > "$evidence" <<'EOF'
## AC-1
- statement: the router reads every configured provider's live usage meter
- surface: live usage meter probe
- class: live
- command: probe each configured provider's live usage endpoint
- result: PASS - live meter values returned for every provider
- head: 2026-07-25T12:00:00Z
EOF
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 0 "$status" "live evidence for configured-providers criterion must pass"
  assert_contains "$out" "PASS AC-1" "AC-1 should pass with live evidence"
  assert_not_contains "$out" "required_class=config" "must not demand config for incidental configured"

  # Subject uses of the same roots still infer as before.
  inferred=$(fm_acceptance_required_class "update the config file for the provider")
  [ "$inferred" = "config" ] || fail "subject 'config' must still infer config (got $inferred)"
  inferred=$(fm_acceptance_required_class "ship the yaml configuration for models")
  [ "$inferred" = "config" ] || fail "subject configuration/yaml must still infer config (got $inferred)"
  inferred=$(fm_acceptance_required_class "option appears in the user-facing model chooser menu")
  [ "$inferred" = "ui" ] || fail "subject user-facing chooser must still infer ui (got $inferred)"
  inferred=$(fm_acceptance_required_class "probe security on the live server")
  [ "$inferred" = "live" ] || fail "subject live server must still infer live (got $inferred)"
  inferred=$(fm_acceptance_required_class "branch includes the focused unit test for the parser")
  [ "$inferred" = "unit" ] || fail "subject unit test must still infer unit (got $inferred)"
  inferred=$(fm_acceptance_required_class "api endpoint returns 200")
  [ "$inferred" = "api" ] || fail "subject api endpoint must still infer api (got $inferred)"
  inferred=$(fm_acceptance_required_class "model appears in the provider catalog list")
  [ "$inferred" = "catalog" ] || fail "subject catalog must still infer catalog (got $inferred)"

  # More incidental vocabulary must not invent strict classes.
  inferred=$(fm_acceptance_required_class "document how units are converted in the parser")
  [ "$inferred" = "code" ] || fail "incidental 'units' must not force unit (got $inferred)"
  inferred=$(fm_acceptance_required_class "rapid application bootstrap without network")
  [ "$inferred" = "code" ] || fail "incidental letters inside other words must not force api (got $inferred)"

  # Explicit required_class still overrides weak inference and stays strict.
  write_brief "$brief" "- AC-1: reads every configured provider's live usage"
  cat > "$evidence" <<'EOF'
## AC-1
- statement: reads every configured provider's live usage
- required_class: live
- surface: unit suite
- class: unit
- command: bash tests/example.test.sh
- result: PASS - suite green
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "explicit required_class=live must still reject unit proxy"
  assert_contains "$out" "proxy rejected" "explicit live still enforces proxy rejection"
  assert_contains "$out" "required_class=live" "explicit required_class honored"
  pass "required-class inference is whole-token; incidental vocabulary does not invent requirements"
}

test_refusal_messages_name_true_repairs() {
  # AC-4: every distinct refusal the checker can emit is produced from a real
  # run, and its repair text applies to the condition that produced it.
  local brief evidence out status case_count=0

  # 1. brief missing
  status=0
  out=$(run_check "$TMP_ROOT/no-such-brief.md" "$TMP_ROOT/no-such-evidence.md") || status=$?
  expect_code 1 "$status" "brief missing fails"
  assert_contains "$out" "brief missing" "brief missing message"
  assert_contains "$out" "repair: ensure the task brief exists" "brief missing repair"
  case_count=$((case_count + 1))

  # 2. evidence missing with criteria
  brief="$TMP_ROOT/refuse-brief.md"
  evidence="$TMP_ROOT/refuse-evidence.md"
  write_brief "$brief" "- AC-1: unit test covers the helper"
  rm -f "$evidence"
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "evidence missing fails"
  assert_contains "$out" "acceptance evidence handoff missing" "missing evidence message"
  assert_contains "$out" "repair: write" "missing evidence repair"
  assert_contains "$out" "bare done:" "bare done note"
  case_count=$((case_count + 1))

  # 3. evidence missing without criteria → none: repair
  write_brief "$brief" "Typos only."
  rm -f "$evidence"
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "missing evidence no-AC fails"
  assert_contains "$out" "none: no concrete acceptance criteria" "none repair for no-AC"
  case_count=$((case_count + 1))

  # 4. no AC and no none: line
  write_brief "$brief" "Typos only."
  cat > "$evidence" <<'EOF'
# Acceptance evidence
looks fine
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "no-AC without none fails"
  assert_contains "$out" "lacks the proportional none:" "no-none message"
  assert_contains "$out" "repair: either tag concrete criteria" "no-none repair"
  case_count=$((case_count + 1))

  # 5. none: with concrete criteria
  write_brief "$brief" "- AC-1: tests pass"
  cat > "$evidence" <<'EOF'
none: no concrete acceptance criteria
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "none with criteria fails"
  assert_contains "$out" "declares none:" "none-vs-criteria message"
  assert_contains "$out" "repair: remove none:" "none-vs-criteria repair"
  case_count=$((case_count + 1))

  # 6. section absent
  write_brief "$brief" "- AC-1: unit test covers the helper"
  cat > "$evidence" <<'EOF'
## AC-99
- surface: x
- class: unit
- command: x
- result: PASS
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "section absent fails"
  assert_contains "$out" "no ## AC-1 section" "absent section message"
  assert_contains "$out" "repair AC-1: add a ## AC-1 section" "absent section repair"
  case_count=$((case_count + 1))

  # 7. section present, fields unparsed
  cat > "$evidence" <<'EOF'
## AC-1
surface: tests/x.test.sh
class: unit
command: bash tests/x.test.sh
result: PASS
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unparsed fields fail"
  assert_contains "$out" "section present but fields did not parse" "unparsed message"
  assert_contains "$out" "repair AC-1: under ## AC-1 rewrite fields as markdown bullets" "unparsed repair"
  case_count=$((case_count + 1))

  # 8. incomplete fields
  cat > "$evidence" <<'EOF'
## AC-1
- class: unit
- result: PASS
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "incomplete fails"
  assert_contains "$out" "incomplete evidence" "incomplete message"
  assert_contains "$out" "repair AC-1: fill missing fields" "incomplete repair"
  case_count=$((case_count + 1))

  # 9. claim class
  cat > "$evidence" <<'EOF'
## AC-1
- surface: status
- class: status
- command: echo done
- result: PASS - done
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "claim class fails"
  assert_contains "$out" "claim, not evidence" "claim message"
  assert_contains "$out" "repair AC-1: replace status/claim class" "claim repair"
  case_count=$((case_count + 1))

  # 10. unrecognised offered class
  cat > "$evidence" <<'EOF'
## AC-1
- surface: runtime
- class: runtime
- command: run
- result: PASS
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unrecognised class fails"
  assert_contains "$out" "unrecognised class token runtime" "unrecognised message"
  assert_contains "$out" "repair AC-1: set class to one of:" "unrecognised repair"
  case_count=$((case_count + 1))

  # 11. unrecognised required_class
  cat > "$evidence" <<'EOF'
## AC-1
- required_class: magic
- surface: tests/x.test.sh
- class: unit
- command: bash tests/x.test.sh
- result: PASS
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "unrecognised required_class fails"
  assert_contains "$out" "unrecognised required_class token magic" "unrecognised required message"
  assert_contains "$out" "repair AC-1: set required_class to one of:" "unrecognised required repair"
  case_count=$((case_count + 1))

  # 12. proxy rejected
  write_brief "$brief" "- AC-1: option appears in the user-facing model chooser menu"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: catalog
- class: catalog
- command: curl
- result: PASS
- head: deadbeef
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "proxy fails"
  assert_contains "$out" "proxy rejected" "proxy message"
  assert_contains "$out" "repair AC-1: required class is ui" "proxy repair names required"
  case_count=$((case_count + 1))

  # 13. ui/live missing head
  write_brief "$brief" "- AC-1: button appears in the user-facing menu"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: settings menu UI
- class: ui
- command: open menu
- result: PASS - visible
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "missing head fails"
  assert_contains "$out" "requires head/freshness attribution" "head message"
  assert_contains "$out" "repair AC-1: add head:" "head repair"
  case_count=$((case_count + 1))

  # 14. verdict not achieved (declared non-PASS)
  write_brief "$brief" "- AC-1: the focused test succeeds"
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: FAIL - red
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "declared FAIL fails"
  assert_contains "$out" "verdict not achieved (declared=FAIL)" "nonpass verdict message"
  assert_contains "$out" "repair AC-1: rerun direct evidence and record PASS" "nonpass verdict repair"
  case_count=$((case_count + 1))

  # 15. verdict ambiguous
  cat > "$evidence" <<'EOF'
## AC-1
- surface: tests/example.test.sh
- class: unit
- command: bash tests/example.test.sh
- result: completed every check except one
EOF
  status=0
  out=$(run_check "$brief" "$evidence") || status=$?
  expect_code 1 "$status" "ambiguous verdict fails"
  assert_contains "$out" "verdict ambiguous" "ambiguous message"
  assert_contains "$out" "repair AC-1: begin result with a declared verdict" "ambiguous repair"
  case_count=$((case_count + 1))

  expect_code 15 "$case_count" "every planted refusal path must run"
  pass "every refusal message names a repair true for its condition"
}

test_script_parses
test_help_renders
test_extract_ids_from_task_only
test_full_direct_evidence_passes
test_declared_nonpassing_and_ambiguous_verdicts_fail
test_missing_evidence_fails
test_incomplete_fields_fail
test_status_claim_class_rejected
test_wrong_surface_proxy_fails
test_gryndstone_chooser_regression
test_proportional_none_without_criteria
test_none_with_criteria_rejected
test_ui_requires_head
test_task_id_path_resolution
test_present_heading_unparsed_fields_distinct_from_absent
test_unrecognised_class_not_proxy
test_required_class_whole_token_not_incidental
test_refusal_messages_name_true_repairs

pass "fm-acceptance-check: all cases"
