#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch selection and quota admission.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot TMP_ROOT fm-dispatch-select-tests
mkdir -p "$TMP_ROOT"

iso_at_epoch() {
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

TEST_NOW=$(date +%s)
VALID_REFRESHED_AT=$(iso_at_epoch $((TEST_NOW - 60)))
VALID_RESET_AT=$(iso_at_epoch $((TEST_NOW + 3600)))
EXPIRED_RESET_AT=$(iso_at_epoch $((TEST_NOW - 1)))
TOO_OLD_REFRESHED_AT=$(iso_at_epoch $((TEST_NOW - 700000)))

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "generatedAt": "$(iso_at_epoch "$TEST_NOW")",
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five, "resetsAt": "$VALID_RESET_AT" },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week, "resetsAt": "$VALID_RESET_AT" },
        { "id": "model:fable", "kind": "model", "percentRemaining": 0 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five, "resetsAt": "$VALID_RESET_AT" },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week, "resetsAt": "$VALID_RESET_AT" },
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

test_quota_balanced_multiple_candidates() {
  local quota out
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  jq -e '.provider == "codex" and .harness == "codex" and .model == "gpt-5.5" and .quota_posture == "normal" and .quota_percent_used == 40' \
    <<< "$out" >/dev/null || fail "higher-min provider should win with posture, got: $out"

  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  jq -e '.provider == "claude" and .harness == "claude"' <<< "$out" >/dev/null \
    || fail "exact tie should use first ordered profile, got: $out"
  pass "quota-balanced handles multiple candidates and keeps deterministic tie order"
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
  assert_not_contains "$err" "codex" "freeze refusal must not claim an alternate provider"
  pass "explicit frozen provider refuses new work without selecting an available alternate"
}

test_stale_data_and_margin() {
  local quota updated out err status
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  jq -e '.provider == "codex"' <<< "$out" >/dev/null \
    || fail "fresh provider should win when stale lead is below margin: $out"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  jq -e '.provider == "claude"' <<< "$out" >/dev/null \
    || fail "stale provider should win when lead clears margin: $out"

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
  assert_contains "$err" "no usable quota windows for selected provider" \
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
  printf '%s\n' '{"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"five_hour","percentRemaining":100},{"id":"weekly","percentRemaining":100}]}]}' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --admit --quota-json "$quota" \
    '[{"provider":"claude","harness":"claude"},{"provider":"codex","harness":"codex"}]' 2>"$TMP_ROOT/unavailable.err")
  err=$(cat "$TMP_ROOT/unavailable.err")
  jq -e '.provider == "claude" and .harness == "claude" and .quota_posture == "unknown"' \
    <<< "$out" >/dev/null || fail "unavailable explicit provider silently fell back: $out"
  assert_contains "$err" "no usable quota windows for selected provider" "unavailable provider must be observable"
  pass "unavailable explicit provider never silently selects another candidate"
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
  assert_not_contains "$out" "codex" "resume must not substitute another provider or harness"
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
test_quota_balanced_multiple_candidates
test_explicit_frozen_provider_never_chooses_alternate
test_stale_data_and_margin
test_expired_or_unverifiable_stale_data_degrades_to_unknown
test_malformed_or_missing_quota_retains_selected_provider
test_unavailable_provider_does_not_trigger_admission_fallback
test_nonfresh_provider_surfaces_actionable_diagnostics
test_resume_meta_retains_pinned_profile
test_non_admission_selection_stays_backward_compatible

echo "# all fm-dispatch-select tests passed"
