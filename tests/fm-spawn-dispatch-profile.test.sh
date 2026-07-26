#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-dispatch-profile

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    for a in "$@"; do case "$a" in *"treehouse get --lease --lease-holder "*)
      fake_root="$(cd "$(dirname "$0")/.." && pwd)"
      holder_file="$fake_root/holder"
      holder=$(printf '%s\n' "$a" | sed -n "s/.*treehouse get --lease --lease-holder '\([^']*\)'.*/\1/p")
      if [ -n "$holder" ]; then
        rm -f "$fake_root/returned"
        printf '%s\n' "$holder" > "$holder_file"
      fi
    ;; esac; done
    if [ -n "${FM_FAKE_SHELL_LOG:-}" ] && [ "${4:-}" != "-l" ]; then
      printf '%s\n' "${4:-}" >> "$FM_FAKE_SHELL_LOG"
    fi
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_QUOTA_EXIT:-0}" -eq 0 ] || exit "$FM_FAKE_QUOTA_EXIT"
# Default: carry an explicit rateLimitResetCredits observation so live enrich
# does not shell out to a real codex app-server. Set FM_FAKE_CODEX_RESET_UNREADABLE=1
# to inject a deliberately unreadable count (AC-2 loud-error path).
if [ "${FM_FAKE_CODEX_RESET_UNREADABLE:-0}" = 1 ]; then
  codex_reset='"rateLimitResetCredits": { "availableCount": "bogus-not-a-number" }'
else
  codex_reset='"rateLimitResetCredits": { "availableCount": '"${FM_FAKE_CODEX_RESET_COUNT:-0}"', "credits": [] }'
fi
cat <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": ${FM_FAKE_CLAUDE_REMAINING:-100}, "resetsAt": "2099-01-01T00:00:00Z", "windowSeconds": 18000 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": ${FM_FAKE_CLAUDE_BUDGET_REMAINING:-100}, "resetsAt": "2099-01-01T00:00:00Z", "windowSeconds": 604800 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": ${FM_FAKE_CODEX_REMAINING:-100}, "resetsAt": "2099-01-01T00:00:00Z", "windowSeconds": 18000 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": ${FM_FAKE_CODEX_BUDGET_REMAINING:-100}, "resetsAt": "2099-01-01T00:00:00Z", "windowSeconds": 604800 }
      ],
      ${codex_reset}
    },
    {
      "provider": "grok",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "credits", "kind": "credits", "percentRemaining": ${FM_FAKE_GROK_REMAINING:-100}, "resetsAt": "2099-01-01T00:00:00Z", "windowSeconds": 604800 }
      ]
    }
  ]
}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    fake_root="$(cd "$(dirname "$0")/.." && pwd)"
    holder_file="$fake_root/holder"
    returned_file="$fake_root/returned"
    if [ -f "$returned_file" ]; then
      printf '1  available  %s\n' "${FM_FAKE_PANE_PATH:-}"
      exit 0
    fi
    [ -f "$holder_file" ] || exit 1
    holder=$(cat "$holder_file")
    [ -n "$holder" ] || exit 1
    printf '1  leased  %s  (held by %s)\n' "${FM_FAKE_PANE_PATH:-}" "$holder"
    exit 0 ;;
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  return)
    fake_root="$(cd "$(dirname "$0")/.." && pwd)"
    [ "${2:-}" = --force ] && : > "$fake_root/returned"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
    fm_write_criteria "$home/data" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"select":"usage-burndown","use":[{"provider":"codex","harness":"codex","model":"gpt-5","effort":"medium"},{"provider":"grok","harness":"grok","model":"grok-4.5","effort":"high"}]}}' \
    > "$home/config/crew-dispatch.json"
}

enable_antigravity_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[],"default":{"select":"usage-burndown","use":[{"provider":"claude","harness":"claude","model":"claude-opus-5","effort":"xhigh"},{"provider":"codex","harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"},{"provider":"grok","harness":"grok","model":"grok-4.5","effort":"high"},{"provider":"antigravity","harness":"agy","model":"gemini-3.1-pro-high"}]}}' \
    > "$home/config/crew-dispatch.json"
}

antigravity_quota_json() {
  cat <<'JSON'
{
  "groups": [
    {
      "displayName": "Gemini Models",
      "buckets": [
        {
          "bucketId": "gemini-weekly",
          "displayName": "Weekly Limit",
          "remainingFraction": 1,
          "resetTime": "2099-01-01T00:00:00Z",
          "window": "weekly"
        },
        {
          "bucketId": "gemini-5h",
          "displayName": "Five Hour Limit",
          "remainingFraction": 1,
          "resetTime": "2099-01-01T00:00:00Z",
          "window": "5h"
        }
      ]
    },
    {
      "displayName": "Claude and GPT models",
      "buckets": [
        {
          "bucketId": "3p-weekly",
          "displayName": "Weekly Limit",
          "remainingFraction": 1,
          "resetTime": "2099-01-01T00:00:00Z",
          "window": "weekly"
        },
        {
          "bucketId": "3p-5h",
          "displayName": "Five Hour Limit",
          "remainingFraction": 1,
          "resetTime": "2099-01-01T00:00:00Z",
          "window": "5h"
        }
      ]
    }
  ]
}
JSON
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 shelllog
  shift 4
  shelllog="${launchlog%.log}.shell.log"
  : > "$launchlog"
  : > "$shelllog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_SHELL_LOG="$shelllog" \
    FM_FAKE_CLAUDE_REMAINING="${FM_FAKE_CLAUDE_REMAINING:-100}" \
    FM_FAKE_CLAUDE_BUDGET_REMAINING="${FM_FAKE_CLAUDE_BUDGET_REMAINING:-100}" \
    FM_FAKE_CODEX_REMAINING="${FM_FAKE_CODEX_REMAINING:-100}" \
    FM_FAKE_CODEX_BUDGET_REMAINING="${FM_FAKE_CODEX_BUDGET_REMAINING:-100}" \
    FM_FAKE_GROK_REMAINING="${FM_FAKE_GROK_REMAINING:-100}" \
    FM_FAKE_QUOTA_EXIT="${FM_FAKE_QUOTA_EXIT:-0}" \
    FM_FAKE_CODEX_RESET_UNREADABLE="${FM_FAKE_CODEX_RESET_UNREADABLE:-0}" \
    FM_FAKE_CODEX_RESET_COUNT="${FM_FAKE_CODEX_RESET_COUNT:-0}" \
    FM_USAGE_ANTIGRAVITY_QUOTA_JSON="${FM_USAGE_ANTIGRAVITY_QUOTA_JSON:-}" \
    FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_launch_unchanged() {
  local rec id out status expected launch shelllog
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch changed"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "must not export NO_MISTAKES_RUN_AGENTS from harness: $(cat "$shelllog")"
  fi
  pass "no --model/--effort records defaults and keeps the claude launch byte-identical"
}

test_active_dispatch_profile_self_routes_ship() {
  local rec id out status meta candidates
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "ship spawn without routing arguments should route itself"
  assert_contains "$out" "spawned $id harness=codex" "self-routed ship did not launch the selected harness"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_profile "$meta" codex gpt-5 medium
  assert_grep "dispatch_origin=algorithm" "$meta" "self-routed ship meta did not identify algorithm routing"
  assert_grep "dispatch_order=score-desc,S-desc,R-desc,T-asc,index-asc" "$meta" \
    "self-routed ship meta did not record the total candidate order"
  candidates=$(sed -n 's/^dispatch_candidates_json=//p' "$meta")
  jq -e 'length == 2 and .[0].provider == "codex" and .[1].provider == "grok"' \
    <<< "$candidates" >/dev/null || fail "self-routed ship meta did not carry every candidate: $candidates"
  pass "active crew-dispatch profile self-routes ship spawns"
}

test_active_dispatch_profile_self_routes_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn without routing arguments should route itself"
  assert_contains "$out" "spawned $id harness=codex kind=scout" "self-routed scout did not launch the selected harness"
  assert_grep "dispatch_origin=algorithm" "$HOME_DIR/state/$id.meta" \
    "self-routed scout meta did not identify algorithm routing"
  pass "active crew-dispatch profile self-routes scout spawns"
}

test_active_dispatch_profile_requires_override_reason() {
  local rec id out status
  id=profile-provider-required-z13
  rec=$(make_spawn_case profile-provider-required claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 2 "$status" "explicit routing without a reason must fail"
  assert_contains "$out" "requires --override-reason" \
    "spawn did not explain how to make an intentional routing override"
  assert_absent "$HOME_DIR/state/$id.meta" "unexplained override should fail before meta is written"
  pass "active crew-dispatch profile requires a reason for explicit routing"
}

test_active_dispatch_profile_allows_admitted_profile() {
  local rec id out status launch shelllog
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider codex --harness codex --model gpt-5 --effort high \
    --override-reason "captain requested codex for this task")
  status=$?
  expect_code 0 "$status" "admitted provider/harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "provider=codex" "$HOME_DIR/state/$id.meta" "meta missing provider pin"
  assert_grep "quota_posture=normal" "$HOME_DIR/state/$id.meta" "meta missing quota posture"
  assert_grep "dispatch_origin=override" "$HOME_DIR/state/$id.meta" "meta did not distinguish explicit override"
  assert_grep "dispatch_override_reason=captain requested codex for this task" "$HOME_DIR/state/$id.meta" \
    "meta did not record the override reason"
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "must not export NO_MISTAKES_RUN_AGENTS from dispatch harness: $(cat "$shelllog")"
  fi
  pass "active crew-dispatch profile re-admits and records the current mechanical posture"
}

test_active_dispatch_profile_cannot_bypass_freeze() {
  local rec id out status
  id=profile-freeze-z21
  rec=$(make_spawn_case profile-freeze claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(FM_FAKE_CODEX_BUDGET_REMAINING=5 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider codex --harness codex \
    --quota-posture normal --quota-used 10 --override-reason "captain pinned codex")
  status=$?
  expect_code 75 "$status" "caller-supplied quota fields must not bypass current freeze"
  assert_contains "$out" "reached the 5% provider target floor" \
    "spawn did not surface the mechanically rechecked freeze"
  assert_absent "$HOME_DIR/state/$id.meta" "frozen new work must not receive an admitted profile pin"
  pass "spawn mechanically rechecks admission and refuses caller attempts to bypass freeze"
}

test_existing_task_profile_is_immutable() {
  local rec id out status meta before
  id=profile-pinned-z20
  rec=$(make_spawn_case profile-pinned claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider claude --harness opencode \
    --model anthropic/claude-sonnet-4-5 --override-reason "captain pinned opencode")
  status=$?
  expect_code 0 "$status" "initial admitted pin should spawn"
  meta="$HOME_DIR/state/$id.meta"
  before=$(cat "$meta")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider codex --harness codex --model gpt-5)
  status=$?
  expect_code 1 "$status" "replacement profile must be refused"
  assert_contains "$out" "already has a pinned profile provider=claude harness=opencode model=anthropic/claude-sonnet-4-5 effort=default" \
    "replacement refusal did not surface the recorded pin"
  assert_contains "$out" "resume that recorded task/profile" "replacement refusal was not actionable"
  [ "$(cat "$meta")" = "$before" ] || fail "replacement attempt modified the pinned metadata"
  pass "recorded task profile pin is immutable"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --provider codex --model gpt-5 --effort high \
    --override-reason "captain requested positional codex")
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch shelllog
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag" --provider codex \
    --override-reason "adapter verification")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  assert_grep "provider=codex" "$HOME_DIR/state/$id.meta" "meta missing recognized provider pin"
  assert_grep "quota_posture=normal" "$HOME_DIR/state/$id.meta" "recognized provider should admit from fresh evidence"
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "raw harness must not export NO_MISTAKES_RUN_AGENTS: $(cat "$shelllog")"
  fi
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_spawn_refuses_unrecognized_provider_without_selector_backstop() {
  local kind rec id out status
  for kind in ship scout; do
    id="profile-unrecognized-$kind-z24"
    rec=$(make_spawn_case "profile-unrecognized-$kind" codex "$id")
    read_case_record "$rec"
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --provider typo-provider --harness codex \
        --override-reason "negative fixture" --scout)
    else
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --provider typo-provider --harness codex \
        --override-reason "negative fixture")
    fi
    status=$?
    expect_code 64 "$status" "$kind spawn with an unrecognized provider must refuse"
    assert_contains "$out" "unrecognized provider token 'typo-provider'" \
      "$kind refusal did not name the bad provider token"
    assert_contains "$out" "recognized providers: claude, codex, grok, antigravity, gemini, openrouter, cursor, copilot" \
      "$kind refusal did not name the shared recognized set"
    assert_absent "$HOME_DIR/state/$id.meta" "$kind refusal should happen before meta is written"
    [ ! -s "$LAUNCH_LOG" ] || fail "$kind refusal reached harness launch: $(cat "$LAUNCH_LOG")"
  done
  pass "ship and scout spawns independently refuse unrecognized provider identities"
}

test_grok_default_dispatch_admits_without_silent_substitution() {
  local rec id out status
  id=profile-grok-default-z22
  rec=$(make_spawn_case profile-grok-default claude "$id")
  read_case_record "$rec"
  printf '%s\n' '{"rules":[],"default":{"harness":"grok","model":"grok-4.5","effort":"high"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider grok --harness grok --model grok-4.5 --effort high \
    --override-reason "temporary grok directive")
  status=$?
  expect_code 0 "$status" "temporary Grok-default dispatch should still admit"
  assert_contains "$out" "spawned $id harness=grok" "spawn did not keep the Grok pin"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4.5 high
  assert_grep "provider=grok" "$HOME_DIR/state/$id.meta" "meta missing grok provider pin"
  # Grok-class adapter scores non-model credit windows from quota-axi; the fixture
  # supplies full credits remaining, so posture is normal and the pin is kept
  # (never silently substituted to another provider).
  assert_grep "quota_posture=normal" "$HOME_DIR/state/$id.meta" "grok with credit windows should admit with observed posture"
  pass "Grok-default temporary policy admits without silent harness substitution"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch shelllog
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "grok must not export NO_MISTAKES_RUN_AGENTS from harness: $(cat "$shelllog")"
  fi
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$(cat " \
    "grok launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should not pass an invalid flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi sonnet max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "pi --model 'sonnet' -e" "pi launch did not thread model"
  assert_not_contains "$launch" "--thinking" "pi launch must omit --thinking max because the CLI rejects it"
  pass "pi threads model and omits unsupported max effort"
}

test_agy_threads_model_and_baked_effort() {
  local rec id out status launch hook
  id=profile-agy-z31
  rec=$(make_spawn_case profile-agy agy "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider antigravity --harness agy \
    --model gemini-3.1-pro-high --effort high \
    --override-reason "captain set antigravity profile")
  status=$?
  expect_code 0 "$status" "agy spawn should accept the captain's antigravity profile"
  assert_contains "$out" "spawned $id harness=agy" "spawn did not report agy harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" agy gemini-3.1-pro-high high
  assert_grep "provider=antigravity" "$HOME_DIR/state/$id.meta" "meta missing antigravity provider pin"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "agy --dangerously-skip-permissions --model 'gemini-3.1-pro-high' --prompt-interactive" \
    "agy launch did not pass the model token or prompt-interactive path: $launch"
  assert_not_contains "$launch" "--effort" \
    "agy launch must omit --effort when the model token already carries low/medium/high: $launch"
  hook="$WT_DIR/.agents/hooks.json"
  assert_present "$hook" "agy Stop hook was not installed"
  assert_contains "$(cat "$hook")" '"fm-turn-end"' "agy hook does not use the named hook format"
  assert_contains "$(cat "$hook")" "$HOME_DIR/state/$id.turn-ended" "agy hook does not touch this task's turn-ended file"
  pass "agy launch threads model-only baked effort and installs the documented Stop hook"
}

test_agy_effort_only_flag() {
  local rec id out status launch
  id=profile-agy-effort-z32
  rec=$(make_spawn_case profile-agy-effort agy "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider antigravity --harness agy --effort low \
    --override-reason "probe agy effort-only path")
  status=$?
  expect_code 0 "$status" "agy effort-only spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "agy --dangerously-skip-permissions --effort 'low' --prompt-interactive" \
    "agy effort-only launch did not pass --effort low: $launch"
  pass "agy passes --effort only when no model token already encodes effort"
}

test_agy_existing_hook_is_refused() {
  local rec id out status
  id=profile-agy-existing-hook-z33
  rec=$(make_spawn_case profile-agy-existing-hook agy "$id")
  read_case_record "$rec"
  mkdir -p "$WT_DIR/.agents"
  printf '{}\n' > "$WT_DIR/.agents/hooks.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider antigravity --harness agy \
    --override-reason "probe agy hook collision")
  status=$?
  expect_code 1 "$status" "agy spawn must refuse to replace an existing workspace hook"
  assert_contains "$out" "refusing to replace existing Antigravity hook" \
    "agy hook collision did not fail closed: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "failed agy hook collision must not publish meta"
  pass "agy spawn refuses to replace a project-owned .agents/hooks.json"
}

test_antigravity_default_dispatch_selects_agy_when_gate_opens() {
  local rec id out status meta launch candidates
  id=profile-agy-dispatch-z34
  rec=$(make_spawn_case profile-agy-dispatch claude "$id")
  read_case_record "$rec"
  enable_antigravity_dispatch_profile "$HOME_DIR"

  out=$(
    FM_FAKE_CLAUDE_REMAINING=10 \
    FM_FAKE_CLAUDE_BUDGET_REMAINING=10 \
    FM_FAKE_CODEX_REMAINING=5 \
    FM_FAKE_CODEX_BUDGET_REMAINING=5 \
    FM_FAKE_GROK_REMAINING=5 \
    FM_USAGE_ANTIGRAVITY_QUOTA_JSON="$(antigravity_quota_json)" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"
  )
  status=$?
  expect_code 0 "$status" "antigravity default profile should route when full-trust providers are at floor"
  assert_contains "$out" "spawned $id harness=agy" "default dispatch did not select agy when its gate opened: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_profile "$meta" agy gemini-3.1-pro-high default
  assert_grep "provider=antigravity" "$meta" "meta missing antigravity provider"
  assert_grep "dispatch_origin=algorithm" "$meta" "meta missing algorithm dispatch origin"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "agy --dangerously-skip-permissions --model 'gemini-3.1-pro-high' --prompt-interactive" \
    "selected antigravity launch did not use the agy harness/model: $launch"
  assert_not_contains "$launch" "--effort" "baked antigravity model must not also pass an effort flag: $launch"
  candidates=$(sed -n 's/^dispatch_candidates_json=//p' "$meta")
  jq -e '
    length == 4
    and (map(select(.provider == "antigravity" and .profile.harness == "agy" and .eligible == true and .gate_weight == 1)) | length) == 1
    and (map(select(.provider == "claude" or .provider == "codex" or .provider == "grok") | select(.posture == "freeze")) | length) == 3
  ' <<< "$candidates" >/dev/null || fail "antigravity default candidate evidence missing: $candidates"
  pass "default dispatch can select the antigravity/agy profile when the fallback gate opens"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status shelllog
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --provider codex --harness codex --model gpt-5 --effort high \
    --override-reason "captain pinned batch")
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_grep "provider=codex" "$HOME_DIR/state/$id1.meta" "batch first task missing provider pin"
  assert_grep "provider=codex" "$HOME_DIR/state/$id2.meta" "batch second task missing provider pin"
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "batch must not export NO_MISTAKES_RUN_AGENTS from harness: $(cat "$shelllog")"
  fi
  pass "batch dispatch forwards the admitted profile and observation to every pair"
}

test_concurrent_static_and_dispatch_assignments_do_not_cross_talk() {
  local static_rec dispatch_rec sid did sout dout spid dpid src=0 drc=0
  local shome swt sfake slog dhome dwt dfake dlog sshell dshell
  sid=profile-concurrent-static-z17
  did=profile-concurrent-dispatch-z18

  static_rec=$(make_spawn_case profile-concurrent-static claude "$sid")
  read_case_record "$static_rec"
  shome=$HOME_DIR; swt=$WT_DIR; sfake=$FAKEBIN_DIR; slog=$LAUNCH_LOG

  dispatch_rec=$(make_spawn_case profile-concurrent-dispatch claude "$did")
  read_case_record "$dispatch_rec"
  enable_dispatch_profile "$HOME_DIR"
  dhome=$HOME_DIR; dwt=$WT_DIR; dfake=$FAKEBIN_DIR; dlog=$LAUNCH_LOG

  sout="$TMP_ROOT/static.out"
  dout="$TMP_ROOT/dispatch.out"
  run_spawn "$shome" "$swt" "$sfake" "$slog" "$sid" "$shome/../project" > "$sout" &
  spid=$!
  run_spawn "$dhome" "$dwt" "$dfake" "$dlog" "$did" "$dhome/../project" \
    --provider codex --harness codex --override-reason "concurrency fixture" > "$dout" &
  dpid=$!
  wait "$spid" || src=$?
  wait "$dpid" || drc=$?
  expect_code 0 "$src" "concurrent static claude spawn should succeed"
  expect_code 0 "$drc" "concurrent dispatch codex spawn should succeed"

  sshell="${slog%.log}.shell.log"
  dshell="${dlog%.log}.shell.log"
  assert_grep "export GOTMPDIR=" "$sshell" "concurrent static worker missing GOTMPDIR"
  assert_grep "export GOTMPDIR=" "$dshell" "concurrent dispatch worker missing GOTMPDIR"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$sshell" "$dshell"; then
    fail "concurrent workers must not export harness NO_MISTAKES_RUN_AGENTS"
  fi
  pass "concurrent static and dispatch workers launch without harness-parity agent export"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_unreadable_codex_reset_is_loud_without_poisoning_dispatch() {
  local rec id out status meta candidates
  id=profile-codex-reset-unreadable-z20
  rec=$(make_spawn_case profile-codex-reset-unreadable claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  # Deliberate AC-2 case: reset count is unreadable, windows are valid.
  # Must loud-error the reset without dispatch_error / selecting grok.
  out=$(
    FM_FAKE_CODEX_RESET_UNREADABLE=1 \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"
  )
  status=$?
  expect_code 0 "$status" "unreadable codex reset must not fail an otherwise-valid spawn"
  assert_contains "$out" "spawned $id harness=codex" \
    "unreadable reset poisoned dispatch away from codex windows: $out"
  assert_contains "$out" "error: unreadable rate-limit reset credits for provider 'codex'" \
    "unreadable reset must be a loud named error: $out"
  assert_not_contains "$out" "dispatch_error=usage-evidence-unreadable" \
    "unreadable reset must not mark whole usage evidence unreadable: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_meta_profile "$meta" codex gpt-5 medium
  assert_grep "dispatch_origin=algorithm" "$meta" "algorithm origin missing under unreadable reset"
  candidates=$(sed -n 's/^dispatch_candidates_json=//p' "$meta")
  jq -e '
    length == 2
    and (map(select(.provider == "codex")) | length) == 1
    and (map(select(.provider == "codex" and .scorable == true)) | length) == 1
    and (map(select(.provider == "codex" and (.reset_count_unreadable == true or (.pressure_source // "" | test("codex-reset-unreadable"))))) | length) == 1
  ' <<< "$candidates" >/dev/null \
    || fail "codex must stay scorable with unreadable reset surface: $candidates"
  pass "unreadable codex reset is loud and does not poison an otherwise-valid dispatch"
}

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_self_routes_ship
test_active_dispatch_profile_self_routes_scout
test_active_dispatch_profile_requires_override_reason
test_active_dispatch_profile_allows_admitted_profile
test_active_dispatch_profile_cannot_bypass_freeze
test_existing_task_profile_is_immutable
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_spawn_refuses_unrecognized_provider_without_selector_backstop
test_grok_default_dispatch_admits_without_silent_substitution
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_omits_invalid_max_effort
test_agy_threads_model_and_baked_effort
test_agy_effort_only_flag
test_agy_existing_hook_is_refused
test_antigravity_default_dispatch_selects_agy_when_gate_opens
test_batch_forwards_shared_profile_flags
test_concurrent_static_and_dispatch_assignments_do_not_cross_talk
test_active_dispatch_profile_does_not_block_secondmate_launch
test_unreadable_codex_reset_is_loud_without_poisoning_dispatch

echo "# all fm-spawn-dispatch-profile tests passed"
