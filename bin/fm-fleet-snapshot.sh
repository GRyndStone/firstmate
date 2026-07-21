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
#     those sections are preserved as unstructured records.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state prefers the matching persisted watcher observation and
#     preserves state, source, evidence, observation time, age, and freshness.
#     prior_observed_state retains the preceding distinct task/endpoint state.
#     last_status_event is historical append-only evidence with its observed
#     sequence and signature, never current state.
#     external_wait separates the registered completion observer from its last
#     model-free result and freshness.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
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

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-reconcile-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-reconcile-lib.sh"

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

reconciled_matches_lifecycle() {  # <id>
  local id=$1 meta_generation record_generation
  meta_generation=$(fm_reconcile_meta_generation "$STATE/$id.meta" 2>/dev/null || true)
  record_generation=$(fm_reconcile_record_value "$STATE/$id.reconciled" lifecycle_generation)
  [ -n "$meta_generation" ] && [ "$record_generation" = "$meta_generation" ]
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

live_crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep now
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
  now=$(date +%s)
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" --argjson now "$now" \
    '{state:$state,source:$source,detail:$detail,raw:$raw,evidence:$raw,observed_at:$now,age_seconds:0,freshness:"unpersisted",persisted:false}'
}

crew_state_json() {  # <id>
  local id=$1 record meta target recorded_target state source detail evidence observed now age freshness fresh_secs
  record="$STATE/$id.reconciled"
  meta="$STATE/$id.meta"
  [ -f "$record" ] || { live_crew_state_json "$id"; return; }
  reconciled_matches_lifecycle "$id" || { live_crew_state_json "$id"; return; }
  target=$(fm_backend_target_of_meta "$meta")
  recorded_target=$(fm_reconcile_record_value "$record" endpoint)
  [ -n "$target" ] && [ "$target" = "$recorded_target" ] || { live_crew_state_json "$id"; return; }
  state=$(fm_reconcile_record_value "$record" state)
  source=$(fm_reconcile_record_value "$record" source)
  detail=$(fm_reconcile_record_value "$record" detail)
  evidence=$(fm_reconcile_record_value "$record" evidence)
  observed=$(fm_reconcile_record_value "$record" observed_at)
  case "$observed" in ''|*[!0-9]*) observed=0 ;; esac
  now=$(date +%s)
  age=$((now - observed))
  [ "$age" -ge 0 ] || age=0
  fresh_secs=${FM_RECONCILE_FRESH_SECS:-60}
  case "$fresh_secs" in ''|*[!0-9]*|0) fresh_secs=60 ;; esac
  if [ "$observed" -eq 0 ]; then freshness=unknown
  elif [ "$age" -le "$fresh_secs" ]; then freshness=fresh
  else freshness=stale
  fi
  jq -n \
    --arg raw "$evidence" \
    --arg evidence "$evidence" \
    --arg state "$state" \
    --arg source "$source" \
    --arg detail "$detail" \
    --arg freshness "$freshness" \
    --argjson observed_at "$observed" \
    --argjson age_seconds "$age" \
    '{state:$state,source:$source,detail:$detail,raw:$raw,evidence:$evidence,observed_at:$observed_at,age_seconds:$age_seconds,freshness:$freshness,persisted:true}'
}

prior_observed_json() {  # <id>
  local record state source evidence endpoint observed
  record="$STATE/$1.reconciled"
  if ! reconciled_matches_lifecycle "$1"; then
    jq -n '{state:null,source:null,evidence:null,endpoint:null,observed_at:null}'
    return
  fi
  state=$(fm_reconcile_record_value "$record" prior_state)
  source=$(fm_reconcile_record_value "$record" prior_source)
  evidence=$(fm_reconcile_record_value "$record" prior_evidence)
  endpoint=$(fm_reconcile_record_value "$record" prior_endpoint)
  observed=$(fm_reconcile_record_value "$record" prior_observed_at)
  case "$observed" in ''|*[!0-9]*) observed=0 ;; esac
  jq -n \
    --arg state "$state" \
    --arg source "$source" \
    --arg evidence "$evidence" \
    --arg endpoint "$endpoint" \
    --argjson observed_at "$observed" \
    '{state:($state | if . == "" then null else . end),source:($source | if . == "" then null else . end),evidence:($evidence | if . == "" then null else . end),endpoint:($endpoint | if . == "" then null else . end),observed_at:($observed_at | if . == 0 then null else . end)}'
}

external_wait_json() {  # <id>
  local id=$1 record observed_sig observed_state observed_evidence observed_at freshness registration current_sig
  local progress_sig progress_at progress_age meta_generation registration_generation registration_current=0
  local probe_armed probe_wait_sig probe_endpoint probe_status_sequence probe_status_signature probe_status_signal probe_wait_evidence probe_observed
  record="$STATE/$id.reconciled"
  registration=$(fm_reconcile_wait_registration "$STATE" "$id")
  meta_generation=$(fm_reconcile_meta_generation "$STATE/$id.meta" 2>/dev/null || true)
  registration_generation=$(printf '%s' "$registration" | jq -r '.lifecycle_generation // ""')
  if [ "$(printf '%s' "$registration" | jq -r '.registered')" = true ] \
    && [ -n "$meta_generation" ] && [ "$registration_generation" = "$meta_generation" ]; then
    registration_current=1
  fi
  observed_sig=$(fm_reconcile_record_value "$record" wait_signature)
  observed_state=$(fm_reconcile_record_value "$record" wait_state)
  observed_evidence=$(fm_reconcile_record_value "$record" wait_evidence)
  observed_at=$(fm_reconcile_record_value "$record" wait_checked_at)
  progress_sig=$(fm_reconcile_record_value "$record" wait_progress_signature)
  progress_at=$(fm_reconcile_record_value "$record" wait_progress_at)
  probe_armed=$(fm_reconcile_record_value "$record" background_probe_armed)
  probe_wait_sig=$(fm_reconcile_record_value "$record" background_probe_wait_signature)
  probe_endpoint=$(fm_reconcile_record_value "$record" background_probe_endpoint)
  probe_status_sequence=$(fm_reconcile_record_value "$record" background_probe_status_sequence)
  probe_status_signature=$(fm_reconcile_record_value "$record" background_probe_status_signature)
  probe_status_signal=$(fm_reconcile_record_value "$record" background_probe_status_signal_signature)
  probe_wait_evidence=$(fm_reconcile_record_value "$record" background_probe_wait_evidence)
  probe_observed=$(fm_reconcile_record_value "$record" background_probe_observed_at)
  if ! reconciled_matches_lifecycle "$id"; then
    observed_sig=
    observed_state=
    observed_evidence=
    observed_at=0
    progress_sig=
    progress_at=0
    probe_armed=0
    probe_wait_sig=
    probe_endpoint=
    probe_status_sequence=0
    probe_status_signature=
    probe_status_signal=
    probe_wait_evidence=
    probe_observed=0
  fi
  case "$observed_at" in ''|*[!0-9]*) observed_at=0 ;; esac
  case "$progress_at" in ''|*[!0-9]*) progress_at=0 ;; esac
  case "$probe_armed" in 1) ;; *) probe_armed=0 ;; esac
  case "$probe_status_sequence" in ''|*[!0-9]*) probe_status_sequence=0 ;; esac
  case "$probe_observed" in ''|*[!0-9]*) probe_observed=0 ;; esac
  progress_age=$(( $(date +%s) - progress_at ))
  [ "$progress_age" -ge 0 ] || progress_age=0
  current_sig=$(printf '%s' "$registration" | jq -r '.signature')
  if [ "$observed_at" -eq 0 ]; then freshness=unobserved
  elif [ "$observed_sig" = "$current_sig" ]; then freshness=current
  else freshness=registration_changed
  fi
  jq -n \
    --argjson registration "$registration" \
    --arg state "$observed_state" \
    --arg evidence "$observed_evidence" \
    --arg freshness "$freshness" \
    --arg progress_signature "$progress_sig" \
    --arg probe_wait_signature "$probe_wait_sig" \
    --arg probe_endpoint "$probe_endpoint" \
    --arg probe_status_signature "$probe_status_signature" \
    --arg probe_status_signal_signature "$probe_status_signal" \
    --arg probe_wait_evidence "$probe_wait_evidence" \
    --argjson checked_at "$observed_at" \
    --argjson progress_at "$progress_at" \
    --argjson progress_age "$progress_age" \
    --argjson probe_armed "$(bool_json "$probe_armed")" \
    --argjson probe_status_sequence "$probe_status_sequence" \
    --argjson probe_observed_at "$probe_observed" \
    --argjson lifecycle_current "$(bool_json "$registration_current")" \
    '$registration + {lifecycle_current:$lifecycle_current,observation:{state:($state | if . == "" then "unobserved" else . end),evidence:$evidence,checked_at:($checked_at | if . == 0 then null else . end),freshness:$freshness,progress_signature:($progress_signature | if . == "" then null else . end),progress_at:($progress_at | if . == 0 then null else . end),progress_age_seconds:($progress_age | if $progress_at == 0 then null else . end)},background_probe:{armed:$probe_armed,wait_signature:($probe_wait_signature | if . == "" then null else . end),endpoint:($probe_endpoint | if . == "" then null else . end),status_sequence:($probe_status_sequence | if $probe_observed_at == 0 then null else . end),status_signature:($probe_status_signature | if . == "" then null else . end),status_signal_signature:($probe_status_signal_signature | if . == "" then null else . end),wait_evidence:($probe_wait_evidence | if . == "" then null else . end),observed_at:($probe_observed_at | if . == 0 then null else . end)}}'
}

status_event_json() {  # <id> <status-log>
  local id=$1 log=$2 record present=0 raw='' verb='' note='' sequence signature
  local observed_sequence observed_signature observed_raw observed_at freshness
  record="$STATE/$id.reconciled"
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
  fi
  sequence=$(fm_reconcile_status_sequence "$log")
  signature=$(fm_reconcile_file_signature "$log")
  observed_sequence=$(fm_reconcile_record_value "$record" status_sequence)
  observed_signature=$(fm_reconcile_record_value "$record" status_signature)
  observed_raw=$(fm_reconcile_record_value "$record" last_status_event)
  observed_at=$(fm_reconcile_record_value "$record" observed_at)
  if ! reconciled_matches_lifecycle "$id"; then
    observed_sequence=0
    observed_signature=
    observed_raw=
    observed_at=0
  fi
  case "$observed_sequence" in ''|*[!0-9]*) observed_sequence=0 ;; esac
  case "$observed_at" in ''|*[!0-9]*) observed_at=0 ;; esac
  if [ "$observed_at" -eq 0 ]; then freshness=unobserved
  elif [ "$sequence" -eq "$observed_sequence" ] && [ "$signature" = "$observed_signature" ]; then freshness=current
  else freshness=advanced_or_changed
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --arg signature "$signature" \
    --arg observed_raw "$observed_raw" \
    --arg observed_signature "$observed_signature" \
    --arg freshness "$freshness" \
    --argjson sequence "$sequence" \
    --argjson observed_sequence "$observed_sequence" \
    --argjson observed_at "$observed_at" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",sequence:$sequence,signature:$signature,last_event:{state:$verb,note:$note,raw:$raw},supervisor_observation:{sequence:($observed_sequence | if $observed_at == 0 then null else . end),signature:($observed_signature | if . == "" then null else . end),event:{raw:($observed_raw | if . == "" then null else . end)},observed_at:($observed_at | if . == 0 then null else . end),freshness:$freshness}}'
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
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
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
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | del(.section,.order)
  ' < "$BACKLOG"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local pr pr_source event_json current_json prior_json wait_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json reconciled_json wait_path_json
  local last_event_raw current_state current_source current_freshness pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
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
    prior_json=$(prior_observed_json "$id")
    wait_json=$(external_wait_json "$id")
    event_json=$(status_event_json "$id" "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')
    current_freshness=$(printf '%s' "$current_json" | jq -r '.freshness // ""')

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
#   - a live activity read (run-step, busy pane, or owned command) that is
#     working/done, so a
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
    if [ "$kind" != secondmate ] \
       && { [ "$current_freshness" = fresh ] || [ "$current_freshness" = unpersisted ]; } && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ] || [ "$current_source" = owned-command ]; } \
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
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    agent_alive=not_checked
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    reconciled_json=$(path_present_json "$STATE/$id.reconciled")
    wait_path_json=$(path_present_json "$STATE/$id.wait")
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
      --argjson prior_observed_state "$prior_json" \
      --argjson external_wait "$wait_json" \
      --argjson meta_path "$meta_json" \
      --argjson reconciled_path "$reconciled_json" \
      --argjson wait_path "$wait_path_json" \
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
          reconciled:$reconciled_path,
          external_wait:$wait_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:$current_state,
        prior_observed_state:$prior_observed_state,
        last_status_event:($status_log | {sequence,signature,event:.last_event,supervisor_observation}),
        external_wait:$external_wait,
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

BACKLOG_JSON=$(backlog_json)
TASKS_JSON=$(task_json_lines)
SCOUT_REPORTS_JSON=$(scout_report_lines)

jq -n \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_guidance:{
       note:"For kind=secondmate, send marked supervisor requests with fm-send and read the status/doc return channel; do not routinely fm-peek the secondmate chat for answers."
     }
   }'
