#!/usr/bin/env bash
# tests/fm-backlog-handoff.test.sh - full item-block handoff (header + indented body).
#
# The happy single-line path and safety refusals live in the secondmate lifecycle
# and safety suites. This file owns the multi-line body contract: the full block
# moves byte-exact, nothing orphans in the source, and re-running is a no-op.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

# The move is delegated to `tasks-axi mv`, so this suite exercises the real
# binary. Skip cleanly when it is absent (matching the backend smoke suites).
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated handoff path)"; exit 0; }
REAL_TASKS_AXI=$(command -v tasks-axi)
export REAL_TASKS_AXI

TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff)

setup_homes() {
  local home=$1 subhome=$2 id=${3:-design}
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" "$id"
  local sub_abs
  sub_abs=$(cd "$subhome" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
  for tasks_home in "$home" "$subhome"; do
    mkdir -p "$tasks_home/data" "$tasks_home/state"
    cat > "$tasks_home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  done
}

# Exact multi-line block extract: header matching key plus following body lines
# (indented lines and blank separators between paragraphs), stopping at the next
# item header or unindented section heading (column-0 ##).
extract_item_block() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { print; capturing = 1; next }
      next
    }
    capturing && /^## / { exit }
    capturing && /^- \[[ x]\] / { exit }
    capturing && /^([ \t].*)?$/ { print; next }
    capturing { exit }
  ' "$file"
}

assert_block_equals() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" != "$actual" ]; then
    printf 'expected block:\n%s\nactual block:\n%s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

test_body_moves_when_followed_by_another_item() {
  local home="$TMP_ROOT/body-next-item-main"
  local sub="$TMP_ROOT/body-next-item-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] keep-a - stays first (repo: alpha)
  keep-a body line
- [ ] body-item - has a body (repo: alpha)
  Spec detail one.
  ## Intent
  Move the full block.
  trailing body line
- [ ] keep-b - stays after (repo: beta)
  keep-b body stays

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" body-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design body-item >/dev/null \
    || fail "handoff of body-followed-by-item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" body-item)
  assert_block_equals "destination body block mismatch after item-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'body-item' "$home/data/backlog.md" "body-item header still in source"
  assert_no_grep 'Spec detail one' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'Move the full block' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'trailing body line' "$home/data/backlog.md" "orphaned trailing body stayed in source"
  # Indented heading must move with the item, not be left or treated as a section.
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  assert_grep 'keep-a' "$home/data/backlog.md" "keep-a was wrongly removed"
  assert_grep '  keep-a body line' "$home/data/backlog.md" "keep-a body was disturbed"
  assert_grep 'keep-b' "$home/data/backlog.md" "keep-b was wrongly removed"
  assert_grep '  keep-b body stays' "$home/data/backlog.md" "keep-b body was disturbed"

  # keep-a's body must not have grown the orphaned lines of body-item.
  local keep_a_block
  keep_a_block=$(extract_item_block "$home/data/backlog.md" keep-a)
  assert_block_equals "keep-a block must not absorb orphaned body-item lines" \
    $'- [ ] keep-a - stays first (repo: alpha)\n  keep-a body line' \
    "$keep_a_block"

  pass "body followed by another item moves intact with no source orphans"
}

test_body_moves_when_followed_by_section_heading() {
  local home="$TMP_ROOT/body-section-main"
  local sub="$TMP_ROOT/body-section-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] section-tail - body ends at section (repo: alpha)
  last queued body
  ## Intent
  still body until column-0 section

## Done
- [x] old-task - shipped - local main (merged 2026-07-01)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" section-tail)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design section-tail >/dev/null \
    || fail "handoff of body-followed-by-section failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" section-tail)
  assert_block_equals "destination body block mismatch after section-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'section-tail' "$home/data/backlog.md" "section-tail still in source"
  assert_no_grep 'last queued body' "$home/data/backlog.md" "body orphaned before ## Done"
  assert_no_grep 'still body until' "$home/data/backlog.md" "body after ## Intent orphaned"
  assert_grep 'old-task' "$home/data/backlog.md" "Done section item was disturbed"
  assert_grep '## Done' "$home/data/backlog.md" "Done section heading was disturbed"

  pass "body followed by section heading moves intact; section stays"
}

test_body_moves_when_last_lines_of_file() {
  local home="$TMP_ROOT/body-eof-main"
  local sub="$TMP_ROOT/body-eof-sub"
  setup_homes "$home" "$sub"

  # A source item that ends the file with no trailing newline is a valid shape;
  # printf builds that deliberately. It must move whole, indented ## line
  # included, into the destination the handoff seeds.
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s' '  eof body line two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination format: the moved block lands under ## Queued
  # in the standard three-section scaffold the handoff seeds for a fresh home.
  local expected_destination="$TMP_ROOT/body-eof-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s\n' '  eof body line two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" eof-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design eof-item >/dev/null \
    || fail "handoff of EOF body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" eof-item)
  assert_block_equals "destination body block mismatch for EOF item" \
    "$expected_block" "$dest_block"
  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF item did not land byte-exact under the seeded destination scaffold"

  # Source should have no item residual - only the section heading remains.
  if grep -E 'eof-item|eof body|## Intent' "$home/data/backlog.md" >/dev/null; then
    fail "EOF item left residual header or body lines in source"
  fi
  assert_grep '## Queued' "$home/data/backlog.md" "Queued section heading was lost"

  pass "body as last lines of the file moves intact"
}

test_eof_body_before_seeded_destination_section_keeps_boundary() {
  local home="$TMP_ROOT/body-eof-seeded-main"
  local sub="$TMP_ROOT/body-eof-seeded-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s' '  seeded eof body two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination whitespace: the moved block sits directly
  # under ## Queued with the section separator before the following ## Done, and
  # the EOF body stays a clean line above that heading (its boundary is kept).
  local expected_destination="$TMP_ROOT/body-eof-seeded-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s\n' '  seeded eof body two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design seeded-eof-item >/dev/null \
    || fail "handoff of EOF body into seeded backlog failed"

  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF body did not remain separate from the seeded ## Done heading"

  pass "EOF body before a seeded destination section keeps its boundary"
}

test_untouched_eof_line_preserves_terminator() {
  local home="$TMP_ROOT/untouched-eof-main"
  local sub="$TMP_ROOT/untouched-eof-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] move-item - remove this block (repo: alpha)'
    printf '%s\n' '  move body'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$home/data/backlog.md"
  local expected_source="$TMP_ROOT/untouched-eof-expected.md"
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$expected_source"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design move-item >/dev/null \
    || fail "handoff before untouched EOF preservation check failed"

  cmp -s "$expected_source" "$home/data/backlog.md" \
    || fail "handoff changed an untouched final-record terminator"

  pass "untouched EOF line preserves its original terminator"
}

test_body_handoff_is_idempotent() {
  local home="$TMP_ROOT/body-idem-main"
  local sub="$TMP_ROOT/body-idem-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] neighbor - untouched (repo: alpha)
  neighbor body
- [ ] idem-item - multi-line for re-run (repo: alpha)
  ## Intent
  Idempotent body must not duplicate.
  final note

## Done
EOF

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item >/dev/null \
    || fail "first handoff of body-carrying item failed"

  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")

  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item 2>&1) \
    || fail "idempotent re-run of body-carrying item failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"

  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"

  local count
  count=$(grep -cF -- '- [ ] idem-item - multi-line for re-run (repo: alpha)' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated the item header (count=$count)"
  count=$(grep -cF -- 'Idempotent body must not duplicate.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a body line (count=$count)"
  count=$(grep -cF -- '  ## Intent' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated indented ## Intent (count=$count)"

  assert_grep 'neighbor' "$home/data/backlog.md" "neighbor item was disturbed by re-run"
  assert_grep '  neighbor body' "$home/data/backlog.md" "neighbor body was disturbed by re-run"

  pass "body-carrying handoff is idempotent: re-run changes nothing"
}

test_noncanonical_indented_continuations_refuse_without_changes() {
  local home="$TMP_ROOT/noncanonical-main"
  local sub="$TMP_ROOT/noncanonical-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] malformed-body - must not orphan continuations (repo: alpha)
 one-space continuation
EOF
  printf '\ttab continuation\n' >> "$home/data/backlog.md"
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] untouched-item - remains in the main backlog (repo: beta)
  canonical body
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] resident-item - remains in the secondmate backlog (repo: alpha)
  resident body
EOF

  local source_before="$TMP_ROOT/noncanonical-source-before.md"
  local destination_before="$TMP_ROOT/noncanonical-destination-before.md"
  local out
  cp "$home/data/backlog.md" "$source_before"
  cp "$sub/data/backlog.md" "$destination_before"

  if out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design malformed-body 2>&1); then
    fail "handoff accepted a noncanonical indented continuation"
  fi

  assert_contains "$out" "malformed-body" "refusal did not name the selected item"
  assert_contains "$out" "one-space continuation" "refusal did not name the one-space continuation"
  assert_contains "$out" "tab continuation" "refusal did not name the tab continuation"
  cmp -s "$source_before" "$home/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the main backlog"
  cmp -s "$destination_before" "$sub/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the secondmate backlog"

  pass "noncanonical one-space and tab continuations refuse without changes"
}

test_indented_heading_is_not_section_boundary() {
  # Standalone focus on the tokenizer trap that caused the live incident.
  local home="$TMP_ROOT/intent-trap-main"
  local sub="$TMP_ROOT/intent-trap-sub"
  setup_homes "$home" "$sub" design

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] ha-codex-fast-default-4e - harness default work (repo: firstmate)
  Context for the secondmate.
  ## Intent
  Deliver the full spec, not the title alone.
  ## Acceptance
  - body survives handoff
  - ## headings inside body stay body
- [ ] next-item - after the trap (repo: firstmate)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" ha-codex-fast-default-4e)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design ha-codex-fast-default-4e >/dev/null \
    || fail "handoff of ## Intent body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" ha-codex-fast-default-4e)
  assert_block_equals "tokenizer trap: indented ## lines must move with the item" \
    "$expected_block" "$dest_block"

  # Source must not treat ## Intent / ## Acceptance as new sections that split the file.
  if grep -E 'ha-codex-fast-default-4e|Deliver the full spec|body survives handoff' \
    "$home/data/backlog.md" >/dev/null; then
    fail "tokenizer trap left item fragments in the source backlog"
  fi
  assert_grep 'next-item' "$home/data/backlog.md" "following item was lost after ## Intent body"
  # Exactly one real Queued section; no spurious column-0 ## Intent section invented.
  local heading_count
  heading_count=$(grep -cE '^## ' "$home/data/backlog.md")
  [ "$heading_count" -eq 1 ] || fail "source gained extra column-0 ## headings (count=$heading_count)"
  heading_count=$(grep -cE '^## ' "$sub/data/backlog.md")
  # sub scaffold has In flight / Queued / Done
  [ "$heading_count" -eq 3 ] || fail "destination has unexpected ## section count (count=$heading_count)"

  pass "indented ## Intent / ## Acceptance are body, not section boundaries"
}

test_multi_paragraph_body_with_internal_blanks_moves_whole() {
  # The live re-orphan risk: a blank line inside a multi-paragraph body must not
  # terminate the block and strand the paragraphs after it. Blank lines are body
  # content and move with the item; only the next item header or a column-0
  # section heading ends the block. Includes an indented ## after a blank.
  local home="$TMP_ROOT/multi-para-main"
  local sub="$TMP_ROOT/multi-para-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] before-multi - stays put (repo: alpha)
  before body
- [ ] multi-para - multi-paragraph body (repo: alpha)
  First paragraph line.

  Second paragraph after a blank.
  ## Intent

  Indented heading then blank then more.
  final line
- [ ] after-multi - subsequent item (repo: alpha)
  after body

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" multi-para)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para >/dev/null \
    || fail "handoff of multi-paragraph body failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" multi-para)
  assert_block_equals "multi-paragraph body with internal blanks must move whole" \
    "$expected_block" "$dest_block"

  # Every body line, including the ones after each internal blank, must leave the source.
  assert_no_grep 'multi-para' "$home/data/backlog.md" "multi-para header still in source"
  assert_no_grep 'First paragraph line' "$home/data/backlog.md" "first paragraph orphaned in source"
  assert_no_grep 'Second paragraph after a blank' "$home/data/backlog.md" "post-blank paragraph orphaned in source"
  assert_no_grep 'Indented heading then blank then more' "$home/data/backlog.md" "post-blank body orphaned in source"
  assert_no_grep 'final line' "$home/data/backlog.md" "trailing body orphaned in source"
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"

  # The post-blank paragraphs must actually arrive at the destination.
  assert_grep '  Second paragraph after a blank.' "$sub/data/backlog.md" "post-blank paragraph did not arrive"
  assert_grep '  Indented heading then blank then more.' "$sub/data/backlog.md" "post-blank body did not arrive"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  # Neighbors on both sides stay intact.
  assert_grep 'before-multi' "$home/data/backlog.md" "before-multi was wrongly removed"
  assert_grep '  before body' "$home/data/backlog.md" "before-multi body was disturbed"
  assert_grep 'after-multi' "$home/data/backlog.md" "after-multi was wrongly removed"
  assert_grep '  after body' "$home/data/backlog.md" "after-multi body was disturbed"

  # Idempotent re-run: already present, no duplication, no mutation.
  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")
  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para 2>&1) \
    || fail "idempotent re-run of multi-paragraph body failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"
  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"
  local count
  count=$(grep -cF -- '  Second paragraph after a blank.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a post-blank paragraph (count=$count)"

  pass "multi-paragraph body with internal blank lines moves whole and is idempotent"
}

test_handoff_tasks_axi_is_contained_to_selected_home() {
  local home="$TMP_ROOT/contained-main" sub="$TMP_ROOT/contained-sub"
  local hostile="$TMP_ROOT/contained-hostile" fakebin="$TMP_ROOT/contained-fakebin" log out home_phys sub_phys
  setup_homes "$home" "$sub"
  home_phys=$(cd "$home" && pwd -P)
  sub_phys=$(cd "$sub" && pwd -P)
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] contained-item - stays home scoped (repo: alpha)
EOF
  mkdir -p "$hostile" "$fakebin"
  cat > "$hostile/.tasks.toml" <<'EOF'
backend = "sqlite"

[markdown]
archive = "/tmp/ambient-archive.md"
EOF
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'pwd=%s home=%s args=%s\n' "$PWD" "$HOME" "$*" >> "${FM_HANDOFF_ARGS_LOG:?}"
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$fakebin/tasks-axi"
  log="$home/tasks.log"
  out=$(cd "$hostile" && PATH="$fakebin:$PATH" HOME="$hostile" FM_HOME="$home" FM_HANDOFF_ARGS_LOG="$log" \
    "$ROOT/bin/fm-backlog-handoff.sh" design contained-item 2>&1) || fail "contained handoff failed: $out"
  assert_contains "$(cat "$log")" "pwd=$home_phys home=$home_phys args=mv contained-item --backend markdown --file $home_phys/data/backlog.md --to $sub_phys/data/backlog.md" \
    "handoff tasks-axi mv inherited ambient cwd, HOME, backend, or file"
  assert_not_contains "$(cat "$log")" "$hostile" "ambient handoff configuration reached tasks-axi"
  pass "handoff tasks-axi execution is contained to the selected Firstmate home"
}

test_active_home_data_symlink_escape_is_rejected() {
  local home="$TMP_ROOT/data-symlink-main" sub="$TMP_ROOT/data-symlink-sub"
  local outside="$TMP_ROOT/data-symlink-outside" before out status
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] escaped-item - must remain in source (repo: alpha)
EOF
  mv "$home/data" "$outside"
  ln -s "$outside" "$home/data"
  before=$(cat "$outside/backlog.md")
  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design escaped-item 2>&1) || status=$?
  expect_code 1 "$status" "active data symlink escape"
  assert_contains "$out" "data directory must resolve inside the active home" \
    "active data symlink escape did not fail home containment"
  [ "$before" = "$(cat "$outside/backlog.md")" ] \
    || fail "rejected active data symlink escape changed the external backlog"
  if [ -f "$sub/data/backlog.md" ]; then
    assert_no_grep 'escaped-item' "$sub/data/backlog.md" \
      "rejected active data symlink escape moved work into the secondmate backlog"
  fi
  pass "active home data symlink cannot escape handoff containment"
}

test_handoff_invalidates_interrupted_completion_claims() {
  local home="$TMP_ROOT/receipt-main" sub="$TMP_ROOT/receipt-sub" claim
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] claimed-item - must receive a new lifecycle (repo: alpha)
EOF
  for claim in "$home/state/.claimed-item.teardown-complete.claimed.source" \
    "$sub/state/.claimed-item.teardown-complete.claimed.destination"; do
    mkdir -p "$claim"
    printf 'stale\n' > "$claim/proof"
  done
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design claimed-item >/dev/null \
    || fail "handoff with stale interrupted claims failed"
  assert_absent "$home/state/.claimed-item.teardown-complete.claimed.source" \
    "handoff left the source interrupted completion claim"
  assert_absent "$sub/state/.claimed-item.teardown-complete.claimed.destination" \
    "handoff left the destination interrupted completion claim"
  pass "handoff invalidates interrupted completion claims in both homes"
}

test_handoff_child_owns_both_homes_after_wrapper_death() {
  local home="$TMP_ROOT/owned-mutation-main" sub="$TMP_ROOT/owned-mutation-sub"
  local fakebin marker release wrapper status out main_owner sub_owner main_pid sub_pid i
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] owned-item - durable handoff ownership (repo: alpha)

## Done
EOF
  fakebin="$home/fakebin"
  marker="$home/mutation-started"
  release="$home/mutation-release"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ] || { [ "${1:-}" = update ] && [ "${2:-}" = --help ]; } \
   || { [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; }; then
  exec "${REAL_TASKS_AXI:?}" "$@"
fi
: > "${FM_FAKE_HANDOFF_MARKER:?}"
while [ ! -e "${FM_FAKE_HANDOFF_RELEASE:?}" ]; do sleep 0.05; done
exit 9
SH
  chmod +x "$fakebin/tasks-axi"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_HANDOFF_MARKER="$marker" \
    FM_FAKE_HANDOFF_RELEASE="$release" "$ROOT/bin/fm-backlog-handoff.sh" design owned-item \
    > "$home/handoff.out" 2>&1 &
  wrapper=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$marker" ] || fail "handoff mutation child never passed its durable start gate"
  main_owner="$home/state/.backlog-mutation-owner"
  sub_owner="$sub/state/.backlog-mutation-owner"
  assert_present "$main_owner/record" "handoff did not publish active-home mutation ownership"
  assert_present "$sub_owner/record" "handoff did not publish secondmate-home mutation ownership"
  main_pid=$(sed -n 's/^pid=//p' "$main_owner/record")
  sub_pid=$(sed -n 's/^pid=//p' "$sub_owner/record")
  [ -n "$main_pid" ] && [ "$main_pid" = "$sub_pid" ] \
    || fail "handoff homes did not record one exact backend child identity"
  kill -KILL "$wrapper"
  wait "$wrapper" 2>/dev/null || true
  kill -0 "$main_pid" 2>/dev/null || fail "handoff backend child did not survive wrapper death"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_LOCK_STALE_AFTER=0 \
    FM_FAKE_HANDOFF_MARKER="$marker" FM_FAKE_HANDOFF_RELEASE="$release" \
    "$ROOT/bin/fm-backlog-handoff.sh" design owned-item 2>&1) || status=$?
  expect_code 1 "$status" "handoff while orphaned child owns both homes"
  assert_contains "$out" "durable backlog mutation ownership" \
    "a second handoff did not fail closed behind the live child"
  : > "$release"
  i=0
  while kill -0 "$main_pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  kill -0 "$main_pid" 2>/dev/null && fail "released handoff child did not exit"
  FM_HOME="$home" bash -c '. "$1"; fm_tasks_axi_reconcile_mutation_owner "$2"; fm_tasks_axi_reconcile_mutation_owner "$3"' \
    _ "$ROOT/bin/fm-tasks-axi-lib.sh" "$home/state" "$sub/state" \
    || fail "dead handoff child ownership did not reconcile in both homes"
  pass "handoff mutation ownership survives wrapper death in both locked homes"
}

test_handoff_refuses_interrupted_receipt_transactions_in_either_home() {
  local scope home sub claim_root out status
  for scope in main sub; do
    home="$TMP_ROOT/receipt-transaction-$scope-main"
    sub="$TMP_ROOT/receipt-transaction-$scope-sub"
    setup_homes "$home" "$sub"
    cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] transaction-item - must not race receipt recovery (repo: alpha)

## Done
EOF
    if [ "$scope" = main ]; then claim_root=$home; else claim_root=$sub; fi
    mkdir -p "$claim_root/state/.backlog-receipts.claimed.interrupted"
    printf 'snapshot\n' > "$claim_root/state/.backlog-receipts.claimed.interrupted/before"
    status=0
    out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design transaction-item 2>&1) || status=$?
    expect_code 1 "$status" "$scope-home interrupted receipt transaction"
    assert_contains "$out" "interrupted backlog receipt transaction" \
      "$scope-home receipt transaction did not block handoff"
    assert_grep 'transaction-item' "$home/data/backlog.md" \
      "$scope-home receipt transaction allowed the source item to move"
    if [ -f "$sub/data/backlog.md" ]; then
      assert_no_grep 'transaction-item' "$sub/data/backlog.md" \
        "$scope-home receipt transaction populated the destination"
    fi
  done
  pass "handoff refuses interrupted receipt transactions in both locked homes"
}

test_committed_handoff_preserves_destination_when_owner_cleanup_fails() {
  local home="$TMP_ROOT/committed-cleanup-main" sub="$TMP_ROOT/committed-cleanup-sub"
  local fakebin out status
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] committed-item - destination must survive cleanup failure (repo: alpha)

## Done
EOF
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf 'stale\n' > "$home/state/committed-item.teardown-complete"
  printf 'stale\n' > "$sub/state/committed-item.teardown-complete"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ] || { [ "${1:-}" = update ] && [ "${2:-}" = --help ]; } \
   || { [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; }; then
  exec "${REAL_TASKS_AXI:?}" "$@"
fi
"${REAL_TASKS_AXI:?}" "$@"
status=$?
chmod 500 "${FM_MAIN_OWNER:?}" "${FM_SUB_OWNER:?}"
exit "$status"
SH
  chmod +x "$fakebin/tasks-axi"
  status=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_MAIN_OWNER="$home/state/.backlog-mutation-owner" \
    FM_SUB_OWNER="$sub/state/.backlog-mutation-owner" \
    "$ROOT/bin/fm-backlog-handoff.sh" design committed-item 2>&1) || status=$?
  chmod 700 "$home/state/.backlog-mutation-owner" "$sub/state/.backlog-mutation-owner" 2>/dev/null || true
  expect_code 1 "$status" "committed handoff owner cleanup failure"
  assert_contains "$out" "handoff committed" "committed cleanup failure was reported as an uncommitted move"
  assert_no_grep 'committed-item' "$home/data/backlog.md" "committed move remained in the source backlog"
  assert_grep 'committed-item' "$sub/data/backlog.md" "committed destination backlog was deleted"
  assert_absent "$home/state/committed-item.teardown-complete" \
    "committed cleanup failure retained the source lifecycle receipt"
  assert_absent "$sub/state/committed-item.teardown-complete" \
    "committed cleanup failure retained the destination lifecycle receipt"
  pass "committed handoff preserves its destination across owner cleanup failure"
}

test_idempotent_and_mixed_handoffs_reconcile_all_completion_receipts() {
  local home="$TMP_ROOT/receipt-reconcile-main" sub="$TMP_ROOT/receipt-reconcile-sub" state key out
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] newly-moved - committed alongside an already-present item (repo: alpha)

## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] already-there - prior committed move needs receipt cleanup (repo: alpha)

## Done
EOF
  for state in "$home/state" "$sub/state"; do
    printf 'stale\n' > "$state/already-there.teardown-complete"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design already-there 2>&1) \
    || fail "all-ALREADY receipt reconciliation failed: $out"
  assert_contains "$out" "already present" "idempotent receipt reconciliation lost existing reporting"
  for state in "$home/state" "$sub/state"; do
    assert_absent "$state/already-there.teardown-complete" \
      "all-ALREADY retry retained a completion receipt in $state"
  done
  for state in "$home/state" "$sub/state"; do
    for key in newly-moved already-there; do
      printf 'stale\n' > "$state/$key.teardown-complete"
    done
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design newly-moved already-there 2>&1) \
    || fail "mixed committed receipt reconciliation failed: $out"
  assert_grep 'newly-moved' "$sub/data/backlog.md" "mixed handoff did not commit its new item"
  for state in "$home/state" "$sub/state"; do
    for key in newly-moved already-there; do
      assert_absent "$state/$key.teardown-complete" \
        "mixed committed handoff retained $key completion receipt in $state"
    done
  done
  pass "idempotent and mixed committed handoffs reconcile every requested receipt in both homes"
}

test_handoff_refuses_current_lifecycle_before_receipt_cleanup_or_move() {
  local home sub before_main before_sub out status
  home="$TMP_ROOT/current-lifecycle-main"
  sub="$TMP_ROOT/current-lifecycle-sub"
  setup_homes "$home" "$sub"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] newly-moved - must remain queued while another requested key is finalizing (repo: alpha)

## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] already-there - lifecycle-owned destination item (repo: alpha)

## Done
EOF
  printf 'current-proof\n' > "$sub/state/already-there.teardown-complete"
  printf 'version=1\nphase=backlog-done-started\n' > "$sub/state/already-there.teardown-stage"
  before_main=$(cksum "$home/data/backlog.md")
  before_sub=$(cksum "$sub/data/backlog.md")
  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design already-there 2>&1) || status=$?
  expect_code 1 "$status" "idempotent handoff with current lifecycle state"
  assert_contains "$out" "current lifecycle state for already-there" \
    "idempotent handoff did not explain its lifecycle refusal"
  assert_present "$sub/state/already-there.teardown-complete" \
    "idempotent lifecycle refusal deleted the live completion proof"
  assert_present "$sub/state/already-there.teardown-stage" \
    "idempotent lifecycle refusal deleted the live teardown stage"
  [ "$(cksum "$home/data/backlog.md")" = "$before_main" ] \
    || fail "idempotent lifecycle refusal changed the source backlog"
  [ "$(cksum "$sub/data/backlog.md")" = "$before_sub" ] \
    || fail "idempotent lifecycle refusal changed the destination backlog"
  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design newly-moved already-there 2>&1) || status=$?
  expect_code 1 "$status" "mixed handoff with current lifecycle state"
  assert_contains "$out" "current lifecycle state for already-there" \
    "mixed handoff did not refuse before its move"
  assert_present "$sub/state/already-there.teardown-complete" \
    "mixed lifecycle refusal deleted the live completion proof"
  [ "$(cksum "$home/data/backlog.md")" = "$before_main" ] \
    || fail "mixed lifecycle refusal moved the queued source item"
  [ "$(cksum "$sub/data/backlog.md")" = "$before_sub" ] \
    || fail "mixed lifecycle refusal changed the destination backlog"
  pass "handoffs preserve current lifecycle proof and backlog state before idempotent or mixed work"
}

test_handoff_refuses_symlinked_active_state_before_locking() {
  local home sub outside out status
  home="$TMP_ROOT/symlinked-active-state-main"
  sub="$TMP_ROOT/symlinked-active-state-sub"
  setup_homes "$home" "$sub"
  outside="$TMP_ROOT/symlinked-active-state-outside"
  mkdir -p "$outside"
  rm -rf "$home/state"
  ln -s "$outside" "$home/state"
  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design body-item 2>&1) || status=$?
  expect_code 1 "$status" "handoff with symlinked active state"
  assert_contains "$out" "symlinked effective state path component refused" \
    "handoff did not reject foreign active state before locking"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "handoff mutated foreign active state before validation"
  pass "handoff validates active state before locks and receipt mutation"
}

test_body_moves_when_followed_by_another_item
test_body_moves_when_followed_by_section_heading
test_multi_paragraph_body_with_internal_blanks_moves_whole
test_body_moves_when_last_lines_of_file
test_eof_body_before_seeded_destination_section_keeps_boundary
test_untouched_eof_line_preserves_terminator
test_body_handoff_is_idempotent
test_noncanonical_indented_continuations_refuse_without_changes
test_indented_heading_is_not_section_boundary
test_handoff_tasks_axi_is_contained_to_selected_home
test_active_home_data_symlink_escape_is_rejected
test_handoff_invalidates_interrupted_completion_claims
test_handoff_child_owns_both_homes_after_wrapper_death
test_handoff_refuses_interrupted_receipt_transactions_in_either_home
test_committed_handoff_preserves_destination_when_owner_cleanup_fails
test_idempotent_and_mixed_handoffs_reconcile_all_completion_receipts
test_handoff_refuses_current_lifecycle_before_receipt_cleanup_or_move
test_handoff_refuses_symlinked_active_state_before_locking

echo "ALL TESTS PASSED"
