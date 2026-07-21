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
cat <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": ${FM_FAKE_CLAUDE_REMAINING:-100} },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": ${FM_FAKE_CODEX_REMAINING:-100} },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "grok",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "credits", "kind": "credits", "percentRemaining": ${FM_FAKE_GROK_REMAINING:-100} }
      ]
    }
  ]
}
JSON
SH
  chmod +x "$fakebin/quota-axi"
  fm_fake_exit0 "$fakebin" treehouse
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
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
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
    FM_FAKE_CODEX_REMAINING="${FM_FAKE_CODEX_REMAINING:-100}" \
    FM_FAKE_GROK_REMAINING="${FM_FAKE_GROK_REMAINING:-100}" \
    FM_FAKE_QUOTA_EXIT="${FM_FAKE_QUOTA_EXIT:-0}" \
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

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass the explicit provider and harness returned by dispatch admission" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass the explicit provider and harness returned by dispatch admission" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_requires_provider_with_explicit_harness() {
  local rec id out status
  id=profile-provider-required-z13
  rec=$(make_spawn_case profile-provider-required claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "explicit harness without provider should not bypass admission"
  assert_contains "$out" "pass the explicit provider and harness returned by dispatch admission" \
    "spawn did not explain the provider admission backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "provider refusal should happen before meta is written"
  pass "active crew-dispatch profile requires provider identity with the explicit harness"
}

test_active_dispatch_profile_allows_admitted_profile() {
  local rec id out status launch shelllog
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider codex --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "admitted provider/harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "provider=codex" "$HOME_DIR/state/$id.meta" "meta missing provider pin"
  assert_grep "quota_posture=normal" "$HOME_DIR/state/$id.meta" "meta missing quota posture"
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

  out=$(FM_FAKE_CODEX_REMAINING=5 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider codex --harness codex \
    --quota-posture normal --quota-used 10)
  status=$?
  expect_code 75 "$status" "caller-supplied quota fields must not bypass current freeze"
  assert_contains "$out" "admission refused: provider 'codex' is freeze at 95% used" \
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
    --model anthropic/claude-sonnet-4-5)
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
    "$id" "$PROJ_DIR" codex --provider codex --model gpt-5 --effort high)
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
    "$id" "$PROJ_DIR" "custom-agent --flag" --provider custom-provider)
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  assert_grep "provider=custom-provider" "$HOME_DIR/state/$id.meta" "meta missing custom provider pin"
  assert_grep "quota_posture=unknown" "$HOME_DIR/state/$id.meta" "unknown provider should admit with unknown posture"
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "raw harness must not export NO_MISTAKES_RUN_AGENTS: $(cat "$shelllog")"
  fi
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_grok_default_dispatch_admits_without_silent_substitution() {
  local rec id out status
  id=profile-grok-default-z22
  rec=$(make_spawn_case profile-grok-default claude "$id")
  read_case_record "$rec"
  printf '%s\n' '{"rules":[],"default":{"harness":"grok","model":"grok-4.5","effort":"high"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --provider grok --harness grok --model grok-4.5 --effort high)
  status=$?
  expect_code 0 "$status" "temporary Grok-default dispatch should still admit"
  assert_contains "$out" "spawned $id harness=grok" "spawn did not keep the Grok pin"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4.5 high
  assert_grep "provider=grok" "$HOME_DIR/state/$id.meta" "meta missing grok provider pin"
  # Grok has no general session windows in quota-axi; posture stays unknown rather
  # than inventing a substitute provider or blocking the temporary Grok-default policy.
  assert_grep "quota_posture=unknown" "$HOME_DIR/state/$id.meta" "grok without general windows should keep unknown posture"
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

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status shelllog
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --provider codex --harness codex --model gpt-5 --effort high)
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
  run_spawn "$dhome" "$dwt" "$dfake" "$dlog" "$did" "$dhome/../project" --provider codex --harness codex > "$dout" &
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

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_requires_provider_with_explicit_harness
test_active_dispatch_profile_allows_admitted_profile
test_active_dispatch_profile_cannot_bypass_freeze
test_existing_task_profile_is_immutable
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_grok_default_dispatch_admits_without_silent_substitution
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_omits_invalid_max_effort
test_batch_forwards_shared_profile_flags
test_concurrent_static_and_dispatch_assignments_do_not_cross_talk
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
