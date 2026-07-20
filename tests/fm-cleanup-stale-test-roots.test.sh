#!/usr/bin/env bash
set -u

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
  for tool in dirname find id date awk stat du basename ps; do
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

test_descendant_handles_refuse_candidate
test_missing_lsof_refuses_candidate
test_clear_recursive_probe_allows_candidate
