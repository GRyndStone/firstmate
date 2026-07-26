#!/usr/bin/env bash
# Behavior tests for Grok/Antigravity harness hooks, detection, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
fm_test_tmproot TMP_ROOT fm-grok-harness

# Harness detection fixtures must own every marker that can outrank the case
# under test. Without this boundary, running the suite from Claude Code makes an
# agy fixture read as claude before the fixture's own marker is considered.
run_harness_fixture() {
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u ANTIGRAVITY_AGENT "$@"
}

make_spawn_fakebin() {
  local dir=$1 fakebin holder_file="$1/holder"
  fakebin=$(fm_fakebin "$dir")
cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for a in "\$@"; do case "\$a" in *"treehouse get --lease --lease-holder "*)
      fake_root=\$(cd "\$(dirname "\$0")/.." && pwd)
      holder=\$(printf '%s\\n' "\$a" | sed -n "s/.*treehouse get --lease --lease-holder '\\([^']*\\)'.*/\\1/p")
      if [ -n "\$holder" ]; then
        rm -f "\$fake_root/returned"
        printf '%s\\n' "\$holder" > "$holder_file"
      fi
    ;; esac; done
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  status)
    fake_root=\$(cd "\$(dirname "\$0")/.." && pwd)
    returned_file="\$fake_root/returned"
    if [ -f "\$returned_file" ]; then
      printf '1  available  %s\\n' "\${FM_FAKE_PANE_PATH:-}"
      exit 0
    fi
    holder=
    [ ! -f "$holder_file" ] || holder=\$(cat "$holder_file")
    [ -n "\$holder" ] || exit 1
    printf '1  leased  %s  (held by %s)\\n' "\${FM_FAKE_PANE_PATH:-}" "\$holder"
    exit 0 ;;
  get) printf '%s\\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  return)
    fake_root=\$(cd "\$(dirname "\$0")/.." && pwd)
    [ "\${2:-}" = --force ] && : > "\$fake_root/returned"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$grok_home"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_write_criteria "$home/data" "$id"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf -- '- %s [direct-PR] - explicit reference fixture\n' \
    "$(basename "$proj")" > "$home/data/projects.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" grok 2>&1
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_fm_harness_detects_agy_env_and_process() {
  local fakebin out
  out=$(run_harness_fixture ANTIGRAVITY_AGENT=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "ANTIGRAVITY_AGENT=1 should detect agy, got: $out"

  fakebin=$(fm_fakebin "$TMP_ROOT/agy-detect-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/cal/.local/bin/agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy --prompt-interactive brief'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(run_harness_fixture PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "agy process ancestry should detect agy, got: $out"
  pass "fm-harness detects agy through the live env marker and process ancestry"
}

test_fm_harness_detection_fixtures_are_isolated() {
  local fakebin out expected marker

  # Env-marker siblings have the same latent hazard as agy: a higher-precedence
  # marker inherited from the harness running the suite can decide the result
  # before the fixture is reached.
  for expected in claude pi grok agy; do
    case "$expected" in
      claude) marker=CLAUDECODE=1 ;;
      pi) marker=PI_CODING_AGENT=true ;;
      grok) marker=GROK_AGENT=1 ;;
      agy) marker=ANTIGRAVITY_AGENT=1 ;;
    esac
    out=$(run_harness_fixture "$marker" "$ROOT/bin/fm-harness.sh")
    [ "$out" = "$expected" ] ||
      fail "$expected env fixture must decide its own result, got: $out"
  done

  # Codex and OpenCode have no verified env marker, so their sibling fixtures
  # exercise process ancestry. The same scrub boundary applies before ancestry.
  fakebin=$(fm_fakebin "$TMP_ROOT/harness-matrix-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/fixture/%s\n' "$FM_FAKE_HARNESS"; exit 0 ;;
  *"args="*) printf '%s fixture\n' "$FM_FAKE_HARNESS"; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  for expected in claude pi grok agy codex opencode; do
    out=$(run_harness_fixture FM_FAKE_HARNESS="$expected" \
      PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
    [ "$out" = "$expected" ] ||
      fail "$expected ancestry fixture must decide its own result, got: $out"
  done
  pass "all harness-detection fixtures scrub competing ambient markers"
}

test_fm_lock_recognizes_agy_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-agy-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-agy-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/cal/.local/bin/agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy --prompt-interactive brief'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize agy as a live holder"
  pass "fm-lock recognizes agy harness processes"
}

test_busy_regex_recognizes_agy_cancel_footer() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s\n' 'esc to cancel' | grep -qiE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "tmux busy regex must match agy's mid-turn footer"
  grep -F "esc to cancel" "$ROOT/bin/fm-watch.sh" >/dev/null \
    || fail "watcher busy regex must include agy's mid-turn footer"
  pass "busy regex recognizes agy's esc-to-cancel footer"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_fm_lock_recognizes_grok_holder
test_fm_harness_detects_agy_env_and_process
test_fm_harness_detection_fixtures_are_isolated
test_fm_lock_recognizes_agy_holder
test_busy_regex_recognizes_agy_cancel_footer
