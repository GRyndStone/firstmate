#!/usr/bin/env bash
# Behavior tests for usage-burndown crew-dispatch selection and quota admission.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot TMP_ROOT fm-dispatch-select-tests
mkdir -p "$TMP_ROOT"
export FM_USAGE_BURN_HISTORY="$TMP_ROOT/burn-history.json"
printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"

iso_at_epoch() {
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

TEST_NOW=$(date +%s)
VALID_REFRESHED_AT=$(iso_at_epoch $((TEST_NOW - 60)))
VALID_RESET_AT=$(iso_at_epoch $((TEST_NOW + 3600)))
NEAR_RESET_AT=$(iso_at_epoch $((TEST_NOW + 300)))
FAR_RESET_AT=$(iso_at_epoch $((TEST_NOW + 500000)))
EXPIRED_RESET_AT=$(iso_at_epoch $((TEST_NOW - 1)))
TOO_OLD_REFRESHED_AT=$(iso_at_epoch $((TEST_NOW - 700000)))

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  local claude_reset=${8:-$VALID_RESET_AT}
  local codex_reset=${9:-$VALID_RESET_AT}
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "generatedAt": "$(iso_at_epoch "$TEST_NOW")",
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five, "resetsAt": "$claude_reset", "windowSeconds": 18000 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week, "resetsAt": "$claude_reset", "windowSeconds": 604800 },
        { "id": "model:fable", "kind": "model", "percentRemaining": 0 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five, "resetsAt": "$codex_reset", "windowSeconds": 18000 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week, "resetsAt": "$codex_reset", "windowSeconds": 604800 },
        { "id": "model:codex_bengalfox:5h", "kind": "model", "percentRemaining": 0 }
      ]
    }
  ]
}
JSON
}

profiles='[{"provider":"claude","harness":"claude","model":"claude-sonnet-5","effort":"high"},{"provider":"codex","harness":"codex","model":"gpt-5.5","effort":"high"}]'

assert_posture() {
  local remaining=$1 expected=$2 label=$3 quota out
  quota="$TMP_ROOT/posture-$label.json"
  write_quota "$quota" fresh "$remaining" 100 fresh 100 100
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]')
  jq -e --arg posture "$expected" --argjson used "$(awk -v r="$remaining" 'BEGIN { print 100-r }')" \
    '.provider == "claude" and .harness == "claude" and .quota_posture == $posture and .quota_percent_used == $used' \
    <<< "$out" >/dev/null || fail "$label: expected posture=$expected, got: $out"
}

test_posture_boundaries() {
  local quota out err status
  assert_posture 40.1 normal below-60
  assert_posture 40 conserve at-60
  assert_posture 20.1 conserve below-80
  assert_posture 20 protect at-80
  assert_posture 10.1 protect below-90

  quota="$TMP_ROOT/at-90.json"
  write_quota "$quota" fresh 10 100 fresh 100 100
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' 2>"$TMP_ROOT/at-90.err")
  status=$?
  err=$(cat "$TMP_ROOT/at-90.err")
  expect_code 75 "$status" "90% used must freeze admission"
  [ -z "$out" ] || fail "freeze must not print an admitted profile: $out"
  assert_contains "$err" "provider 'claude' is freeze at 90% used" "freeze reason must name provider and boundary"
  assert_contains "$err" "retry after quota clears" "freeze reason must be actionable"
  pass "provider postures change exactly at 60%, 80%, and 90% used"
}

test_usage_burndown_multiple_candidates() {
  local quota out err
  # Equal windows/time: higher binding remaining wins via surplus when B is similar.
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select usage-burndown --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/higher.err")
  err=$(cat "$TMP_ROOT/higher.err")
  jq -e '.provider == "codex" and .harness == "codex" and .model == "gpt-5.5" and .quota_posture == "normal" and .dispatch_strategy == "usage-burndown"' \
    <<< "$out" >/dev/null || fail "higher surplus provider should win, got: $out"
  assert_contains "$err" "highest expiry-weighted surplus" "stderr must explain the choice"

  # Exact tie on binding remaining: stable first-index order.
  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select usage-burndown --quota-json "$quota" "$profiles" 2>/dev/null)
  jq -e '.provider == "claude" and .harness == "claude"' <<< "$out" >/dev/null \
    || fail "exact tie should use first ordered profile, got: $out"

  # Legacy alias routes to the same engine.
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>/dev/null)
  jq -e '.provider == "codex" and .dispatch_strategy == "usage-burndown"' \
    <<< "$out" >/dev/null || fail "quota-balanced alias should run usage-burndown: $out"
  pass "usage-burndown handles multiple candidates, ties, and the legacy alias"
}

test_prefers_near_expiry_surplus_over_static_remaining() {
  local quota out
  # Claude: high remaining, far reset, high learned burn => low S.
  # Codex: moderate remaining, near reset, zero burn history => high S*pressure.
  quota="$TMP_ROOT/near-expiry.json"
  cat > "$quota" <<JSON
{
  "generatedAt": "$(iso_at_epoch "$TEST_NOW")",
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 90, "resetsAt": "$FAR_RESET_AT", "windowSeconds": 18000 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 45, "resetsAt": "$NEAR_RESET_AT", "windowSeconds": 18000 }
      ]
    }
  ]
}
JSON
  # Seed high burn for claude only.
  printf '%s\n' '{"samples":[
    {"provider":"claude","window_id":"five_hour","remaining":100,"at":1000},
    {"provider":"claude","window_id":"five_hour","remaining":10,"at":1100}
  ]}' > "$FM_USAGE_BURN_HISTORY"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select usage-burndown --quota-json "$quota" "$profiles" 2>/dev/null)
  jq -e '.provider == "codex"' <<< "$out" >/dev/null \
    || fail "near-expiry surplus should beat high remaining with high burn: $out"
  # Reset history for other tests.
  printf '%s\n' '{"samples":[]}' > "$FM_USAGE_BURN_HISTORY"
  pass "engine prefers capacity at risk of expiring unused, not static max remaining"
}

test_explicit_frozen_provider_never_chooses_alternate() {
  local quota spec out err status
  quota="$TMP_ROOT/explicit-freeze.json"
  write_quota "$quota" fresh 9 100 fresh 100 100
  spec='[{"provider":"claude","harness":"opencode","model":"anthropic/sonnet"},{"provider":"codex","harness":"codex","model":"gpt-5.5"}]'
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" "$spec" 2>"$TMP_ROOT/explicit-freeze.err")
  status=$?
  err=$(cat "$TMP_ROOT/explicit-freeze.err")
  expect_code 75 "$status" "explicit frozen provider must refuse admission"
  [ -z "$out" ] || fail "explicit freeze must not output the alternate candidate: $out"
  assert_contains "$err" "provider 'claude' is freeze" "freeze refusal must retain explicit provider identity"
  assert_not_contains "$err" "provider 'codex' is freeze" "freeze refusal must not claim an alternate provider freeze"
  pass "explicit frozen provider refuses new work without selecting an available alternate"
}

test_multi_select_skips_freeze_for_live_capacity() {
  local quota out
  quota="$TMP_ROOT/multi-freeze-skip.json"
  write_quota "$quota" fresh 5 5 fresh 80 80
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select usage-burndown --quota-json "$quota" "$profiles" 2>/dev/null)
  jq -e '.provider == "codex" and .quota_posture == "normal"' \
    <<< "$out" >/dev/null || fail "multi-select should use live capacity when other is freeze: $out"
  pass "multi-select skips freeze-level sources when live capacity exists"
}

test_stale_usable_evidence_competes_by_burndown() {
  local quota updated out err status
  quota="$TMP_ROOT/stale-margin.json"
  # Stale claude with higher remaining competes by score (stale-clear margin retired).
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select usage-burndown --quota-json "$quota" "$profiles" 2>/dev/null)
  jq -e '.provider == "claude"' <<< "$out" >/dev/null \
    || fail "usable stale higher-surplus should compete by burndown score: $out"

  write_quota "$quota" stale 9 100 fresh 100 100
  updated="$quota.updated"
  jq '.providers[0].state += {
    error:"oauth refresh failed",
    reason:"keychain_access_required",
    remedyCommand:"quota-axi --allow-keychain-prompt"
  }' "$quota" > "$updated"
  mv "$updated" "$quota"
  "$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' >/dev/null 2>"$TMP_ROOT/stale-freeze.err"
  status=$?
  err=$(cat "$TMP_ROOT/stale-freeze.err")
  expect_code 75 "$status" "usable stale cached data at freeze must refuse admission"
  assert_contains "$err" "cached snapshot refreshed at $VALID_REFRESHED_AT" \
    "stale admission did not surface cached snapshot use"
  assert_contains "$err" "refresh error: oauth refresh failed" \
    "stale admission did not surface the refresh failure"
  assert_contains "$err" "remedy: quota-axi --allow-keychain-prompt" \
    "stale admission did not surface the remedy"
  pass "current stale quota remains usable and its refresh failure stays observable"
}

test_expired_or_unverifiable_stale_data_degrades_to_unknown() {
  local quota updated out err
  quota="$TMP_ROOT/stale-expired.json"
  write_quota "$quota" stale 1 1 fresh 100 100
  updated="$quota.updated"
  jq --arg reset "$EXPIRED_RESET_AT" \
    '.providers[0].windows |= map(if .id == "five_hour" or .id == "seven_day" then .resetsAt = $reset else . end)' \
    "$quota" > "$updated"
  mv "$updated" "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' 2>"$TMP_ROOT/stale-expired.err")
  err=$(cat "$TMP_ROOT/stale-expired.err")
  jq -e '.provider == "claude" and .harness == "claude" and .quota_posture == "unknown" and (has("quota_percent_used") | not)' \
    <<< "$out" >/dev/null || fail "expired stale quota did not degrade to unknown: $out"
  assert_contains "$err" "no usable" \
    "expired stale quota did not explain why it degraded"

  write_quota "$quota" stale 1 1 fresh 100 100
  updated="$quota.updated"
  jq '(.providers[0].state |= del(.refreshedAt)) | (.providers[0].windows |= map(del(.resetsAt)))' \
    "$quota" > "$updated"
  mv "$updated" "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' 2>/dev/null)
  jq -e '.quota_posture == "unknown" and (has("quota_percent_used") | not)' \
    <<< "$out" >/dev/null || fail "unverifiable stale quota did not degrade to unknown: $out"

  write_quota "$quota" stale 1 1 fresh 100 100
  updated="$quota.updated"
  jq --arg refreshed "$TOO_OLD_REFRESHED_AT" '.providers[0].state.refreshedAt = $refreshed' \
    "$quota" > "$updated"
  mv "$updated" "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' 2>/dev/null)
  jq -e '.quota_posture == "unknown" and (has("quota_percent_used") | not)' \
    <<< "$out" >/dev/null || fail "over-age stale quota did not degrade to unknown: $out"
  pass "expired, timestamp-less, and over-age stale windows cannot prove freeze"
}

test_malformed_or_missing_quota_retains_selected_provider() {
  local quota fakebin out err status
  quota="$TMP_ROOT/bad.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"opencode","model":"anthropic/sonnet"}' 2>"$TMP_ROOT/bad.err")
  status=$?
  err=$(cat "$TMP_ROOT/bad.err")
  expect_code 0 "$status" "malformed quota cannot prove freeze"
  jq -e '.provider == "claude" and .harness == "opencode" and .quota_posture == "unknown"' \
    <<< "$out" >/dev/null || fail "malformed quota changed selected provider/profile: $out"
  assert_contains "$err" "unparseable JSON" "malformed quota must stay observable"

  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --admit \
    '{"provider":"codex","harness":"codex"}' 2>"$TMP_ROOT/missing.err")
  status=$?
  expect_code 0 "$status" "missing quota-axi cannot prove freeze"
  jq -e '.provider == "codex" and .harness == "codex" and .quota_posture == "unknown"' \
    <<< "$out" >/dev/null || fail "missing quota-axi changed selected provider/profile: $out"
  assert_grep "quota-axi missing" "$TMP_ROOT/missing.err" "missing quota-axi must stay observable"
  pass "malformed or missing quota retains the selected provider with unknown posture"
}

test_unavailable_provider_does_not_trigger_admission_fallback() {
  local quota out err
  quota="$TMP_ROOT/unavailable.json"
  printf '%s\n' '{"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":100,"resetsAt":"'"$VALID_RESET_AT"'","windowSeconds":18000},{"id":"weekly","percentRemaining":100,"resetsAt":"'"$VALID_RESET_AT"'","windowSeconds":604800}]}]}' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]' 2>"$TMP_ROOT/unavailable.err")
  err=$(cat "$TMP_ROOT/unavailable.err")
  jq -e '.provider == "claude" and .harness == "claude" and .quota_posture == "unknown"' \
    <<< "$out" >/dev/null || fail "unavailable explicit provider silently fell back: $out"
  assert_contains "$err" "no usable" "unavailable provider must be observable"
  pass "unavailable explicit provider never silently selects another candidate"
}

test_unrecognized_provider_is_a_distinct_machine_error() {
  local quota token out err status
  quota="$TMP_ROOT/unrecognized.json"
  write_quota "$quota" fresh 100 100 fresh 65 65

  for token in openai typo-provider; do
    out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
      '{"provider":"'"$token"'","harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}' \
      2>"$TMP_ROOT/unrecognized-$token.err")
    status=$?
    err=$(cat "$TMP_ROOT/unrecognized-$token.err")
    expect_code 64 "$status" "unrecognized provider $token must refuse admission distinctly"
    jq -e --arg token "$token" '
      .provider == $token
      and .harness == "codex"
      and .provider_recognition == "unrecognized"
      and .quota_posture == "unknown"
      and .dispatch_error == "unrecognized-provider"
      and .unrecognized_providers == [$token]
      and (.recognized_providers | index("codex")) != null
      and (.recognized_providers | index("gemini")) != null
    ' <<< "$out" >/dev/null || fail "unrecognized provider profile was not machine-distinct: $out"
    assert_contains "$err" "unrecognized provider token '$token'" \
      "unrecognized refusal did not name the bad token"
    assert_contains "$err" "recognized providers: claude, codex, grok, gemini, openrouter, cursor, copilot" \
      "unrecognized refusal did not name the shared recognized set"
    assert_not_contains "$err" "no usable usage evidence" \
      "unrecognized provider was mislabeled as honest absence"
  done
  pass "unrecognized provider identities refuse with distinct JSON and stderr diagnostics"
}

test_recognized_unmetered_provider_degrades_honestly() {
  local quota out err status
  quota="$TMP_ROOT/recognized-unmetered.json"
  write_quota "$quota" fresh 100 100 fresh 100 100
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"gemini","harness":"codex","model":"future-model"}' \
    2>"$TMP_ROOT/recognized-unmetered.err")
  status=$?
  err=$(cat "$TMP_ROOT/recognized-unmetered.err")
  expect_code 0 "$status" "recognized provider without a meter must remain admissible"
  jq -e '
    .provider == "gemini"
    and .harness == "codex"
    and .provider_recognition == "recognized"
    and .quota_posture == "unknown"
    and (has("dispatch_error") | not)
    and (has("unrecognized_providers") | not)
  ' <<< "$out" >/dev/null || fail "recognized unmetered provider did not degrade honestly: $out"
  assert_contains "$err" "provider gemini retained with unknown posture; no usable evidence" \
    "recognized unmetered provider did not explain honest unknown evidence"
  assert_not_contains "$err" "unrecognized provider" \
    "recognized unmetered provider was reclassified as a caller error"
  pass "recognized providers without meters stay distinct from unrecognized tokens"
}

test_nonfresh_provider_surfaces_actionable_diagnostics() {
  local quota out err
  quota="$TMP_ROOT/auth-required.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "claude",
      "state": {
        "status": "auth_required",
        "error": "credentials expired",
        "reason": "keychain_access_required",
        "remedyCommand": "quota-axi --allow-keychain-prompt"
      },
      "windows": []
    },
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "percentRemaining": 100 },
        { "id": "weekly", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '{"provider":"claude","harness":"claude"}' 2>"$TMP_ROOT/auth-required.err")
  err=$(cat "$TMP_ROOT/auth-required.err")
  jq -e '.provider == "claude" and .quota_posture == "unknown"' <<< "$out" >/dev/null \
    || fail "auth-required provider changed the selected profile: $out"
  assert_contains "$err" "provider 'claude' quota status is auth_required" \
    "non-fresh admission did not surface provider status"
  assert_contains "$err" "refresh error: credentials expired" \
    "non-fresh admission did not surface provider error"
  assert_contains "$err" "reason: keychain_access_required" \
    "non-fresh admission did not surface provider reason"
  assert_contains "$err" "remedy: quota-axi --allow-keychain-prompt" \
    "non-fresh admission did not surface provider remedy"
  pass "non-fresh provider states retain their actionable diagnostics"
}

test_resume_meta_retains_pinned_profile() {
  local meta quota out status
  meta="$TMP_ROOT/resume.meta"
  cat > "$meta" <<'META'
window=firstmate:fm-resume
worktree=/tmp/existing-worktree
provider=claude
harness=opencode
model=anthropic/claude-sonnet-4-5
effort=default
kind=ship
META
  quota="$TMP_ROOT/resume.json"
  write_quota "$quota" fresh 10 100 fresh 100 100
  "$ROOT/bin/fm-dispatch-select.sh" --resume-meta "$meta" --quota-json "$quota" \
    >/dev/null 2>"$TMP_ROOT/resume-frozen.err"
  status=$?
  expect_code 75 "$status" "pinned resume must pause while its provider is frozen"

  write_quota "$quota" fresh 30 100 fresh 100 100
  out=$("$ROOT/bin/fm-dispatch-select.sh" --resume-meta "$meta" --quota-json "$quota")
  jq -e '.provider == "claude" and .harness == "opencode" and .model == "anthropic/claude-sonnet-4-5" and .effort == "default" and .quota_posture == "conserve"' \
    <<< "$out" >/dev/null || fail "resume did not retain the recorded profile: $out"
  assert_not_contains "$out" '"provider":"codex"' "resume must not substitute another provider or harness"
  pass "quota recovery returns the persisted task's recorded provider/profile only"
}

test_non_admission_selection_stays_backward_compatible() {
  local fakebin marker out single array_rule
  fakebin=$(fm_fakebin "$TMP_ROOT/no-call")
  marker="$TMP_ROOT/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object legacy selection changed: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array-without-select legacy selection changed: $out"
  [ ! -e "$marker" ] || fail "legacy non-admission selection should not call quota-axi"
  pass "legacy non-admission selection remains byte-compatible and quota-free"
}

test_posture_boundaries
test_usage_burndown_multiple_candidates
test_prefers_near_expiry_surplus_over_static_remaining
test_explicit_frozen_provider_never_chooses_alternate
test_multi_select_skips_freeze_for_live_capacity
test_stale_usable_evidence_competes_by_burndown
test_expired_or_unverifiable_stale_data_degrades_to_unknown
test_malformed_or_missing_quota_retains_selected_provider
test_unavailable_provider_does_not_trigger_admission_fallback
test_unrecognized_provider_is_a_distinct_machine_error
test_recognized_unmetered_provider_degrades_honestly
test_nonfresh_provider_surfaces_actionable_diagnostics
test_resume_meta_retains_pinned_profile
test_non_admission_selection_stays_backward_compatible

echo "# all fm-dispatch-select tests passed"
