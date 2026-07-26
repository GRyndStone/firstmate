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
        { "id": "credits", "kind": "credits", "percentRemaining": 13, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 },
        { "id": "product:grokbuild", "kind": "credits", "percentRemaining": 47, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 },
        { "id": "product:api", "kind": "credits", "percentRemaining": 66, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 },
        { "id": "product:chat", "kind": "credits", "percentRemaining": 88, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 },
        { "id": "product:voice", "kind": "credits", "percentRemaining": 91, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 }
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
  [ "$(fm_usage_source_class antigravity)" = antigravity-class ] || fail "antigravity class"
  [ "$(fm_usage_source_class gemini)" = gemini-class ] || fail "gemini class"
  [ "$(fm_usage_source_class openrouter)" = openrouter-class ] || fail "openrouter class"
  pass "provider class map covers shipped adapter classes"
}

test_provider_registry_distinguishes_unknown_tokens() {
  local ids class_out status
  ids=$(fm_usage_source_provider_ids)
  [ "$ids" = $'claude\ncodex\ngrok\nantigravity\ngemini\nopenrouter\ncursor\ncopilot' ] \
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

test_antigravity_live_summary_adapter() {
  local fixture obs broken
  fixture="$TMP_ROOT/antigravity-summary.json"
  cat > "$fixture" <<JSON
{
  "description": "Within each group, models share a weekly limit and a 5-hour limit. The 5-hour limit smooths out aggregate demand, while your weekly limit is tied directly to your individual tier.",
  "groups": [
    {
      "displayName": "Gemini Models",
      "description": "Models within this group: Gemini Flash, Gemini Pro",
      "buckets": [
        {
          "bucketId": "gemini-weekly",
          "displayName": "Weekly Limit",
          "remainingFraction": 0.9899833,
          "resetTime": "$(iso_at_epoch $((TEST_NOW + 604000)))",
          "window": "weekly"
        },
        {
          "bucketId": "gemini-5h",
          "displayName": "Five Hour Limit",
          "remainingFraction": 0.9799,
          "resetTime": "$(iso_at_epoch $((TEST_NOW + 13000)))",
          "window": "5h"
        }
      ]
    },
    {
      "displayName": "Claude and GPT models",
      "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
      "buckets": [
        {
          "bucketId": "3p-weekly",
          "displayName": "Weekly Limit",
          "remainingFraction": 1,
          "resetTime": "$(iso_at_epoch $((TEST_NOW + 604100)))",
          "window": "weekly"
        },
        {
          "bucketId": "3p-5h",
          "displayName": "Five Hour Limit",
          "remainingFraction": 1,
          "resetTime": "$(iso_at_epoch $((TEST_NOW + 13100)))",
          "window": "5h"
        }
      ]
    }
  ]
}
JSON
  obs=$(
    FM_USAGE_ANTIGRAVITY_QUOTA_JSON="$(cat "$fixture")" \
      fm_usage_source_observe antigravity '{}' "$TEST_NOW"
  )
  jq -e '
    .class == "antigravity-class"
    and .provider == "antigravity"
    and .evidence == "fresh"
    and .binding.id == "gemini-weekly"
    and .binding.remaining == 98.99833
    and .binding.window_seconds == 604800
    and .binding.window_seconds_source == "meter-window-field"
    and (.gate_windows | length) == 1
    and .gate_windows[0].id == "gemini-5h"
    and .gate_windows[0].remaining == 97.99
    and ([.windows[].id] | index("3p-weekly") == null)
    and ([.windows[].id] | index("3p-5h") == null)
  ' <<< "$obs" >/dev/null || fail "antigravity adapter did not bind live summary roles: $obs"

  broken=$(
    FM_USAGE_ANTIGRAVITY_QUOTA_JSON='{"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":"bogus","resetTime":"nope","window":"weekly"}]}]}' \
      fm_usage_source_observe antigravity '{}' "$TEST_NOW"
  )
  jq -e '
    .evidence == "unreadable"
    and (.diagnostics | any(test("antigravity quota unreadable")))
    and (.binding? == null)
  ' <<< "$broken" >/dev/null || fail "broken antigravity quota must be loudly unreadable: $broken"
  pass "antigravity adapter scores gemini weekly budget, gates on gemini 5h, ignores 3p buckets, and fails loud"
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
    and .binding.role == "budget"
    and (.gate_windows | length) == 1
    and .gate_windows[0].id == "five_hour"
    and (.windows | length) == 2
  ' <<< "$obs" >/dev/null || fail "claude adapter binding wrong: $obs"

  obs=$(fm_usage_source_observe codex "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .class == "openai-class"
    and .binding.remaining == 60
    and .rate_limit_reset_credits.evidence == "fresh"
    and .rate_limit_reset_credits.available_count == 0
  ' <<< "$obs" >/dev/null || fail "codex adapter: $obs"

  obs=$(fm_usage_source_observe grok "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .class == "grok-class"
    and .binding.remaining == 13
    and .binding.id == "credits"
    and .binding.window_seconds == 604800
    and .binding.window_seconds_source == "meter"
    and .gate_windows[0].id == "product:grokbuild"
    and ([.windows[]
          | select(.id == "product:api" or .id == "product:chat" or .id == "product:voice")]
         | all(.role == "ignored"))
  ' <<< "$obs" >/dev/null || fail "grok adapter should bind the reported weekly credits budget: $obs"
  pass "anthropic/openai/grok adapters classify rate gates and durable budgets"
}

test_missing_window_period_is_not_fabricated() {
  local reset quota obs null_quota null_obs
  reset=$(iso_at_epoch $((TEST_NOW + 79678)))
  quota=$(jq -cn \
    --arg reset "$reset" '
    {
      providers:[{
        provider:"grok",
        state:{status:"fresh"},
        windows:[{
          id:"credits",
          kind:"credits",
          percentRemaining:11,
          resetsAt:$reset
        }]
      }]
    }')
  obs=$(fm_usage_source_observe grok "$quota" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .binding.id == "credits"
    and .binding.window_seconds == null
    and .binding.window_seconds_source == "missing"
  ' <<< "$obs" >/dev/null || fail "Grok adapter fabricated an unobserved period: $obs"
  null_quota=$(jq '.providers[0].windows[0].windowSeconds = null' <<< "$quota")
  null_obs=$(fm_usage_source_observe grok "$null_quota" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .binding.id == "credits"
    and .binding.window_seconds == null
    and .binding.window_seconds_source == "missing"
  ' <<< "$null_obs" >/dev/null || fail "Grok adapter replaced an explicit unknown period: $null_obs"
  pass "absent and explicitly null Grok periods remain missing evidence"
}

test_unconfigured_role_fallback_is_bounded() {
  local reset quota obs
  reset=$(iso_at_epoch $((TEST_NOW + 3600)))
  quota=$(jq -cn \
    --arg reset "$reset" '
    {
      providers:[{
        provider:"cursor",
        state:{status:"fresh"},
        windows:[{
          id:"requests",
          kind:"credits",
          percentRemaining:50,
          resetsAt:$reset,
          windowSeconds:604800
        }]
      }]
    }')
  obs=$(fm_usage_source_observe cursor "$quota" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .binding.role_source == "single-window-fallback"
    and .gate_windows[0].id == "requests"
  ' <<< "$obs" >/dev/null || fail "single unconfigured window did not become both gate and budget: $obs"

  quota=$(jq -c '
    .providers[0].windows += [{
      id:"other",
      kind:"credits",
      percentRemaining:40,
      resetsAt:.providers[0].windows[0].resetsAt,
      windowSeconds:604800
    }]
  ' <<< "$quota")
  obs=$(fm_usage_source_observe cursor "$quota" "$TEST_NOW")
  jq -e '.evidence == "unknown" and (.binding? == null)' \
    <<< "$obs" >/dev/null || fail "multiple unclassified windows should degrade unknown: $obs"
  pass "single-window fallback is both roles while ambiguous multi-window shapes degrade unknown"
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

test_offset_and_fractional_timestamps_parse() {
  local quota obs
  # Live quota-axi emits fractional seconds and +00:00; fromdateiso8601 needs Z.
  quota="$TMP_ROOT/offset-ts.json"
  cat > "$quota" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": {
        "status": "fresh",
        "refreshedAt": "$(iso_at_epoch $((TEST_NOW - 60)) | sed 's/Z$/.383+00:00/')"
      },
      "windows": [
        {
          "id": "five_hour",
          "kind": "session",
          "percentRemaining": 81,
          "resetsAt": "$(iso_at_epoch $((TEST_NOW + 3600)) | sed 's/Z$/.332186+00:00/')",
          "windowSeconds": 18000
        },
        {
          "id": "seven_day",
          "kind": "weekly",
          "percentRemaining": 67,
          "resetsAt": "$(iso_at_epoch $((TEST_NOW + 500000)) | sed 's/Z$/.332205+00:00/')",
          "windowSeconds": 604800
        }
      ]
    }
  ]
}
JSON
  obs=$(fm_usage_source_observe claude "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .binding.id == "seven_day"
    and .binding.remaining == 67
    and (.binding.T | type) == "number"
    and .binding.T > 0
  ' <<< "$obs" >/dev/null || fail "offset/fractional timestamps did not score as fresh: $obs"
  pass "fractional-second +00:00 timestamps parse into scorable Claude windows"
}

test_metered_predicate() {
  fm_usage_source_provider_is_metered claude || fail "claude must be metered"
  fm_usage_source_provider_is_metered codex || fail "codex must be metered"
  fm_usage_source_provider_is_metered grok || fail "grok must be metered"
  fm_usage_source_provider_is_metered antigravity || fail "antigravity must be metered"
  if fm_usage_source_provider_is_metered gemini; then
    fail "gemini must not be treated as metered"
  fi
  pass "metered predicate separates quota-axi providers from unmetered stubs"
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

test_codex_reset_credits_parse_shapes() {
  local parsed expired_at future_at
  future_at=$((TEST_NOW + 86400))
  expired_at=$((TEST_NOW - 60))

  parsed=$(fm_usage_source_parse_codex_rate_limit_reset_credits 'null' "$TEST_NOW")
  jq -e '.evidence == "fresh" and .available_count == 0 and .source == "absent-as-zero"' \
    <<< "$parsed" >/dev/null || fail "null raw must be genuine zero: $parsed"

  parsed=$(fm_usage_source_parse_codex_rate_limit_reset_credits \
    "{\"availableCount\":2}" "$TEST_NOW")
  jq -e '.evidence == "fresh" and .available_count == 2 and .source == "available-count-field"' \
    <<< "$parsed" >/dev/null || fail "availableCount-only shape: $parsed"

  parsed=$(fm_usage_source_parse_codex_rate_limit_reset_credits \
    '{"available_count":"nope"}' "$TEST_NOW")
  jq -e '.evidence == "unreadable" and .available_count == null' \
    <<< "$parsed" >/dev/null || fail "string available_count must be unreadable: $parsed"

  parsed=$(fm_usage_source_parse_codex_rate_limit_reset_credits \
    "$(jq -cn --argjson now "$TEST_NOW" --argjson fut "$future_at" --argjson exp "$expired_at" '
      {
        availableCount: 99,
        credits: [
          {status:"available", expiresAt:$fut, resetType:"codexRateLimits"},
          {status:"available", expiresAt:$exp, resetType:"codexRateLimits"},
          {status:"consumed", expiresAt:$fut, resetType:"codexRateLimits"},
          {status:"available", expiresAt:$fut, resetType:"codexRateLimits"}
        ]
      }
    ')" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .available_count == 2
    and .source == "credits-array-filtered"
    and .all_expired == false
  ' <<< "$parsed" >/dev/null || fail "mixed credits must count only available unexpired: $parsed"

  parsed=$(fm_usage_source_parse_codex_rate_limit_reset_credits \
    "$(jq -cn --argjson exp "$expired_at" '
      {
        availableCount: 1,
        credits: [
          {status:"available", expiresAt:$exp, resetType:"codexRateLimits"}
        ]
      }
    ')" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .available_count == 0
    and .source == "credits-array-all-expired"
    and .all_expired == true
  ' <<< "$parsed" >/dev/null || fail "all-expired set must be zero and marked: $parsed"

  pass "codex rateLimitResetCredits shapes parse with loud unreadable and availability filter"
}

test_codex_observe_attaches_reset_credits() {
  local quota obs
  quota="$TMP_ROOT/quota-codex-resets.json"
  cat > "$quota" <<JSON
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 70, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 18000 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 60, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 }
      ],
      "rateLimitResetCredits": {
        "availableCount": 1,
        "credits": [
          {
            "status": "available",
            "resetType": "codexRateLimits",
            "expiresAt": $((TEST_NOW + 100000))
          }
        ]
      }
    }
  ]
}
JSON
  obs=$(fm_usage_source_observe codex "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .rate_limit_reset_credits.available_count == 1
    and .rate_limit_reset_credits.evidence == "fresh"
    and .rate_limit_reset_credits.source == "credits-array-filtered"
  ' <<< "$obs" >/dev/null || fail "observe must attach filtered reset count: $obs"

  # Unreadable count is a loud named diagnostic; window evidence stays fresh so
  # an otherwise-valid dispatch is not poisoned (AC-2 interaction).
  cat > "$quota" <<JSON
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh", "refreshedAt": "$VALID_REFRESHED_AT" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 70, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 18000 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 60, "resetsAt": "$VALID_RESET_AT", "windowSeconds": 604800 }
      ],
      "rateLimitResetCredits": { "availableCount": "bogus" }
    }
  ]
}
JSON
  obs=$(fm_usage_source_observe codex "$(cat "$quota")" "$TEST_NOW")
  jq -e '
    .evidence == "fresh"
    and .binding.remaining == 60
    and .rate_limit_reset_credits.evidence == "unreadable"
    and (.diagnostics | any(test("unreadable"; "i")))
  ' <<< "$obs" >/dev/null || fail "unreadable reset credits must stay loud without poisoning windows: $obs"
  pass "codex observe attaches reset credits; unreadable is loud without demoting windows"
}

test_per_provider_target_floors() {
  local quota obs
  [ "$(fm_usage_source_target_percent claude)" = 10 ] || fail "claude target must be 10"
  [ "$(fm_usage_source_target_percent codex)" = 5 ] || fail "codex target must be 5"
  [ "$(fm_usage_source_target_percent grok)" = 5 ] || fail "grok target must be 5"
  [ "$(fm_usage_source_target_percent antigravity)" = 5 ] || fail "antigravity target must be 5"
  [ "$(fm_usage_source_target_percent gemini)" = 5 ] || fail "gemini target must be 5"
  [ "$(fm_usage_source_target_percent openrouter)" = 5 ] || fail "openrouter target must be 5"
  [ "$(fm_usage_source_target_percent cursor)" = 5 ] || fail "cursor target must be 5"
  [ "$(fm_usage_source_target_percent copilot)" = 5 ] || fail "copilot target must be 5"
  if fm_usage_source_target_percent openai 2>/dev/null; then
    fail "unrecognized provider must not invent a target"
  fi
  write_quota "$TMP_ROOT/targets.json"
  quota=$(cat "$TMP_ROOT/targets.json")
  obs=$(fm_usage_source_observe claude "$quota" "$TEST_NOW")
  jq -e '.target_percent == 10' <<< "$obs" >/dev/null \
    || fail "observe must carry claude registry target 10: $obs"
  obs=$(fm_usage_source_observe codex "$quota" "$TEST_NOW")
  jq -e '.target_percent == 5' <<< "$obs" >/dev/null \
    || fail "observe must carry codex registry target 5: $obs"
  jq -e '.trust_multiplier == 1 and .gated == false' \
    <<< "$(fm_usage_source_trust_policy claude)" >/dev/null \
    || fail "claude trust must be full and ungated"
  jq -e '.trust_multiplier == 1 and .gated == false' \
    <<< "$(fm_usage_source_trust_policy codex)" >/dev/null \
    || fail "codex trust must be full and ungated"
  jq -e '.trust_multiplier == 0.75 and .gated == false' \
    <<< "$(fm_usage_source_trust_policy grok)" >/dev/null \
    || fail "grok trust must be 0.75 and not gated"
  jq -e '
    .trust_multiplier == 0.4
    and .gated == true
    and .wake_below == 0.35
    and .full_at == 0.05
  ' <<< "$(fm_usage_source_trust_policy antigravity)" >/dev/null \
    || fail "antigravity trust/gate policy must be declared as provider data"
  pass "per-provider target floors are registry data and ride on observations"
}

test_class_map
test_provider_registry_distinguishes_unknown_tokens
test_per_provider_target_floors
test_antigravity_live_summary_adapter
test_quota_backed_adapters
test_missing_window_period_is_not_fabricated
test_unconfigured_role_fallback_is_bounded
test_stubs_degrade_unknown
test_absent_provider_unknown
test_offset_and_fractional_timestamps_parse
test_metered_predicate
test_observe_profiles_dedupes
test_codex_reset_credits_parse_shapes
test_codex_observe_attaches_reset_credits

echo "# all fm-usage-source-lib tests passed"
