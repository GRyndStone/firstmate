#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records; structured rows
#     expose raw tags plus active_hold, active_blocked_by_ids, and runnable.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   endpoint_anomalies[]: deterministic same-home duplicate endpoint findings.
#   program_sources[]: durable data/program.md, data/*-program.md, and
#     data/programs/*.md pointers.
#   queue_accounting: runnable candidates, held/blocked queued work, and the
#     explicit supervisor-judgment boundary for program decomposition.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
TODAY=${FM_FLEET_SNAPSHOT_TODAY:-$(date +%Y-%m-%d)}

# shellcheck source=bin/fm-wake-lib.sh
FM_WAKE_STATE_INIT=skip
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
unset FM_WAKE_STATE_INIT
STATE=$FM_VALIDATED_STATE_PATH

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-program-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-program-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.
EOF
}

case "${1:---json}" in
  --json) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

ENDPOINT_ANOMALIES_JSON=$(
  FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-endpoint-audit.sh" --json
) || exit 1

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {
  if [ ! -f "$BACKLOG" ]; then
    jq -n --arg path "$BACKLOG" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$BACKLOG" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      ascii_downcase
      | if . == "in flight" then "in_flight"
      elif . == "queued" then "queued"
      elif startswith("done") then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def dep_re:
      "[[:space:]]*(?<type>blocked-by|parent|discovered-from):[[:space:]]*(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)(?:[[:space:]]+-[[:space:]]+(?<reason>(?:(?![[:space:]]+(?:blocked-by|parent|discovered-from):[[:space:]]).)+?))?[[:space:]]*$";
    def repo_re: "[[:space:]]*\\((?:[^()]*\\+[[:space:]]*)?repo:[[:space:]]*(?<value>[^)]+)\\)[[:space:]]*$";
    def kind_re: "[[:space:]]*\\(kind:[[:space:]]*(?<value>[^)]+)\\)[[:space:]]*$";
    def priority_re: "[[:space:]]*\\(priority:[[:space:]]*(?<value>[0-4])\\)[[:space:]]*$";
    def since_re: "[[:space:]]*\\(since[[:space:]]+(?<value>[0-9]{4}-[0-9]{2}-[0-9]{2})\\)[[:space:]]*$";
    def closed_re: "[[:space:]]*\\((?<verb>merged|reported|done|closed)[[:space:]]+(?<value>[0-9]{4}-[0-9]{2}-[0-9]{2})\\)[[:space:]]*$";
    def hold_until_re: "[[:space:]]*\\(hold-until:[[:space:]]*(?<value>[0-9]{4}-[0-9]{2}-[0-9]{2})\\)[[:space:]]*$";
    def hold_kind_re: "[[:space:]]*\\(hold-kind:[[:space:]]*(?<value>captain|external|load|parked|future)\\)[[:space:]]*$";
    def hold_re: "[[:space:]]*\\(hold:[[:space:]]*(?<value>[^()]+)\\)[[:space:]]*$";
    def peel_tags:
      ((.title | capture(dep_re)?) // null) as $dep
      | if $dep != null then
          .title |= sub(dep_re; "")
          | .deps = ([{type:$dep.type,id:$dep.id} + (if $dep.reason == null then {} else {reason:($dep.reason | trim)} end)] + .deps)
          | peel_tags
        else ((.title | capture(repo_re)?) // null) as $repo
        | if $repo != null then
            .title |= sub(repo_re; "")
            | .repo = (.repo // ($repo.value | trim))
            | peel_tags
          else ((.title | capture(kind_re)?) // null) as $kind
          | if $kind != null then
              .title |= sub(kind_re; "")
              | .kind = (.kind // ($kind.value | trim))
              | peel_tags
            else ((.title | capture(priority_re)?) // null) as $priority
            | if $priority != null then
                .title |= sub(priority_re; "")
                | .priority = (.priority // ($priority.value | tonumber))
                | peel_tags
              else ((.title | capture(since_re)?) // null) as $since
              | if $since != null then
                  .title |= sub(since_re; "")
                  | .since = (.since // $since.value)
                  | peel_tags
                else ((.title | capture(closed_re)?) // null) as $closed
                | if $closed != null then
                    .title |= sub(closed_re; "")
                    | .closed = (.closed // {verb:$closed.verb,date:$closed.value})
                    | peel_tags
                  else ((.title | capture(hold_until_re)?) // null) as $hold_until
                  | if $hold_until != null then
                      .title |= sub(hold_until_re; "")
                      | .hold_until = (.hold_until // $hold_until.value)
                      | peel_tags
                    else ((.title | capture(hold_kind_re)?) // null) as $hold_kind
                    | if $hold_kind != null then
                        .title |= sub(hold_kind_re; "")
                        | .hold_kind = (.hold_kind // $hold_kind.value)
                        | peel_tags
                      else ((.title | capture(hold_re)?) // null) as $hold
                      | if $hold != null then
                          .title |= sub(hold_re; "")
                          | .hold = (.hold // ($hold.value | trim))
                          | peel_tags
                        else . end
                      end
                    end
                  end
                end
              end
            end
          end
        end;
    def tags($rest):
      {title:$rest,repo:null,kind:null,priority:null,since:null,closed:null,hold:null,hold_kind:null,hold_until:null,deps:[]}
      | peel_tags
      | .title |= trim;
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($title):
      $title
      | gsub(wrapped_url_pattern; "")
      | clean_title;
    def blocked_deps($tags): [$tags.deps[] | select(.type == "blocked-by")];
    def local_note($title):
      cap(($title | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest; $tags):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $tags.closed != null then $tags.closed
        elif $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def unchecked_row($line):
      (($line | capture("^- \\[ \\] (?<id>[A-Za-z0-9][A-Za-z0-9._-]*) - (?<rest>.*)$")?) // null) as $match
      | if $match == null then null else $match + {check:" "} end;
    def legacy_in_flight_row($line):
      (($line | capture("^- \\*\\*(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\\*\\* - (?<rest>.*)$")?) // null) as $match
      | if $match == null then null else $match + {check:" "} end;
    def done_row($line):
      (($line | capture("^- \\[x\\] (?<id>[A-Za-z0-9][A-Za-z0-9._-]*) - (?<rest>.*)$")?) // null) as $match
      | if $match == null then null else $match + {check:"x"} end;
    def row_match($line; $section):
      if $section == "queued" then unchecked_row($line)
      elif $section == "in_flight" then (unchecked_row($line) // legacy_in_flight_row($line))
      elif $section == "done" then done_row($line)
      else null end;
    def structured_row($line; $section): row_match($line; $section) != null;
    def parse_row($line; $section; $order):
      row_match($line; $section) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | tags($rest) as $tags
          | blocked_deps($tags) as $blockers
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($tags.title),
             repo:metadata($rest; "repo"),
             kind:(metadata($rest; "kind") // $tags.kind),
             priority:(metadata($rest; "priority") // (if $tags.priority == null then null else ($tags.priority | tostring) end)),
             hold:$tags.hold,
             hold_kind:$tags.hold_kind,
             hold_until:$tags.hold_until,
             deps:$tags.deps,
             blocked_by:($blockers[0].id // null),
             blocked_by_ids:[$blockers[].id],
             blocked_reason:($blockers[0].reason // null),
             since:(metadata_word($rest; "since") // $tags.since),
             merged:(metadata_word($rest; "merged") // (if $tags.closed.verb == "merged" then $tags.closed.date else null end)),
             reported:(metadata_word($rest; "reported") // (if $tags.closed.verb == "reported" then $tags.closed.date else null end)),
             done:(metadata_word($rest; "done") // (if $tags.closed.verb == "done" then $tags.closed.date else null end)),
             completion:completion($rest; $tags),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($tags.title),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0,body_open:false};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
         | .body_open = false
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line; .section) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
         | .body_open = true
       elif (.body_open == true and (.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^  "))) then
         ($line | sub("^  ";"")) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
         | .body_open = false
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | del(.section,.order,.body_open)
  ' < "$BACKLOG"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local pr pr_source event_json current_json endpoint_exists endpoint_state agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_json=$(crew_state_json "$id")
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # Secondmates are excluded from lifecycle clearing: they are persistent and
    # multiplex many concerns onto one stream, so activity on one concern must
    # never clear another concern's keyed decision. A parked/blocked state, or a
    # non-authoritative status-log/none read on a still-live task, keeps the fold's
    # open decision surfacing.
    open_decisions_tsv=$(status_open_decisions "$status_log")
    if [ "$kind" != secondmate ] && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
           && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
         || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
    blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

    endpoint_exists=null
    endpoint_state=unknown
    if [ -n "$target" ]; then
      endpoint_state=$(fm_backend_target_state_of_meta "$meta" "fm-$id")
      case "$endpoint_state" in
        present) endpoint_exists=true ;;
        absent) endpoint_exists=false ;;
        *) endpoint_exists=null ;;
      esac
    fi
    agent_alive=not_checked
    if [ "$kind" = secondmate ] && [ "${endpoint_state:-unknown}" = present ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ]; then home_json=$(path_present_json "$home"); else home_json=$(jq -n '{path:null,present:false}'); fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        backend:$backend,
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:$current_state,
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          open_decisions:$open_decisions,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

program_source_lines() {
  local relative source
  while IFS=$'\t' read -r relative source; do
    [ -n "$source" ] || continue
    jq -n --arg path "$source" --arg relative "$relative" '{path:$path,relative_path:$relative}'
  done < <(fm_program_source_lines "$DATA" "$FM_HOME") | jq -s 'sort_by(.relative_path)'
}

BACKLOG_JSON=$(backlog_json)
TASKS_JSON=$(task_json_lines)
SCOUT_REPORTS_JSON=$(scout_report_lines)
PROGRAM_SOURCES_JSON=$(program_source_lines)

jq -n \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --arg today "$TODAY" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  --argjson program_sources "$PROGRAM_SOURCES_JSON" \
  --argjson endpoint_anomalies "$ENDPOINT_ANOMALIES_JSON" \
  'def raw_blocker_ids($record):
     ($record.blocked_by_ids // (if ($record.blocked_by // "") == "" then [] else [$record.blocked_by] end));
   def active_blocker_ids($record; $records):
     if $record.state == "done" then []
     else raw_blocker_ids($record) as $ids
     | [$ids[] as $id
        | select(any($records[]?;
                     .structured == true
                     and .state != "done"
                     and .id == $id))
        | $id]
     end;
   def annotate_record($record; $records):
     if $record.structured != true then $record
     else active_blocker_ids($record; $records) as $active_ids
     | (((($record.hold // "") != "")
         and $record.state != "done"
         and ((($record.hold_until // "") == "") or (($record.hold_until // "") > $today)))) as $active_hold
     | $record + {
         active_hold:$active_hold,
         active_blocked_by_ids:$active_ids,
         active_blocked_by:($active_ids[0] // null),
         active_blocked_reason:([$record.deps[]?
                                 | select(.type == "blocked-by" and .id == ($active_ids[0] // null))
                                 | .reason][0] // null),
         active_blocked:($active_ids | length > 0),
         runnable:($record.state == "queued" and ($active_hold | not) and (($active_ids | length) == 0))
       }
     end;
   ($backlog | .records as $records | .records |= map(annotate_record(.; $records))) as $derived_backlog
   | def backlog_by_id($id): ($derived_backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$derived_backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     endpoint_anomalies:$endpoint_anomalies,
     program_sources:$program_sources,
     queue_accounting:{
       queued_total:([$derived_backlog.records[]? | select(.state == "queued")] | length),
       structured_queued:([$derived_backlog.records[]? | select(.state == "queued" and .structured == true)] | length),
       unstructured_queued:([$derived_backlog.records[]? | select(.state == "queued" and .structured != true)] | length),
       held:([$derived_backlog.records[]? | select(.state == "queued" and .structured == true and .active_hold)] | length),
       blocked:([$derived_backlog.records[]? | select(.state == "queued" and .structured == true and .active_blocked)] | length),
       runnable_candidates:([$derived_backlog.records[]? | select(.state == "queued" and .structured == true and .runnable)] | length),
       empty_runnable_queue:(([$derived_backlog.records[]? | select(.state == "queued" and .structured == true and .runnable)] | length) == 0),
       durable_program_source_count:($program_sources | length),
       decomposition_status:(if ($program_sources | length) > 0 then "requires_supervisor_judgment" else "no_declared_program_sources" end),
       supervisor_boundary:(if ($program_sources | length) > 0 then "An empty runnable queue does not prove the durable program is complete; audit each program source for obligations that were never materialized as backlog tasks." else "No convention-named durable program source was found; absence does not prove that no plan exists elsewhere." end)
     },
     secondmate_guidance:{
       note:"For kind=secondmate, send marked supervisor requests with fm-send and read the status/doc return channel; do not routinely fm-peek the secondmate chat for answers."
     }
   }'
