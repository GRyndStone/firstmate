#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot TMP_ROOT fm-cleanup-stale-test-roots

make_candidate() {
  local name=$1 path
  path="$TMP_ROOT/$name"
  mkdir -p "$path/nested"
  : > "$path/nested/open-file"
  cd "$path" && pwd -P
}

make_lsof_fake() {
  local dir=$1 fb
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_LSOF_LOG:?}"
case "${FM_LSOF_MODE:?}" in
  descendant)
    case " $* " in
      *" +D "*) printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nsleep 1 user cwd DIR 1,1 0 1 %s/nested\n' "${*: -1}"; exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  clear) exit 1 ;;
esac
SH
  chmod +x "$fb/lsof"
  printf '%s\n' "$fb"
}

test_mount_entries_and_probe_failures_refuse_candidate() {
  local candidate fb log out real_find recursive_log tools tool
  candidate=$(make_candidate fm-secondmate-safety.mounted)
  mkdir -p "$candidate/empty-mount"
  fb=$(make_lsof_fake "$TMP_ROOT/mount-fake")
  log="$TMP_ROOT/mount-lsof.log"; : > "$log"
  real_find=$(command -v find)
  cat > "$fb/mount" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'same-device on $candidate (bind, local)'
EOF
  chmod +x "$fb/mount"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "candidate root mount was not refused"

  cat > "$fb/mount" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'same-device on $candidate/empty-mount (bind, local)'
EOF
  chmod +x "$fb/mount"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "same-device bind mount was not refused"
  assert_present "$candidate" "dry-run removed a mount-containing candidate"

  recursive_log="$TMP_ROOT/recursive-find.log"
  cat > "$fb/find" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -maxdepth ]; then
    exec "${FM_REAL_FIND:?}" "$@"
  fi
done
printf 'recursive\n' >> "${FM_RECURSIVE_FIND_LOG:?}"
exit 72
SH
  chmod +x "$fb/find"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    FM_REAL_FIND="$real_find" FM_RECURSIVE_FIND_LOG="$recursive_log" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "mount-table refusal was lost"
  assert_absent "$recursive_log" "recursive device walk ran before the mount-table refusal"

  cat > "$fb/mount" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/mount"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    FM_REAL_FIND="$real_find" FM_RECURSIVE_FIND_LOG="$recursive_log" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "failed mount probe did not fail closed"
  assert_present "$candidate" "failed mount probe removed its candidate"

  cat > "$fb/mount" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'rootfs on / (local)'
SH
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    FM_REAL_FIND="$real_find" FM_RECURSIVE_FIND_LOG="$recursive_log" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "failed recursive find did not fail closed"

  tools="$TMP_ROOT/no-mount-bin"
  mkdir -p "$tools"
  for tool in dirname find id date awk basename; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  out=$(PATH="$tools" /bin/bash "$ROOT/bin/fm-cleanup-stale-test-roots.sh" \
    --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "cross-device-or-mount-descendant" "missing mount probe did not fail closed"
  pass "cleanup helper: mount entries and probe failures refuse candidates"
}

test_dry_run_and_explicit_apply_modes() {
  local candidate refused fb log out status
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  fb=$(make_lsof_fake "$TMP_ROOT/apply-modes-fake")
  log="$TMP_ROOT/apply-modes-lsof.log"; : > "$log"
  candidate=$(make_candidate fm-secondmate-safety.default-dry)
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "action: dry-run (no deletions performed)" "default mode was not dry-run"
  assert_present "$candidate" "default dry-run deleted an eligible candidate"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 --apply)
  assert_absent "$candidate" "explicit --apply did not delete its eligible candidate"

  candidate=$(make_candidate fm-secondmate-safety.apply-eligible)
  refused=$(make_candidate fm-secondmate-safety.refused-fresh)
  touch -t 209901010000 "$refused/nested/open-file"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 --apply 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "--apply must refuse the whole run when any candidate is refused"
  assert_present "$candidate" "refused --apply deleted an otherwise eligible candidate"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 --apply-eligible)
  assert_absent "$candidate" "explicit --apply-eligible did not delete the eligible set"
  assert_present "$refused" "--apply-eligible deleted a refused candidate"
  pass "cleanup helper: only explicit apply modes delete eligible candidates"
}

test_owner_and_resolved_path_checks_fail_closed() {
  local candidate fb log out status real_stat base outside nested real_find
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.wrong-owner)
  fb=$(make_lsof_fake "$TMP_ROOT/owner-fake")
  log="$TMP_ROOT/owner-lsof.log"; : > "$log"
  real_stat=$(command -v stat)
  cat > "$fb/stat" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  '-c %u'|'-f %u') printf '%s\n' "${FM_OTHER_UID:?}"; exit 0 ;;
esac
exec "${FM_REAL_STAT:?}" "$@"
SH
  chmod +x "$fb/stat"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    FM_REAL_STAT="$real_stat" FM_OTHER_UID=4294967294 \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 --apply 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "owner mismatch must refuse --apply"
  assert_contains "$out" "owner-uid-4294967294-ne-" "owner mismatch refusal lost its reason"
  assert_present "$candidate" "owner mismatch deleted its candidate"

  base="$TMP_ROOT/escape-base"; outside="$TMP_ROOT/escape-outside"
  mkdir -p "$base/fm-secondmate-safety.escape" "$outside"
  : > "$outside/sentinel"
  candidate="$base/fm-secondmate-safety.escape"
  fb="$TMP_ROOT/escape-fake/fakebin"; mkdir -p "$fb"
  real_find=$(command -v find)
  cat > "$fb/find" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -maxdepth ]; then
    printf '%s\0' "${FM_ESCAPE_CANDIDATE:?}"
    /bin/rm -rf "$FM_ESCAPE_CANDIDATE"
    /bin/ln -s "${FM_ESCAPE_OUTSIDE:?}" "$FM_ESCAPE_CANDIDATE"
    exit 0
  fi
done
exec "${FM_REAL_FIND:?}" "$@"
SH
  chmod +x "$fb/find"
  out=$(PATH="$fb:$PATH" FM_ESCAPE_CANDIDATE="$candidate" FM_ESCAPE_OUTSIDE="$outside" FM_REAL_FIND="$real_find" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$base" --min-age-hours 0 --apply 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "resolved path escape must refuse --apply"
  assert_contains "$out" "escaped-base-via-symlink-or-resolve" "resolved path escape refusal lost its reason"
  assert_present "$outside/sentinel" "resolved path escape deleted outside content"

  base="$TMP_ROOT/nested-base"
  candidate="$base/fm-secondmate-safety.escape"
  nested="$base/unrelated/fm-secondmate-safety.target"
  mkdir -p "$candidate" "$nested"
  : > "$nested/sentinel"
  out=$(PATH="$fb:$PATH" FM_ESCAPE_CANDIDATE="$candidate" FM_ESCAPE_OUTSIDE="$nested" FM_REAL_FIND="$real_find" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$base" --min-age-hours 0 --apply 2>&1) && status=0 || status=$?
  expect_code 3 "$status" "resolved nested path outside the direct scan scope must refuse --apply"
  assert_contains "$out" "escaped-base-via-symlink-or-resolve" "nested path-scope refusal lost its reason"
  assert_present "$nested/sentinel" "resolved nested target was deleted outside the direct scan scope"
  pass "cleanup helper: owner and resolved path gates fail closed"
}

test_reappearing_path_is_not_deleted_without_recheck() {
  local candidate fb log out status real_find
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.reappears)
  fb=$(make_lsof_fake "$TMP_ROOT/reappears-fake")
  log="$TMP_ROOT/reappears-lsof.log"; : > "$log"
  real_find=$(command -v find)
  cat > "$fb/find" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -delete ]; then
    "${FM_REAL_FIND:?}" "$@" || exit $?
    mkdir -p "${FM_REAPPEAR_PATH:?}"
    : > "$FM_REAPPEAR_PATH/replacement"
    exit 0
  fi
done
exec "${FM_REAL_FIND:?}" "$@"
SH
  chmod +x "$fb/find"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    FM_REAL_FIND="$real_find" FM_REAPPEAR_PATH="$candidate" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 --apply-eligible 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "replacement tree after delete must fail the apply"
  assert_contains "$out" "delete-incomplete:" "replacement tree did not report deletion failure"
  assert_present "$candidate/replacement" "replacement tree was deleted without a fresh safety recheck"
  pass "cleanup helper: a reappearing path is preserved and reported"
}

test_descendant_handles_refuse_candidate() {
  local candidate fb log out
  candidate=$(make_candidate fm-secondmate-safety.descendant)
  fb=$(make_lsof_fake "$TMP_ROOT/descendant-fake")
  log="$TMP_ROOT/descendant-lsof.log"; : > "$log"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=descendant \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "eligible_count: 0" "descendant cwd/open handle was classified eligible"
  assert_contains "$out" "open-files-cwd-root-or-lsof-unavailable" "descendant handle refusal lost its reason"
  assert_contains "$(cat "$log")" "+D $candidate" "lsof did not recursively inspect the candidate"
  pass "cleanup helper: descendant handles refuse eligibility"
}

test_missing_lsof_refuses_candidate() {
  local candidate tools tool out
  candidate=$(make_candidate fm-secondmate-safety.no-lsof)
  tools="$TMP_ROOT/no-lsof-bin"
  mkdir -p "$tools"
  for tool in dirname find id date awk stat du basename ps mount; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  out=$(PATH="$tools" /bin/bash "$ROOT/bin/fm-cleanup-stale-test-roots.sh" \
    --base "$TMP_ROOT" --prefix fm-secondmate-safety --min-age-hours 0)
  assert_contains "$out" "path=$candidate" "missing-lsof candidate disappeared from the inventory"
  assert_contains "$out" "eligible_count: 0" "missing lsof did not fail closed"
  assert_contains "$out" "open-files-cwd-root-or-lsof-unavailable" "missing-lsof refusal lost its reason"
  pass "cleanup helper: missing lsof fails closed"
}

test_clear_recursive_probe_allows_candidate() {
  local candidate fb log out
  rm -rf "$TMP_ROOT/fm-secondmate-safety.descendant" "$TMP_ROOT/fm-secondmate-safety.no-lsof"
  candidate=$(make_candidate fm-secondmate-safety.clear)
  fb=$(make_lsof_fake "$TMP_ROOT/clear-fake")
  log="$TMP_ROOT/clear-lsof.log"; : > "$log"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "path=$candidate" "clear candidate disappeared from the manifest"
  assert_contains "$out" "eligible_count: 1" "clear recursive probe did not allow eligibility"
  pass "cleanup helper: clear recursive probe preserves eligibility"
}

test_apply_rechecks_gates_before_delete() {
  # Apply path must re-run full eligibility immediately before rm, not just
  # basename/existence. Flip the lsof probe after scan so a once-eligible root
  # is refused on the pre-delete recheck (TOCTOU regression for apply-eligibility).
  local candidate fb log out state
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.recheck)
  fb="$TMP_ROOT/recheck-fake/fakebin"
  mkdir -p "$fb"
  state="$TMP_ROOT/recheck-state"
  printf 'clear\n' > "$state"
  log="$TMP_ROOT/recheck-lsof.log"; : > "$log"
  cat > "$fb/lsof" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
mode=\$(cat '$state')
case "\$mode" in
  clear)
    printf 'open\n' > '$state'
    exit 1
    ;;
  *)
    case " \$* " in
      *" +D "*)
        printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
        printf 'sleep 1 user 3r REG 1,1 0 1 %s/nested/open-file\n' "\${*: -1}"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
esac
EOF
  chmod +x "$fb/lsof"
  out=$(PATH="$fb:$PATH" "$ROOT/bin/fm-cleanup-stale-test-roots.sh" \
    --base "$TMP_ROOT" --min-age-hours 0 --apply-eligible)
  assert_contains "$out" "eligible_count: 1" "initial scan should have allowed the candidate"
  assert_contains "$out" "skip-recheck:" "apply did not recheck before delete"
  assert_contains "$out" "open-files-cwd-root-or-lsof-unavailable" "recheck refusal lost its reason"
  assert_present "$candidate" "apply deleted a path that failed the pre-delete recheck"
  pass "cleanup helper: apply rechecks full gates before delete"
}

test_pipe_names_remain_structured() {
  local candidate candidate_q fb log out status
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate 'fm-secondmate-safety.left|middle|right')
  printf -v candidate_q '%q' "$candidate"
  fb=$(make_lsof_fake "$TMP_ROOT/pipe-fake")
  log="$TMP_ROOT/pipe-lsof.log"; : > "$log"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=descendant \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "pipe-containing candidate must not corrupt classification"
  assert_contains "$out" "path=$candidate_q" "pipe-containing candidate was split in the refusal record"
  assert_contains "$out" "refused_count: 1" "pipe-containing candidate was not refused exactly once"
  pass "cleanup helper: candidate paths are carried as structured values"
}

test_large_ps_match_refuses_candidate() {
  local candidate fb out
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.large-ps)
  fb="$TMP_ROOT/large-ps-fake/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
printf '424242 sleep %s\n' "${FM_CLEANUP_PROBE_PATH:?}"
i=0
while [ "$i" -lt 50000 ]; do
  printf '500000 unrelated-process-%s padding-padding-padding-padding\n' "$i"
  i=$((i + 1))
done
SH
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fb/ps" "$fb/lsof"
  out=$(PATH="$fb:$PATH" "$ROOT/bin/fm-cleanup-stale-test-roots.sh" \
    --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "path=$candidate" "large-ps candidate disappeared from the inventory"
  assert_contains "$out" "eligible_count: 0" "live reference was lost after a large ps snapshot"
  assert_contains "$out" "live-process-command-or-cwd" "large-ps refusal lost its live-reference reason"
  pass "cleanup helper: live-reference scan consumes a large ps snapshot"
}

test_descendant_freshness_refuses_candidate() {
  local candidate fb log out
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.fresh-descendant)
  touch -t 209901010000 "$candidate/nested/open-file"
  fb=$(make_lsof_fake "$TMP_ROOT/fresh-descendant-fake")
  log="$TMP_ROOT/fresh-descendant-lsof.log"; : > "$log"
  out=$(PATH="$fb:$PATH" FM_LSOF_LOG="$log" FM_LSOF_MODE=clear \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" --min-age-hours 0)
  assert_contains "$out" "path=$candidate" "fresh-descendant candidate disappeared from the inventory"
  assert_contains "$out" "eligible_count: 0" "fresh descendant did not refuse the candidate"
  assert_contains "$out" "mtime-too-fresh" "fresh descendant refusal lost its freshness reason"
  pass "cleanup helper: newest descendant activity controls freshness"
}

test_recheck_observes_descendant_rewrite() {
  local candidate fb state out status
  rm -rf "$TMP_ROOT"/fm-secondmate-safety.*
  candidate=$(make_candidate fm-secondmate-safety.rewrite-recheck)
  fb="$TMP_ROOT/rewrite-recheck-fake/fakebin"
  mkdir -p "$fb"
  state="$TMP_ROOT/rewrite-recheck-state"
  printf 'initial\n' > "$state"
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "${FM_REWRITE_STATE:?}")" = initial ]; then
  touch -t 209901010000 "${FM_REWRITE_PATH:?}"
  printf 'rewritten\n' > "$FM_REWRITE_STATE"
fi
exit 1
SH
  chmod +x "$fb/lsof"
  out=$(PATH="$fb:$PATH" FM_REWRITE_STATE="$state" \
    FM_REWRITE_PATH="$candidate/nested/open-file" \
    "$ROOT/bin/fm-cleanup-stale-test-roots.sh" --base "$TMP_ROOT" \
    --min-age-hours 0 --apply-eligible 2>&1) && status=0 || status=$?
  expect_code 4 "$status" "fresh descendant on recheck must refuse deletion"
  assert_contains "$out" "eligible_count: 1" "candidate should pass before the descendant rewrite"
  assert_contains "$out" "skip-recheck: reason=mtime-too-fresh" "recheck missed the descendant rewrite"
  assert_present "$candidate" "recheck deleted a candidate with a freshly rewritten descendant"
  pass "cleanup helper: pre-delete recheck includes descendant freshness"
}

test_descendant_handles_refuse_candidate
test_missing_lsof_refuses_candidate
test_clear_recursive_probe_allows_candidate
test_mount_entries_and_probe_failures_refuse_candidate
test_dry_run_and_explicit_apply_modes
test_owner_and_resolved_path_checks_fail_closed
test_reappearing_path_is_not_deleted_without_recheck
test_apply_rechecks_gates_before_delete
test_pipe_names_remain_structured
test_large_ps_match_refuses_candidate
test_descendant_freshness_refuses_candidate
test_recheck_observes_descendant_rewrite
