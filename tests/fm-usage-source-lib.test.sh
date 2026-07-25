#!/usr/bin/env bash
# Unit tests for modular usage-source adapters (bin/fm-usage-source-lib.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-usage-source-lib.sh
. "$ROOT/bin/fm-usage-source-lib.sh"

fm_test_tmproot TMP_ROOT fm-usage-source-lib-tests
mkdir -p "$TMP_ROOT"

TEST_NOW=$(date +%s)
iso_at_epoch() {
  if date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
VALID_REFRESHED_AT=$(iso_at_epoch $((TEST_NOW - 60)))
VALID_RESET_AT=$(iso_at_epoch $((TEST_NOW + 3600)))

write_quota() {
  cat > "$1" <<JSON
{
  "generatedAt": "$(iso_at_epoch "$TEST_NOW")",
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 80, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 18000 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 50, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 },
        { "id": "model:fable", "kind": "model", "percentRemaining": 0 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 70, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 18000 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 60, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 }
      ]
    },
    {
      "provider": "grok",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "credits", "kind": "credits", "percentRemaining": 13, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 86400 },
        { "id": "product:api", "kind": "credits", "percentRemaining": 66, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 86400 }
      ]
    }
  ]
}
JSON
}

test_class_map() {
  [ "$(fm_usage_source_class claude)" = anthropic-class ] || fail "claude class"
  [ "$(fm_usage_source_class codex)" = openai-class ] || fail "codex class"
  [ "$(fm_usage_source_class grok)" = grok-class ] || fail "grok class"
  [ "$(fm_usage_source_class gemini)" = gemini-class ] || fail "gemini class"
  [ "$(fm_usage_source_class openrouter)" = openrouter-class ] || fail "openrouter class"
  pass "provider class map covers shipped adapter classes"
}

test_provider_registry_distinguishes_unknown_tokens() {
  local ids class_out status
  ids=$(fm_usage_source_provider_ids)
  [ "$ids" = $'claude\ncodex\ngrok\ngemini\nopenrouter\ncursor\ncopilot' ] \
    || fail "recognized provider registry changed: $ids"
  fm_usage_source_provider_known gemini \
    || fail "recognized unmetered provider must be accepted by the shared registry"
  if fm_usage_source_provider_known openai; then
    fail "adapter class token openai must not be accepted as a provider identity"
  fi
  class_out=$(fm_usage_source_class openai)
  status=$?
  expect_code 64 "$status" "unrecognized provider class lookup must refuse"
  [ -z "$class_out" ] || fail "unrecognized provider must not receive a generic class: $class_out"
  pass "shared provider registry distinguishes provider identities from unknown tokens"
}

test_quota_backed_adapters() {
  local quota obs
  quota="$TMP_ROOT/quota.json"
  write_quota "$quota"
  obs=$(fm_usage_source_observe claude "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .class == "anthropic-class"
    and .evidence == "fresh"
    and .binding.remaining == 50
    and .binding.id == "seven_day"
    and (.windows | length) == 2
  ' <<< "$obs" >/dev/null || fail "claude adapter binding wrong: $obs"

  obs=$(fm_usage_source_observe codex "$(cat "$quota")" "$TEST_NOW")
  jq -e '.class == "openai-class" and .binding.remaining == 60' \
    <<< "$obs" >/dev/null || fail "codex adapter: $obs"

  obs=$(fm_usage_source_observe grok "$(cat "$quota")" "$TEST_NOW")
  jq -e '.class == "grok-class" and .binding.remaining == 13 and .binding.id == "credits"' \
    <<< "$obs" >/dev/null || fail "grok adapter should bind tightest non-model window: $obs"
  pass "anthropic/openai/grok adapters expose window, remaining, and binding"
}

test_stubs_degrade_unknown() {
  local obs
  [ "$(fm_usage_source_meter_kind gemini)" = unmetered ] \
    || fail "recognized unmetered provider must be declared in the shared registry"
  obs=$(fm_usage_source_observe gemini '{"providers":[]}' "$TEST_NOW")
  jq -e '.class == "gemini-class" and .evidence == "unknown" and (.windows|length)==0' \
    <<< "$obs" >/dev/null || fail "gemini stub: $obs"
  obs=$(fm_usage_source_observe openrouter '{"providers":[]}' "$TEST_NOW")
  jq -e '.class == "openrouter-class" and .evidence == "unknown"' \
    <<< "$obs" >/dev/null || fail "openrouter stub: $obs"
  pass "gemini and openrouter stubs degrade honestly to unknown"
}

test_absent_provider_unknown() {
  local obs
  obs=$(fm_usage_source_observe claude '{"providers":[]}' "$TEST_NOW")
  jq -e '.evidence == "unknown"' <<< "$obs" >/dev/null || fail "absent provider: $obs"
  pass "provider absent from quota evidence is unknown, not fabricated"
}

test_observe_profiles_dedupes() {
  local quota out
  quota="$TMP_ROOT/quota.json"
  write_quota "$quota"
  out=$(fm_usage_source_observe_profiles \
    '[{"provider":"claude","harness":"claude"},{"provider":"claude","harness":"opencode"},{"provider":"codex","harness":"codex"}]' \
    "$(cat "$quota")" "$TEST_NOW")
  jq -e 'length == 2' <<< "$out" >/dev/null || fail "should dedupe providers: $out"
  pass "observe_profiles emits one observation per distinct provider"
}

test_class_map
test_provider_registry_distinguishes_unknown_tokens
test_quota_backed_adapters
test_stubs_degrade_unknown
test_absent_provider_unknown
test_observe_profiles_dedupes

echo "# all fm-usage-source-lib tests passed"
