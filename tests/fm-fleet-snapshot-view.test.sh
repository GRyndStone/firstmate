#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    # Strict-probe inventory (docs/tmux-backend.md "Strict window-existence
    # probe"): every recorded window is live in this suite; deadness is
    # expressed through agent_alive (a zsh pane_current_command), not a gone
    # endpoint.
    for m in "${FM_HOME:-/nonexistent}"/state/*.meta; do
      [ -e "$m" ] || continue
      sed -n 's/^window=//p' "$m"
    done
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) printf '%s\n' PONG ;;
  list-windows) printf '%s\n' '[{"id":"fixture-window"}]' ;;
  workspace) printf '%s\n' '{"workspaces":[]}' ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/cmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1" and .backlog.present == false and (.tasks|length == 0)' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | - | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | - | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_queue_accounting_surfaces_holds_and_durable_program_boundary() {
  local home out view
  home=$(make_home program-boundary)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] dependency - Active Dependency (repo: alpha) (kind: ship)

## Queued
- [ ] held-task - Held Task (repo: alpha) (kind: ship) (hold: captain decision pending) (hold-kind: captain)
- [ ] blocked-task - Blocked Task (repo: alpha) (kind: ship) blocked-by: dependency - waiting for dependency

## Done
EOF
  printf '# Durable program\n\nThis plan still has undecomposed obligations.\n' > "$home/data/alpha-program.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg path "$home/data/alpha-program.md" '
    .queue_accounting.runnable_candidates == 0
      and .queue_accounting.empty_runnable_queue == true
      and .queue_accounting.held == 1
      and .queue_accounting.blocked == 1
      and .queue_accounting.durable_program_source_count == 1
      and .queue_accounting.decomposition_status == "requires_supervisor_judgment"
      and .program_sources == [{path:$path,relative_path:"alpha-program.md"}]
      and (.queue_accounting.supervisor_boundary | contains("does not prove the durable program is complete"))
  ' >/dev/null || fail "queue/program accounting did not distinguish an empty runnable queue from durable obligations: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "Runnable candidates: 0" "view omitted the empty runnable queue"
  assert_contains "$view" "Durable program sources: 1" "view omitted durable program sources"
  assert_contains "$view" "| held-task | Held Task | alpha | ship | captain - captain decision pending |" \
    "view omitted structured held work"
  pass "status reporting distinguishes an empty runnable queue from held work and durable program obligations"
}

test_queue_accounting_uses_active_hold_and_blocker_semantics() {
  local home out view
  home=$(make_home active-queue-gates)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-dependency - Live Dependency (repo: alpha) (kind: ship)

## Queued
- [ ] future-hold - Future Hold (repo: alpha) (kind: ship) (hold: scheduled) (hold-kind: external) (hold-until: 2026-07-18)
- [ ] expired-hold - Expired Hold (repo: alpha) (kind: ship) (hold: scheduled) (hold-kind: external) (hold-until: 2026-07-16)
- [ ] active-blocker - Active Blocker (repo: alpha) (kind: ship) blocked-by: live-dependency - waits on live work
- [ ] resolved-blocker - Resolved Blocker (repo: alpha) (kind: ship) blocked-by: done-dependency - already landed
- [ ] missing-blocker - Missing Blocker (repo: alpha) (kind: ship) blocked-by: removed-dependency - legacy dangling edge
- [ ] prose-hold - Explain (hold: scheduled) in title prose (repo: alpha) (kind: ship)
- [ ] prose-blocker - Explain blocked-by: live-dependency in title prose (repo: alpha) (kind: ship)
- [ ] mixed-blockers - Mixed Blockers (repo: alpha) (kind: ship) blocked-by: done-dependency - already landed blocked-by: live-dependency - waits on live work
- [ ] repeated-hold - Repeated Hold (repo: alpha) (kind: ship) (hold: older value) (hold: rightmost value)
- [ ] embedded-marker - Embedded Marker unblocked-by: live-dependency (repo: alpha) (kind: ship)

## Done
- [x] done-dependency - Done Dependency (repo: alpha) (kind: ship) (done 2026-07-16)
EOF
  out=$(FM_HOME="$home" FM_FLEET_SNAPSHOT_TODAY=2026-07-17 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .queue_accounting.held == 2
      and .queue_accounting.blocked == 3
      and .queue_accounting.runnable_candidates == 5
      and .queue_accounting.empty_runnable_queue == false
      and (.backlog.records[] | select(.id == "future-hold")
           | .hold_until == "2026-07-18" and .active_hold == true and .runnable == false)
      and (.backlog.records[] | select(.id == "expired-hold")
           | .hold == "scheduled" and .active_hold == false and .runnable == true)
      and (.backlog.records[] | select(.id == "active-blocker")
           | .active_blocked_by_ids == ["live-dependency"] and .active_blocked == true and .runnable == false)
      and (.backlog.records[] | select(.id == "resolved-blocker")
           | .blocked_by_ids == ["done-dependency"] and .active_blocked_by_ids == [] and .active_blocked == false and .runnable == true)
      and (.backlog.records[] | select(.id == "missing-blocker")
           | .active_blocked_by_ids == [] and .runnable == true)
      and (.backlog.records[] | select(.id == "prose-hold")
           | .title == "Explain (hold: scheduled) in title prose" and .hold == null and .active_hold == false and .runnable == true)
      and (.backlog.records[] | select(.id == "prose-blocker")
           | .title == "Explain blocked-by: live-dependency in title prose" and .blocked_by_ids == [] and .active_blocked == false and .runnable == true)
      and (.backlog.records[] | select(.id == "mixed-blockers")
           | .blocked_by_ids == ["done-dependency","live-dependency"]
             and .active_blocked_by_ids == ["live-dependency"]
             and .active_blocked_reason == "waits on live work")
      and (.backlog.records[] | select(.id == "repeated-hold")
           | .hold == "rightmost value" and .active_hold == true and .runnable == false)
      and (.backlog.records[] | select(.id == "embedded-marker")
           | .title == "Embedded Marker un" and .blocked_by_ids == ["live-dependency"]
             and .active_blocked_by_ids == ["live-dependency"] and .runnable == false)
  ' >/dev/null || fail "queue accounting did not resolve expired holds and landed or missing blockers: $out"
  view=$(FM_HOME="$home" FM_FLEET_SNAPSHOT_TODAY=2026-07-17 "$VIEW")
  assert_contains "$view" "| future-hold | Future Hold | alpha | ship | external - scheduled | - |" \
    "view omitted an active hold"
  assert_contains "$view" "| expired-hold | Expired Hold | alpha | ship | - | - |" \
    "view rendered an expired hold as active"
  assert_contains "$view" "| active-blocker | Active Blocker | alpha | ship | - | live-dependency - waits on live work |" \
    "view omitted an active blocker"
  assert_contains "$view" "| resolved-blocker | Resolved Blocker | alpha | ship | - | - |" \
    "view rendered a resolved blocker as active"
  assert_contains "$view" "| prose-hold | Explain (hold: scheduled) in title prose | alpha | ship | - | - |" \
    "view treated title prose as a hold tag"
  pass "queue accounting matches tasks-axi active hold and blocker semantics"
}

test_backlog_rows_match_tasks_axi_section_grammar() {
  local home out tab
  home=$(make_home exact-row-grammar)
  tab=$(printf '\t')
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] active-checkbox - Active checkbox
- **active-legacy** - Active legacy
- [x] active-wrong-check - Not an in-flight task

## Queued
- [ ] runnable - Runnable task
  canonical body continuation
 one-space raw obligation
${tab}tab-prefixed raw obligation
- [x] checked-queued - Not queued
- **bold-queued** - Not queued
* [ ] star-bullet - Not queued
- [ ] bad/id - Invalid id
- [X] uppercase-check - Not queued

## Done archive
- [x] landed - Landed task
- [X] uppercase-done - Not done
EOF
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .queue_accounting.queued_total == 8
      and .queue_accounting.structured_queued == 1
      and .queue_accounting.unstructured_queued == 7
      and .queue_accounting.runnable_candidates == 1
      and ([.backlog.records[] | select(.structured) | .id]
           == ["active-checkbox","active-legacy","runnable","landed"])
      and (.backlog.records[] | select(.id == "runnable") | .body_excerpt == "canonical body continuation")
      and ([.backlog.records[] | select(.state == "queued" and .structured != true)] | length == 7)
      and ([.backlog.records[] | select(.raw == " one-space raw obligation")] | length == 1)
      and ([.backlog.records[] | select(.raw == "\ttab-prefixed raw obligation")] | length == 1)
      and ([.backlog.records[] | select(.state == "done" and .structured != true)] | length == 1)
  ' >/dev/null || fail "snapshot accepted rows outside tasks-axi section grammar: $out"
  pass "snapshot recognizes tasks-axi rows and exact two-space continuations"
}

test_heading_resets_body_continuation_context() {
  local home out
  home=$(make_home heading-body-context)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-task - Active task

## Queued
  raw queued obligation after section change
- [ ] queued-before-repeat - Queued before repeated heading

## Queued
  raw queued obligation after repeated heading
- [ ] runnable - Runnable task
EOF
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.backlog.records[] | select(.id == "active-task") | .body_excerpt == null)
      and (.backlog.records[] | select(.id == "queued-before-repeat") | .body_excerpt == null)
      and ([.backlog.records[] | select(.state == "queued" and .structured != true and .raw == "  raw queued obligation after section change")] | length) == 1
      and ([.backlog.records[] | select(.state == "queued" and .structured != true and .raw == "  raw queued obligation after repeated heading")] | length) == 1
      and .queue_accounting.queued_total == 4
      and .queue_accounting.structured_queued == 2
      and .queue_accounting.unstructured_queued == 2
  ' >/dev/null || fail "a heading did not reset body continuation context: $out"
  pass "snapshot resets body continuation context at every heading"
}

test_program_sources_stay_inside_selected_home() {
  local home escaped_home outside out
  home=$(make_home contained-program-sources)
  outside=$TMP_ROOT/outside-program-sources
  mkdir -p "$outside/programs"
  printf '## Queued\n' > "$home/data/backlog.md"
  printf '# Safe\n' > "$home/data/safe-program.md"
  printf '# Escaped file\n' > "$outside/escaped.md"
  printf '# Escaped directory\n' > "$outside/programs/escaped.md"
  ln -s "$outside/escaped.md" "$home/data/escaped-program.md"
  ln -s "$outside/programs" "$home/data/programs"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg path "$home/data/safe-program.md" '
    .program_sources == [{path:$path,relative_path:"safe-program.md"}]
      and .queue_accounting.durable_program_source_count == 1
  ' >/dev/null || fail "snapshot followed a program source outside the selected home: $out"
  escaped_home=$(make_home escaped-data-program-sources)
  mkdir -p "$outside/data"
  printf '## Queued\n' > "$outside/data/backlog.md"
  printf '# Escaped data\n' > "$outside/data/escaped-program.md"
  rmdir "$escaped_home/data"
  ln -s "$outside/data" "$escaped_home/data"
  out=$(FM_HOME="$escaped_home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.program_sources | length) == 0
      and .queue_accounting.durable_program_source_count == 0
  ' >/dev/null || fail "snapshot followed a data directory outside the selected home: $out"
  pass "snapshot rejects program-source symlinks that escape the selected home"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_queue_accounting_surfaces_holds_and_durable_program_boundary
test_queue_accounting_uses_active_hold_and_blocker_semantics
test_backlog_rows_match_tasks_axi_section_grammar
test_heading_resets_body_continuation_context
test_program_sources_stay_inside_selected_home
test_view_renders_dead_secondmate_agent_status
