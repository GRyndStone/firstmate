#!/usr/bin/env bash
# fm-kuru-organ.sh - Firstmate as a KURU orchestration organ (T-e.2).
#
# Exposes goal↔task linkage and the evidence-only organ call surface that sits
# behind KURU's orchestration seam. The organ binds FM tasks to Brain goals and
# returns evidence; it never writes KURU criterion outcomes, never invents
# harness/model routing, and never arms initiative.
#
# Live crew spawn / supervise / teardown remain the existing firstmate scripts
# (fm-spawn, fm-watch, fm-teardown). Organ `spawn` here is bind-only: it links
# the dispatch to a task id and returns evidence that work is bound. Drivers
# that need a live crew still use the normal lifecycle after binding.
#
# Usage:
#   fm-kuru-organ.sh link <task-id> --goal <slug> [--dispatch <dispatch-id>]
#   fm-kuru-organ.sh unlink <task-id>
#   fm-kuru-organ.sh show-link <task-id>
#   fm-kuru-organ.sh find-goal <goal-slug>
#   fm-kuru-organ.sh call <spawn|status|teardown|collect_evidence>
#       --dispatch-file <path> [--task-id <id>] [--result ok|failed|...]
#   fm-kuru-organ.sh make-evidence --id <ev-id> --dispatch-id <d> --goal <slug>
#       --surface <task|pr|...> --result <ok|...> --summary "..." [--task-id <id>]
#   fm-kuru-organ.sh validate-evidence <file|->
#   fm-kuru-organ.sh validate-dispatch <file|->
#
# Environment: FM_HOME / FM_STATE_OVERRIDE / FM_DATA_OVERRIDE / FM_ROOT_OVERRIDE
# as elsewhere. JSON on stdout for call/make-evidence; text for link helpers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-kuru-organ-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-kuru-organ-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-kuru-organ.sh link <task-id> --goal <slug> [--dispatch <dispatch-id>]
  fm-kuru-organ.sh unlink <task-id>
  fm-kuru-organ.sh show-link <task-id>
  fm-kuru-organ.sh find-goal <goal-slug>
  fm-kuru-organ.sh call <spawn|status|teardown|collect_evidence>
      --dispatch-file <path> [--task-id <id>] [--result ok|failed|blocked|needs_decision|pending]
  fm-kuru-organ.sh make-evidence --id <ev-id> --dispatch-id <d> --goal <slug>
      --surface <task|pr|run|validator|log|other> --result <ok|...> --summary "..."
      [--task-id <id>] [--adapter firstmate]
  fm-kuru-organ.sh validate-evidence <file|->
  fm-kuru-organ.sh validate-dispatch <file|->
EOF
}

die() {
  printf 'fm-kuru-organ: %s\n' "$1" >&2
  exit "${2:-1}"
}

cmd_link() {
  local id=${1:-} goal="" dispatch=""
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --goal) shift; goal=${1:-} ;;
      --dispatch) shift; dispatch=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  [ -n "$goal" ] || die "link requires --goal <slug>" 2
  fm_kuru_link_set "$STATE" "$DATA" "$id" "$goal" "$dispatch" || {
    case $? in
      1) die "link failed: missing meta or update error for $id" ;;
      2) die "link failed: invalid task id, goal, or dispatch slug" 2 ;;
      *) die "link failed (rc $?)" ;;
    esac
  }
  printf 'linked task=%s goal=%s' "$id" "$goal"
  [ -n "$dispatch" ] && printf ' dispatch=%s' "$dispatch"
  printf '\n'
}

cmd_unlink() {
  local id=${1:-}
  [ -n "$id" ] || { usage; exit 2; }
  fm_kuru_link_clear "$STATE" "$DATA" "$id" || {
    case $? in
      1) die "unlink failed: missing meta for $id" ;;
      2) die "unlink failed: invalid task id" 2 ;;
      *) die "unlink failed (rc $?)" ;;
    esac
  }
  printf 'unlinked task=%s\n' "$id"
}

cmd_show_link() {
  local id=${1:-} out
  [ -n "$id" ] || { usage; exit 2; }
  out=$(fm_kuru_link_show "$STATE" "$id") || die "show-link: no such task $id"
  if [ -z "$out" ]; then
    printf 'task=%s unlinked\n' "$id"
    return 0
  fi
  printf 'task=%s\n%s\n' "$id" "$out"
}

cmd_find_goal() {
  local goal=${1:-}
  [ -n "$goal" ] || { usage; exit 2; }
  fm_kuru_find_goal_tasks "$STATE" "$DATA" "$goal" || die "find-goal: invalid goal slug" 2
}

# Organ call: bind-only spawn, observational status, teardown link clear,
# collect_evidence from local status. Always prints evidence JSON (or error).
cmd_call() {
  local verb=${1:-} dispatch_file="" task_id="" result="ok"
  [ -n "$verb" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dispatch-file) shift; dispatch_file=${1:-} ;;
      --task-id) shift; task_id=${1:-} ;;
      --result) shift; result=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift
  done

  if reason=$(fm_kuru_organ_verb_refuse_reason "$verb" 2>/dev/null); then
    if ! fm_kuru_organ_verb_ok "$verb"; then
      die "$reason" 2
    fi
  fi

  [ -n "$dispatch_file" ] || die "call requires --dispatch-file" 2
  [ -f "$dispatch_file" ] || die "dispatch file not found: $dispatch_file"
  fm_kuru_validate_dispatch_json "$dispatch_file" || die "dispatch failed validation"

  local dispatch_id goal_slug brief organ_ref dispatch_status
  dispatch_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["id"])' "$dispatch_file")
  goal_slug=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["goal_slug"])' "$dispatch_file")
  brief=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("brief") or "")' "$dispatch_file")
  organ_ref=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("organ_ref") or "")' "$dispatch_file")
  dispatch_status=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("status") or "")' "$dispatch_file")

  case "$result" in
    ok|failed|blocked|needs_decision|pending) ;;
    *) die "invalid --result $result" 2 ;;
  esac

  # Resolve task id: explicit flag, dispatch.organ_ref, or synthesize from dispatch.
  if [ -z "$task_id" ]; then
    if [ -n "$organ_ref" ]; then
      task_id=$organ_ref
    else
      # d-<portable> -> portable when possible; else full dispatch id as task slug
      case "$dispatch_id" in
        d-*) task_id=${dispatch_id#d-} ;;
        *) task_id=$dispatch_id ;;
      esac
    fi
  fi
  fm_kuru_task_id_valid "$task_id" || die "invalid task id: $task_id" 2

  local meta="$STATE/$task_id.meta"
  local ev_id summary surface ev_result refs_json
  local seq_file="$STATE/$task_id.kuru-ev-seq"
  local seq=0
  if [ -f "$seq_file" ]; then
    seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  fi
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file"
  # Evidence ids must match portable grammar; keep short.
  ev_id="ev-${task_id}-${seq}"
  # Truncate if needed
  if [ "${#ev_id}" -gt 64 ]; then
    ev_id="ev-${seq}-$(printf '%s' "$task_id" | tr -cd 'a-z0-9' | head -c 40)"
  fi

  case "$verb" in
    spawn)
      # Bind-only: ensure meta exists (organ sidecar), link goal, no crew launch.
      mkdir -p "$STATE" "$DATA"
      if [ ! -f "$meta" ]; then
        {
          printf 'window=organ-bound:%s\n' "$task_id"
          printf 'kind=ship\n'
          printf 'mode=direct-PR\n'
          printf 'yolo=off\n'
          printf 'harness=none\n'
          printf 'organ_bound=1\n'
          printf 'kuru_organ=firstmate\n'
        } > "$meta"
      fi
      fm_kuru_link_set "$STATE" "$DATA" "$task_id" "$goal_slug" "$dispatch_id" \
        || die "spawn bind: failed to link task $task_id to goal $goal_slug"
      # Refresh generation-safe organ_bound marker if meta pre-existed.
      local gen
      gen=$(fm_reconcile_meta_generation "$meta") || die "spawn: cannot read generation"
      fm_reconcile_meta_update "$STATE" "$task_id" "$gen" \
        --set organ_bound 1 --set kuru_organ firstmate || true
      surface=task
      ev_result=pending
      summary="bound organ work task_id=${task_id} goal=${goal_slug} (bind-only; no crew launch; no initiative)"
      refs_json=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"brief":sys.argv[2],"bind_only":True,"initiative":False}))' "$task_id" "$brief")
      ;;
    status)
      local last_status=""
      if [ -f "$STATE/$task_id.status" ]; then
        last_status=$(tail -n1 "$STATE/$task_id.status" 2>/dev/null || true)
      fi
      local linked_goal
      linked_goal=$(fm_kuru_meta_get "$meta" kuru_goal 2>/dev/null || true)
      surface=log
      ev_result=pending
      case "$last_status" in
        done:*) ev_result=ok ;;
        failed:*) ev_result=failed ;;
        blocked:*) ev_result=blocked ;;
        needs-decision:*|needs_decision:*) ev_result=needs_decision ;;
      esac
      summary="status task_id=${task_id} dispatch_status=${dispatch_status} last_status=${last_status:-none} linked_goal=${linked_goal:-none}"
      refs_json=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"dispatch_status":sys.argv[2],"last_status":sys.argv[3],"linked_goal":sys.argv[4]}))' \
        "$task_id" "$dispatch_status" "${last_status:-}" "${linked_goal:-}")
      ;;
    teardown)
      if [ -f "$meta" ]; then
        fm_kuru_link_clear "$STATE" "$DATA" "$task_id" || true
      fi
      surface=task
      ev_result=failed
      summary="teardown organ bind cleared task_id=${task_id}"
      refs_json=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1]}))' "$task_id")
      ;;
    collect_evidence)
      local last_status=""
      if [ -f "$STATE/$task_id.status" ]; then
        last_status=$(tail -n1 "$STATE/$task_id.status" 2>/dev/null || true)
      fi
      surface=task
      ev_result=$result
      # Status labels alone never force attainment language into evidence.
      case "$last_status" in
        done:*)
          [ "$result" = "ok" ] || true
          surface=task
          ;;
        failed:*)
          [ "$result" = "ok" ] && ev_result=failed
          ;;
      esac
      summary="organ work finished result=${ev_result} task_id=${task_id} last_status=${last_status:-none} (evidence only; not criterion attainment)"
      refs_json=$(python3 -c 'import json,sys; print(json.dumps({"task_id":sys.argv[1],"last_status":sys.argv[2],"evidence_only":True,"not_criterion_attainment":True}))' \
        "$task_id" "${last_status:-}")
      ;;
    *)
      die "unsupported verb $verb" 2
      ;;
  esac

  fm_kuru_make_evidence \
    --id "$ev_id" \
    --dispatch-id "$dispatch_id" \
    --goal "$goal_slug" \
    --surface "$surface" \
    --result "$ev_result" \
    --summary "$summary" \
    --task-id "$task_id" \
    --adapter firstmate \
    --refs-json "$refs_json"
}

cmd_make_evidence() {
  fm_kuru_make_evidence "$@"
}

cmd_validate_evidence() {
  local src=${1:--}
  local bad
  if ! bad=$(fm_kuru_evidence_forbidden_key_scan "$src"); then
    rc=$?
    if [ "$rc" -eq 2 ]; then
      die "validate-evidence: scan error"
    fi
    if [ -n "$bad" ]; then
      printf 'fm-kuru-organ: forbidden evidence keys:\n%s\n' "$bad" >&2
      exit 1
    fi
  fi
  # Also require type=evidence via python for a positive shape check when src is file.
  if [ "$src" != "-" ] && [ -f "$src" ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
assert d.get("type")=="evidence", "type must be evidence"
assert "outcome" not in d and d.get("attained") is not True
print("ok")' "$src" || die "validate-evidence: shape failed"
  else
    printf 'ok\n'
  fi
}

cmd_validate_dispatch() {
  local src=${1:--}
  fm_kuru_validate_dispatch_json "$src" || die "validate-dispatch failed"
  printf 'ok\n'
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  case "$cmd" in
    link) cmd_link "$@" ;;
    unlink) cmd_unlink "$@" ;;
    show-link) cmd_show_link "$@" ;;
    find-goal) cmd_find_goal "$@" ;;
    call) cmd_call "$@" ;;
    make-evidence) cmd_make_evidence "$@" ;;
    validate-evidence) cmd_validate_evidence "$@" ;;
    validate-dispatch) cmd_validate_dispatch "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
