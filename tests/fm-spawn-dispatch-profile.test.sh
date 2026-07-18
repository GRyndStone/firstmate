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
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

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
  list-windows)
    [ -z "${FM_FAKE_INVENTORY_UNKNOWN:-}" ] || { echo 'inventory failed' >&2; exit 2; }
    exit 0
    ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  new-window)
    if [ -n "${FM_FAKE_ENDPOINT_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    fi
    [ -z "${FM_FAKE_ENDPOINT_READY:-}" ] || : > "$FM_FAKE_ENDPOINT_READY"
    while [ -n "${FM_FAKE_ENDPOINT_RELEASE:-}" ] && [ ! -e "$FM_FAKE_ENDPOINT_RELEASE" ]; do
      sleep 0.05
    done
    [ -z "${FM_FAKE_ENDPOINT_FAIL:-}" ] || exit 1
    printf '@1\n'
    exit 0
    ;;
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
  printf '## In flight\n\n' > "$home/data/backlog.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
    printf -- '- [ ] %s - test task\n' "$id" >> "$home/data/backlog.md"
  done
  printf '\n## Queued\n\n## Done\n' >> "$home/data/backlog.md"
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
    FM_FAKE_ENDPOINT_LOG="${FM_FAKE_ENDPOINT_LOG:-}" \
    FM_FAKE_ENDPOINT_READY="${FM_FAKE_ENDPOINT_READY:-}" \
    FM_FAKE_ENDPOINT_RELEASE="${FM_FAKE_ENDPOINT_RELEASE:-}" \
    FM_FAKE_ENDPOINT_FAIL="${FM_FAKE_ENDPOINT_FAIL:-}" \
    FM_FAKE_INVENTORY_UNKNOWN="${FM_FAKE_INVENTORY_UNKNOWN:-}" \
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
  assert_grep "export NO_MISTAKES_RUN_AGENTS='claude'" "$shelllog" \
    "static crew-harness resolution did not export claude to no-mistakes"
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
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
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
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch shelllog
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  assert_grep "export NO_MISTAKES_RUN_AGENTS='codex'" "$shelllog" \
    "dispatch-resolved harness did not export codex to no-mistakes"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
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
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  assert_contains "$out" "harness 'custom-agent' is not supported by private no-mistakes run agents" \
    "raw unsupported harness did not warn that validation will fail closed"
  assert_grep "export NO_MISTAKES_RUN_AGENTS='custom-agent'" "$shelllog" \
    "raw unsupported harness was not exported literally for fail-closed validation"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
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
  assert_contains "$out" "harness 'grok' is not supported by private no-mistakes run agents" \
    "grok did not warn that no-mistakes validation will fail closed"
  assert_grep "export NO_MISTAKES_RUN_AGENTS='grok'" "$shelllog" \
    "grok was not exported literally for fail-closed validation"
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
  local rec id1 id2 out status shelllog count
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  count=$(grep -cFx "export NO_MISTAKES_RUN_AGENTS='codex'" "$shelllog" || true)
  [ "$count" -eq 2 ] || fail "batch exported codex validation assignment $count times, want 2"
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
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
  run_spawn "$dhome" "$dwt" "$dfake" "$dlog" "$did" "$dhome/../project" --harness codex > "$dout" &
  dpid=$!
  wait "$spid" || src=$?
  wait "$dpid" || drc=$?
  expect_code 0 "$src" "concurrent static claude spawn should succeed"
  expect_code 0 "$drc" "concurrent dispatch codex spawn should succeed"

  sshell="${slog%.log}.shell.log"
  dshell="${dlog%.log}.shell.log"
  assert_grep "export NO_MISTAKES_RUN_AGENTS='claude'" "$sshell" \
    "concurrent static worker did not receive claude"
  assert_not_contains "$(cat "$sshell")" "NO_MISTAKES_RUN_AGENTS='codex'" \
    "dispatch worker assignment crossed into the static worker pane"
  assert_grep "export NO_MISTAKES_RUN_AGENTS='codex'" "$dshell" \
    "concurrent dispatch worker did not receive codex"
  assert_not_contains "$(cat "$dshell")" "NO_MISTAKES_RUN_AGENTS='claude'" \
    "static worker assignment crossed into the dispatch worker pane"
  pass "concurrent static and dispatch workers receive distinct no-mistakes assignments without cross-talk"
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

test_secondmate_recovery_refuses_symlinked_metadata() {
  local rec id sm outside out status
  id=profile-secondmate-meta-symlink-z17
  rec=$(make_spawn_case profile-secondmate-meta-symlink codex "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  outside="$CASE_DIR/foreign.meta"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'home=%s\n' "$sm" > "$outside"
  ln -s "$outside" "$HOME_DIR/state/$id.meta"
  status=0
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --secondmate) || status=$?
  expect_code 1 "$status" "secondmate recovery from symlinked metadata"
  assert_contains "$out" "task metadata is symlinked or non-regular" \
    "secondmate recovery parsed a symlinked metadata home"
  assert_present "$outside" "secondmate recovery removed foreign metadata"
  assert_absent "$CASE_DIR/endpoint.log" "secondmate recovery created an endpoint from foreign metadata"
  pass "secondmate recovery rejects symlinked metadata before reading home ownership"
}

test_spawn_invalidates_all_same_id_completion_receipts_before_endpoint() {
  local rec id out status claim endpoint_log
  id=profile-receipt-z19
  rec=$(make_spawn_case profile-receipt claude "$id")
  read_case_record "$rec"
  claim="$HOME_DIR/state/.$id.teardown-complete.claimed.stale"
  endpoint_log="$CASE_DIR/endpoint.log"
  printf 'canonical\n' > "$HOME_DIR/state/$id.teardown-complete"
  mkdir "$claim"
  printf 'claimed\n' > "$claim/proof"

  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with stale completion receipts should succeed after invalidation"
  assert_absent "$HOME_DIR/state/$id.teardown-complete" \
    "spawn left a reusable canonical completion proof"
  assert_absent "$claim" "spawn left a reusable interrupted completion claim"
  assert_absent "$HOME_DIR/state/$id.spawning" "successful spawn retained lifecycle ownership"
  assert_present "$endpoint_log" "spawn did not create its endpoint after safe receipt invalidation"

  id=profile-receipt-failure-z20
  rec=$(make_spawn_case profile-receipt-failure claude "$id")
  read_case_record "$rec"
  claim="$HOME_DIR/state/.$id.teardown-complete.claimed.unsafe"
  endpoint_log="$CASE_DIR/endpoint.log"
  mkdir "$claim"
  printf 'claimed\n' > "$claim/proof"
  printf 'unexpected\n' > "$claim/extra"
  status=0
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn with an unsafe completion claim"
  assert_contains "$out" "could not invalidate completion receipts safely before spawning $id" \
    "spawn did not report unsafe receipt invalidation"
  assert_absent "$HOME_DIR/state/$id.spawning" \
    "receipt invalidation refusal retained ownership despite no endpoint attempt"
  assert_absent "$endpoint_log" "spawn created an endpoint after receipt invalidation failed"
  assert_absent "$HOME_DIR/state/$id.meta" "spawn wrote lifecycle meta after receipt invalidation failed"
  pass "spawn invalidates canonical and claimed receipts before endpoint creation"
}

test_spawn_lifecycle_claim_covers_endpoint_creation() {
  local rec id ready release endpoint_log out_file pid status out
  id=profile-spawn-claim-z21
  rec=$(make_spawn_case profile-spawn-claim claude "$id")
  read_case_record "$rec"
  ready="$CASE_DIR/endpoint-ready"
  release="$CASE_DIR/endpoint-release"
  endpoint_log="$CASE_DIR/endpoint.log"
  out_file="$CASE_DIR/spawn.out"
  FM_FAKE_ENDPOINT_LOG="$endpoint_log" FM_FAKE_ENDPOINT_READY="$ready" \
    FM_FAKE_ENDPOINT_RELEASE="$release" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    > "$out_file" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ ! -e "$ready" ] || break
    sleep 0.05
  done
  assert_present "$ready" "spawn did not reach the blocked endpoint creation"
  assert_present "$HOME_DIR/state/$id.spawning" \
    "spawn did not retain durable ownership during endpoint creation"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "spawn published metadata before endpoint creation completed"
  : > "$release"
  status=0
  wait "$pid" || status=$?
  expect_code 0 "$status" "spawn lifecycle claim release"
  assert_present "$HOME_DIR/state/$id.meta" "spawn did not atomically publish lifecycle metadata"
  assert_absent "$HOME_DIR/state/$id.spawning" "spawn did not release ownership after metadata publication"

  id=profile-done-first-z22
  rec=$(make_spawn_case profile-done-first claude "$id")
  read_case_record "$rec"
  printf '## In flight\n\n## Queued\n\n## Done\n\n- [x] %s - completed task\n' "$id" \
    > "$HOME_DIR/data/backlog.md"
  endpoint_log="$CASE_DIR/endpoint.log"
  status=0
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn after backlog completion"
  assert_contains "$out" "not a canonical In flight backlog record" \
    "spawn did not reject a task completed before lifecycle ownership"
  assert_absent "$endpoint_log" "spawn created an endpoint after backlog completion won the lock"
  assert_absent "$HOME_DIR/state/$id.spawning" "Done-first refusal retained spawn ownership"

  id=profile-missing-backlog-z22a
  rec=$(make_spawn_case profile-missing-backlog claude "$id")
  read_case_record "$rec"
  rm -f "$HOME_DIR/data/backlog.md"
  status=0
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn without durable backlog accounting"
  assert_contains "$out" "not a canonical In flight backlog record" \
    "spawn accepted a missing durable backlog program"
  assert_absent "$HOME_DIR/state/$id.spawning" "missing backlog refusal retained spawn ownership"

  id=profile-duplicate-backlog-z22aa
  rec=$(make_spawn_case profile-duplicate-backlog claude "$id")
  read_case_record "$rec"
  printf -- '- [ ] %s - duplicate task\n' "$id" >> "$HOME_DIR/data/backlog.md"
  status=0
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn with duplicate backlog accounting"
  assert_contains "$out" "not a canonical In flight backlog record" \
    "spawn accepted duplicate durable backlog records"
  assert_absent "$HOME_DIR/state/$id.spawning" "duplicate backlog refusal retained spawn ownership"

  id=profile-final-cleanup-z22b
  rec=$(make_spawn_case profile-final-cleanup claude "$id")
  read_case_record "$rec"
  : > "$HOME_DIR/state/$id.teardown-final-cleanup"
  endpoint_log="$CASE_DIR/endpoint.log"
  status=0
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn during partial final lifecycle cleanup"
  assert_contains "$out" "unresolved owned lifecycle state" \
    "spawn did not reject existing final cleanup authority"
  assert_absent "$endpoint_log" "spawn created an endpoint during partial final lifecycle cleanup"

  id=profile-endpoint-fail-z23
  rec=$(make_spawn_case profile-endpoint-fail claude "$id")
  read_case_record "$rec"
  status=0
  out=$(FM_FAKE_ENDPOINT_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "endpoint creation failure"
  assert_absent "$HOME_DIR/state/$id.spawning" \
    "clean endpoint creation failure retained unrecoverable lifecycle ownership"
  assert_absent "$HOME_DIR/state/$id.meta" "failed endpoint creation published lifecycle metadata"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id" "clean endpoint failure could not be retried"

  id=profile-endpoint-unknown-z24
  rec=$(make_spawn_case profile-endpoint-unknown claude "$id")
  read_case_record "$rec"
  status=0
  out=$(FM_FAKE_ENDPOINT_FAIL=1 FM_FAKE_INVENTORY_UNKNOWN=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "endpoint creation failure with unknown rollback state"
  assert_absent "$HOME_DIR/state/$id.spawning" \
    "failed endpoint command retained lifecycle ownership without an endpoint identity"
  assert_absent "$HOME_DIR/state/$id.meta" "unknown endpoint rollback published lifecycle metadata"

  id=profile-worktree-recovery-z25
  rec=$(make_spawn_case profile-worktree-recovery pi "$id")
  read_case_record "$rec"
  mkdir "$HOME_DIR/state/$id.pi-ext.ts"
  status=0
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn failure after entering a worktree"
  assert_present "$HOME_DIR/state/$id.spawning" \
    "failed worktree spawn lost its durable lifecycle claim"
  assert_present "$HOME_DIR/state/$id.meta" \
    "failed worktree spawn did not publish teardown-recoverable metadata"
  assert_grep "window=@1" "$HOME_DIR/state/$id.meta" \
    "recovery metadata did not retain the exact tmux window id"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "recovery metadata did not retain the observed worktree"
  pass "spawn lifecycle ownership covers endpoint creation and Done-first ordering"
}

test_spawn_waits_for_durable_backlog_mutation_owner() {
  local rec id endpoint_log out status worker identity owner claim
  id=profile-mutation-owner-z26
  rec=$(make_spawn_case profile-mutation-owner claude "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  sleep 30 &
  worker=$!
  identity=$(LC_ALL=C ps -p "$worker" -o lstart= | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  owner="$HOME_DIR/state/.backlog-mutation-owner"
  mkdir "$owner"
  {
    printf 'version=1\n'
    printf 'pid=%s\n' "$worker"
    printf 'identity=%s\n' "$identity"
    printf 'token=0123456789abcdef0123456789abcdef\n'
  } > "$owner/record"
  status=0
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn during orphaned backlog mutation"
  assert_contains "$out" "durable backlog mutation ownership is live or unreadable" \
    "spawn did not fail closed behind the orphaned backend child"
  assert_absent "$endpoint_log" "spawn created an endpoint while backlog mutation ownership was live"
  assert_absent "$HOME_DIR/state/$id.spawning" "blocked spawn created lifecycle authority"
  kill -TERM "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  claim="$HOME_DIR/state/.backlog-receipts.claimed.interrupted"
  mkdir "$claim"
  printf 'synthetic snapshot\n' > "$claim/snapshot-before"
  status=0
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR") || status=$?
  expect_code 1 "$status" "spawn with interrupted backlog receipt claim"
  assert_contains "$out" "interrupted backlog receipt claims" \
    "spawn did not fail closed behind the unreconciled receipt claim"
  assert_absent "$endpoint_log" "spawn created an endpoint while a receipt claim was unresolved"
  rm -f "$claim/snapshot-before"
  rmdir "$claim"
  out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  assert_contains "$out" "spawned $id" "spawn did not reconcile the dead durable mutation owner"
  assert_absent "$owner" "dead durable mutation owner was not reconciled"
  pass "spawn admission shares durable backlog mutation ownership recovery"
}

test_no_profile_keeps_claude_launch_unchanged
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
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
test_secondmate_recovery_refuses_symlinked_metadata
test_spawn_invalidates_all_same_id_completion_receipts_before_endpoint
test_spawn_lifecycle_claim_covers_endpoint_creation
test_spawn_waits_for_durable_backlog_mutation_owner

echo "# all fm-spawn-dispatch-profile tests passed"
