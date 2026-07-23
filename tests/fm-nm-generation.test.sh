#!/usr/bin/env bash
# Behavior tests for task-pinned no-mistakes generation routing.
#
# Covers: absent-config compatibility, exact env/meta pinning, invalid config
# rejection, old/new generation coexistence, recovery continuity, and the
# absence of implicit harness-parity NO_MISTAKES_RUN_AGENTS export.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
# shellcheck source=bin/fm-nm-generation-lib.sh disable=SC1091
. "$ROOT/bin/fm-nm-generation-lib.sh"

fm_test_tmproot TMP_ROOT fm-nm-generation

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
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Install a fake generation binary under <root>/bin/no-mistakes that is healthy
# by default (daemon status reports running). Optional second arg: unhealthy.
make_fake_generation() {
  local root=$1 mode=${2:-healthy} bin
  mkdir -p "$root/bin" "$root/home"
  bin="$root/bin/no-mistakes"
  cat > "$bin" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --version) echo "no-mistakes version fake-gen (\$(basename "$root"))"; exit 0 ;;
  daemon)
    if [ "\${2:-}" = status ]; then
      if [ "${mode}" = healthy ]; then
        echo "  ● daemon running (pid 1)"
        exit 0
      fi
      echo "  ○ daemon not running"
      exit 1
    fi
    ;;
esac
exit 0
SH
  chmod +x "$bin"
  printf '%s\n' "$bin"
}

# Register the fixture project basename under the given delivery mode.
# Default (omit) is direct-PR so generation routing stays off unless opted in.
register_project_mode() {
  local home=$1 mode=${2:-direct-PR} proj_name=${3:-project}
  mkdir -p "$home/data"
  printf -- '- %s [%s] - fixture project (added 2026-07-20)\n' "$proj_name" "$mode" \
    > "$home/data/projects.md"
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
  register_project_mode "$home" direct-PR project
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
    fm_write_criteria "$home/data" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  local shelllog="${launchlog%.log}.shell.log"
  : > "$launchlog"
  : > "$shelllog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_SHELL_LOG="$shelllog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

write_generation_config() {
  local home=$1 id=$2 binary=$3 gen_home=$4
  cat > "$home/config/no-mistakes-generation" <<EOF
id=$id
binary=$binary
home=$gen_home
EOF
}

# --- unit: parse / health ---------------------------------------------------

test_absent_config_is_ambient() {
  local cfg
  cfg="$TMP_ROOT/absent/config"
  mkdir -p "$cfg"
  FM_NM_GEN_ID=x FM_NM_GEN_BINARY=y FM_NM_GEN_HOME=z
  fm_nm_generation_resolve_for_spawn "$cfg" "" || fail "absent config should resolve"
  [ -z "$FM_NM_GEN_BINARY" ] || fail "absent config must leave binary empty"
  [ -z "$FM_NM_GEN_HOME" ] || fail "absent config must leave home empty"
  [ -z "$(fm_nm_generation_export_lines)" ] || fail "absent config must emit no exports"
  [ -z "$(fm_nm_generation_meta_lines)" ] || fail "absent config must emit no meta lines"
  pass "absent config keeps ambient no-mistakes routing"
}

test_incomplete_config_fails_closed() {
  local cfg
  cfg="$TMP_ROOT/incomplete/config"
  mkdir -p "$cfg"
  printf 'id=only\n' > "$cfg/no-mistakes-generation"
  if fm_nm_generation_resolve_for_spawn "$cfg" ""; then
    fail "incomplete config should fail closed"
  fi
  assert_contains "$FM_NM_GEN_ERR" "incomplete" "incomplete config diagnostic missing"
  pass "incomplete config fails closed with diagnostic"
}

test_relative_paths_fail_closed() {
  local cfg
  cfg="$TMP_ROOT/relative/config"
  mkdir -p "$cfg"
  cat > "$cfg/no-mistakes-generation" <<'EOF'
id=rel
binary=relative/bin/no-mistakes
home=relative/home
EOF
  if fm_nm_generation_resolve_for_spawn "$cfg" ""; then
    fail "relative paths should fail closed"
  fi
  assert_contains "$FM_NM_GEN_ERR" "absolute path" "relative path diagnostic missing"
  pass "relative paths fail closed"
}

test_unhealthy_daemon_fails_closed() {
  local root bin gen_home cfg
  root="$TMP_ROOT/unhealthy-gen"
  bin=$(make_fake_generation "$root" unhealthy)
  gen_home="$root/home"
  cfg="$TMP_ROOT/unhealthy/config"
  mkdir -p "$cfg"
  cat > "$cfg/no-mistakes-generation" <<EOF
id=sick
binary=$bin
home=$gen_home
EOF
  if fm_nm_generation_resolve_for_spawn "$cfg" ""; then
    fail "unhealthy generation should fail closed"
  fi
  assert_contains "$FM_NM_GEN_ERR" "unhealthy" "unhealthy diagnostic missing"
  pass "unhealthy generation fails closed without ambient fallback"
}

# --- spawn integration ------------------------------------------------------

test_spawn_absent_config_no_pin_no_run_agents() {
  local rec id out status shelllog meta
  id=nm-absent-z1
  rec=$(make_spawn_case nm-absent claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn without generation config should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_present "$meta" "meta missing"
  if grep -q '^nm_' "$meta"; then
    fail "absent config must not write nm_* meta keys: $(cat "$meta")"
  fi
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_grep "export GOTMPDIR=" "$shelllog" "GOTMPDIR export missing"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "must not export NO_MISTAKES_RUN_AGENTS from harness: $(cat "$shelllog")"
  fi
  if grep -q 'export NM_HOME=' "$shelllog"; then
    fail "absent config must not export NM_HOME: $(cat "$shelllog")"
  fi
  pass "absent config: no meta pin, no NM_HOME, no harness RUN_AGENTS export"
}

test_spawn_pins_meta_and_env_exactly() {
  local rec id out status shelllog meta root bin gen_home
  id=nm-pin-z2
  rec=$(make_spawn_case nm-pin claude "$id")
  read_case_record "$rec"
  register_project_mode "$HOME_DIR" no-mistakes project
  root="$CASE_DIR/gen-green"
  bin=$(make_fake_generation "$root" healthy)
  gen_home="$root/home"
  write_generation_config "$HOME_DIR" green-fixture "$bin" "$gen_home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn with healthy generation should succeed"
  assert_contains "$out" "nm_generation=green-fixture" "spawn line missing generation id"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "mode=no-mistakes" "$meta" "meta must record explicit no-mistakes mode"
  assert_grep "nm_generation=green-fixture" "$meta" "meta nm_generation mismatch"
  assert_grep "nm_binary=$bin" "$meta" "meta nm_binary mismatch"
  assert_grep "nm_home=$gen_home" "$meta" "meta nm_home mismatch"
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_grep "export NM_HOME='$gen_home'" "$shelllog" "NM_HOME export mismatch"
  assert_grep "export PATH='$(dirname "$bin")':\"\${PATH}\"" "$shelllog" "PATH export mismatch"
  if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
    fail "must not export NO_MISTAKES_RUN_AGENTS when generation is pinned"
  fi
  pass "spawn snapshots exact generation meta and pane exports"
}

test_direct_pr_ignores_generation_config() {
  local rec id out status shelllog meta root bin gen_home
  id=nm-direct-z8
  rec=$(make_spawn_case nm-direct claude "$id")
  read_case_record "$rec"
  # Keep default direct-PR mode; install a healthy generation config that must
  # not be applied.
  root="$CASE_DIR/gen-ignored"
  bin=$(make_fake_generation "$root" healthy)
  gen_home="$root/home"
  write_generation_config "$HOME_DIR" ignored-gen "$bin" "$gen_home"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "direct-PR spawn must succeed even with generation config present"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "mode=direct-PR" "$meta" "ordinary spawn must record direct-PR mode"
  if grep -q '^nm_' "$meta"; then
    fail "direct-PR must not pin generation meta: $(cat "$meta")"
  fi
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  if grep -q 'export NM_HOME=' "$shelllog"; then
    fail "direct-PR must not export NM_HOME: $(cat "$shelllog")"
  fi
  pass "direct-PR launch ignores no-mistakes generation config"
}

test_direct_pr_ignores_invalid_generation_config() {
  local rec id out status meta
  id=nm-direct-bad-z9
  rec=$(make_spawn_case nm-direct-bad claude "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/no-mistakes-generation" <<'EOF'
id=broken
binary=/no/such/binary
home=/no/such/home
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "invalid generation config must not fail direct-PR spawn"
  meta="$HOME_DIR/state/$id.meta"
  assert_present "$meta" "direct-PR meta should be written"
  assert_grep "mode=direct-PR" "$meta" "mode should stay direct-PR"
  if grep -q '^nm_' "$meta"; then
    fail "direct-PR must not pin nm_* from invalid config: $(cat "$meta")"
  fi
  pass "absent/invalid generation config does not affect direct-PR launches"
}

test_local_only_ignores_generation_config() {
  local rec id meta shelllog root bin gen_home
  id=nm-local-z10
  rec=$(make_spawn_case nm-local claude "$id")
  read_case_record "$rec"
  register_project_mode "$HOME_DIR" local-only project
  root="$CASE_DIR/gen-local"
  bin=$(make_fake_generation "$root" healthy)
  gen_home="$root/home"
  write_generation_config "$HOME_DIR" local-ignored "$bin" "$gen_home"

  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" >/dev/null
  expect_code 0 $? "local-only spawn must succeed with generation config present"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "mode=local-only" "$meta" "local-only mode missing"
  if grep -q '^nm_' "$meta"; then
    fail "local-only must not pin generation: $(cat "$meta")"
  fi
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  if grep -q 'export NM_HOME=' "$shelllog"; then
    fail "local-only must not export NM_HOME"
  fi
  pass "local-only launch ignores no-mistakes generation config"
}

test_spawn_rejects_invalid_generation_config() {
  local rec id out status
  id=nm-bad-z3
  rec=$(make_spawn_case nm-bad claude "$id")
  read_case_record "$rec"
  register_project_mode "$HOME_DIR" no-mistakes project
  cat > "$HOME_DIR/config/no-mistakes-generation" <<'EOF'
id=broken
binary=/no/such/binary
home=/no/such/home
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "invalid generation must fail spawn for no-mistakes mode"
  assert_contains "$out" "no-mistakes generation routing failed" "spawn error missing"
  assert_contains "$out" "refusing ambient fallback" "fail-closed wording missing"
  assert_absent "$HOME_DIR/state/$id.meta" "failed spawn must not write meta"
  pass "invalid generation config fails closed for explicit no-mistakes only"
}

test_old_and_new_generation_coexistence() {
  local rec_a id_a rec_b id_b root_a bin_a home_a root_b bin_b home_b
  local meta_a meta_b shell_a shell_b

  id_a=nm-coexist-old-z4
  rec_a=$(make_spawn_case nm-coexist-a claude "$id_a")
  read_case_record "$rec_a"
  register_project_mode "$HOME_DIR" no-mistakes project
  root_a="$CASE_DIR/gen-old"
  bin_a=$(make_fake_generation "$root_a" healthy)
  home_a="$root_a/home"
  write_generation_config "$HOME_DIR" old-gen "$bin_a" "$home_a"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_a" "$PROJ_DIR" >/dev/null
  expect_code 0 $? "old-gen spawn should succeed"
  meta_a="$HOME_DIR/state/$id_a.meta"
  shell_a="${LAUNCH_LOG%.log}.shell.log"
  assert_grep "nm_generation=old-gen" "$meta_a" "old task pin missing"
  assert_grep "export NM_HOME='$home_a'" "$shell_a" "old task env missing"

  # Flip home config to a different generation; existing meta must stay put when
  # only reading it, and a NEW task must get the new pin.
  id_b=nm-coexist-new-z5
  rec_b=$(make_spawn_case nm-coexist-b codex "$id_b")
  read_case_record "$rec_b"
  register_project_mode "$HOME_DIR" no-mistakes project
  root_b="$CASE_DIR/gen-new"
  bin_b=$(make_fake_generation "$root_b" healthy)
  home_b="$root_b/home"
  write_generation_config "$HOME_DIR" new-gen "$bin_b" "$home_b"
  # Copy the already-pinned old task meta into this home to simulate coexistence
  # of live tasks under one fleet home with a config flip.
  cp "$meta_a" "$HOME_DIR/state/$id_a.meta"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_b" "$PROJ_DIR" >/dev/null
  expect_code 0 $? "new-gen spawn should succeed"
  meta_b="$HOME_DIR/state/$id_b.meta"
  shell_b="${LAUNCH_LOG%.log}.shell.log"
  assert_grep "nm_generation=new-gen" "$meta_b" "new task pin missing"
  assert_grep "export NM_HOME='$home_b'" "$shell_b" "new task env missing"
  # Live old meta was only copied, not rewritten by the new spawn.
  assert_grep "nm_generation=old-gen" "$HOME_DIR/state/$id_a.meta" "config flip rewrote live old meta"
  assert_grep "nm_home=$home_a" "$HOME_DIR/state/$id_a.meta" "old home pin lost"
  pass "old and new generation pins coexist; config flip does not rewrite live meta"
}

test_recovery_preserves_prior_pin_over_config() {
  local rec id out status meta root_old bin_old home_old root_new bin_new home_new shelllog
  id=nm-recover-z6
  rec=$(make_spawn_case nm-recover claude "$id")
  read_case_record "$rec"
  register_project_mode "$HOME_DIR" no-mistakes project
  root_old="$CASE_DIR/gen-prior"
  bin_old=$(make_fake_generation "$root_old" healthy)
  home_old="$root_old/home"
  root_new="$CASE_DIR/gen-later"
  bin_new=$(make_fake_generation "$root_new" healthy)
  home_new="$root_new/home"

  # Seed meta with the prior pin, then point live config at a different generation.
  {
    echo "window=firstmate:fm-$id"
    echo "worktree=$WT_DIR"
    echo "project=$PROJ_DIR"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "nm_generation=prior-gen"
    echo "nm_binary=$bin_old"
    echo "nm_home=$home_old"
  } > "$HOME_DIR/state/$id.meta"
  write_generation_config "$HOME_DIR" later-gen "$bin_new" "$home_new"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "recovery spawn should succeed with prior pin"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "nm_generation=prior-gen" "$meta" "recovery must keep prior generation id"
  assert_grep "nm_binary=$bin_old" "$meta" "recovery must keep prior binary"
  assert_grep "nm_home=$home_old" "$meta" "recovery must keep prior home"
  if grep -q 'later-gen\|'"$bin_new" "$meta"; then
    fail "recovery re-resolved from live config instead of meta pin: $(cat "$meta")"
  fi
  shelllog="${LAUNCH_LOG%.log}.shell.log"
  assert_grep "export NM_HOME='$home_old'" "$shelllog" "recovery must re-export prior NM_HOME"
  pass "recovery continuity reuses task meta pin over live config"
}

test_no_implicit_harness_parity_export_across_harnesses() {
  local rec id shelllog harness
  for harness in claude codex grok; do
    id="nm-parity-$harness-z7"
    rec=$(make_spawn_case "nm-parity-$harness" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "$harness")
    expect_code 0 $? "spawn harness=$harness should succeed without generation config"
    shelllog="${LAUNCH_LOG%.log}.shell.log"
    if grep -q 'NO_MISTAKES_RUN_AGENTS' "$shelllog"; then
      fail "harness=$harness still exports NO_MISTAKES_RUN_AGENTS: $(cat "$shelllog")"
    fi
  done
  pass "no harness derives NO_MISTAKES_RUN_AGENTS export"
}

test_bootstrap_reports_active_generation() {
  local home cfg root bin gen_home out
  home="$TMP_ROOT/boot-home"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  root="$TMP_ROOT/boot-gen"
  bin=$(make_fake_generation "$root" healthy)
  gen_home="$root/home"
  write_generation_config "$home" boot-gen "$bin" "$gen_home"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "NM_GENERATION: active id=boot-gen" "bootstrap active line missing"
  pass "bootstrap reports active no-mistakes generation"
}

test_absent_config_is_ambient
test_incomplete_config_fails_closed
test_relative_paths_fail_closed
test_unhealthy_daemon_fails_closed
test_spawn_absent_config_no_pin_no_run_agents
test_spawn_pins_meta_and_env_exactly
test_direct_pr_ignores_generation_config
test_direct_pr_ignores_invalid_generation_config
test_local_only_ignores_generation_config
test_spawn_rejects_invalid_generation_config
test_old_and_new_generation_coexistence
test_recovery_preserves_prior_pin_over_config
test_no_implicit_harness_parity_export_across_harnesses
test_bootstrap_reports_active_generation
