#!/usr/bin/env bash
# shellcheck shell=bash
# Firstmate-as-KURU-orchestration-organ helpers (T-e.2 / plan §8).
#
# This file is the single owner of FM-side goal↔task linkage fields and the
# evidence-only organ boundary that mirrors KURU's orchestration seam
# (docs/seams/orchestration.md on the kuru repo; local contract in
# docs/kuru-organ.md).
#
# Public functions:
#   fm_kuru_slug_valid <value>
#   fm_kuru_task_id_valid <value>
#   fm_kuru_meta_get <meta-path> <key>
#   fm_kuru_link_set <state-dir> <data-dir> <task-id> <goal-slug> [dispatch-id]
#   fm_kuru_link_clear <state-dir> <data-dir> <task-id>
#   fm_kuru_link_show <state-dir> <task-id>
#   fm_kuru_find_goal_tasks <state-dir> <data-dir> <goal-slug>
#   fm_kuru_organ_verb_ok <verb>          # 0 if allowed organ verb
#   fm_kuru_organ_verb_refuse_reason <verb>
#   fm_kuru_evidence_forbidden_key_scan <json-text|file>  # prints bad keys; rc 1 if any
#   fm_kuru_make_evidence ...             # prints one evidence JSON object on stdout
#   fm_kuru_validate_dispatch_json <file-or->  # rc 0 if dispatch shape is acceptable
#
# Hard boundary: the organ returns evidence only. It never writes KURU goal
# outcome / attained fields, never invents harness/model routing, and never
# arms initiative. Live crew spawn/supervise/teardown remain the existing
# firstmate machinery; this organ surface binds work and reports evidence.

_FM_KURU_ORGAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_KURU_ORGAN_LIB_DIR="."
# shellcheck source=bin/fm-reconcile-lib.sh disable=SC1091
. "$_FM_KURU_ORGAN_LIB_DIR/fm-reconcile-lib.sh"

# Organ verbs the seam allows. Routing verbs are refused (REQ-19).
FM_KURU_ORGAN_VERBS="spawn status teardown collect_evidence"
FM_KURU_ROUTING_VERBS="route choose_model pick_harness select_profile usage_route"

# Keys that would smuggle outcome or routing authority into organ returns.
FM_KURU_FORBIDDEN_EVIDENCE_KEYS="outcome attained criterion_outcome goal_outcome chosen_model chosen_harness route routing profile_choice"

fm_kuru_slug_valid() {
  local v=$1
  # Portable grammar: [a-z0-9][a-z0-9._-]{0,63} without bash-4 regex.
  case "$v" in
    ''|.*|*[!a-z0-9._-]*) return 1 ;;
  esac
  case "$v" in
    [a-z0-9]|[a-z0-9][a-z0-9._-]*) ;;
    *) return 1 ;;
  esac
  [ "${#v}" -le 64 ]
}

fm_kuru_task_id_valid() {
  fm_reconcile_task_id_valid "$1"
}

fm_kuru_meta_get() {
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "${line#*=}"
}

fm_kuru_index_dir() {  # <data-dir>
  printf '%s/kuru-goal-index\n' "$1"
}

fm_kuru_index_path() {  # <data-dir> <goal-slug>
  printf '%s/kuru-goal-index/%s\n' "$1" "$2"
}

# Append task-id to durable goal index if missing. Creates parent dirs.
fm_kuru_index_add() {  # <data-dir> <goal-slug> <task-id>
  local data=$1 goal=$2 id=$3 path dir tmp
  fm_kuru_slug_valid "$goal" || return 2
  fm_kuru_task_id_valid "$id" || return 2
  dir=$(fm_kuru_index_dir "$data")
  path=$(fm_kuru_index_path "$data" "$goal")
  mkdir -p "$dir" || return 1
  if [ -f "$path" ] && grep -Fxq "$id" "$path" 2>/dev/null; then
    return 0
  fi
  tmp="$path.tmp.${BASHPID:-$$}"
  if [ -f "$path" ]; then
    cat "$path" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp" || return 1
  fi
  printf '%s\n' "$id" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

# Remove task-id from one goal index file; delete empty file.
fm_kuru_index_remove_one() {  # <data-dir> <goal-slug> <task-id>
  local data=$1 goal=$2 id=$3 path tmp
  path=$(fm_kuru_index_path "$data" "$goal")
  [ -f "$path" ] || return 0
  tmp="$path.tmp.${BASHPID:-$$}"
  if ! grep -Fxv "$id" "$path" > "$tmp" 2>/dev/null; then
    # grep exit 1 means all lines matched (file becomes empty) — still ok
    :
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$path"
    return 0
  fi
  mv -f "$tmp" "$path"
}

# Remove task-id from every goal index under data/kuru-goal-index/.
fm_kuru_index_remove_task() {  # <data-dir> <task-id>
  local data=$1 id=$2 dir f goal
  dir=$(fm_kuru_index_dir "$data")
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    goal=${f##*/}
    fm_kuru_index_remove_one "$data" "$goal" "$id"
  done
}

# Link task meta + durable inverse index. Requires existing state/<id>.meta.
# Optional dispatch id dual-writes kuru_dispatch= for the KURU work record.
fm_kuru_link_set() {  # <state-dir> <data-dir> <task-id> <goal-slug> [dispatch-id]
  local state=$1 data=$2 id=$3 goal=$4 dispatch=${5:-} meta gen update_args
  fm_kuru_task_id_valid "$id" || return 2
  fm_kuru_slug_valid "$goal" || return 2
  if [ -n "$dispatch" ] && ! fm_kuru_slug_valid "$dispatch"; then
    return 2
  fi
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  gen=$(fm_reconcile_meta_generation "$meta") || return 1
  update_args=(--set kuru_goal "$goal")
  if [ -n "$dispatch" ]; then
    update_args+=(--set kuru_dispatch "$dispatch")
  fi
  fm_reconcile_meta_update "$state" "$id" "$gen" "${update_args[@]}" || return $?
  fm_kuru_index_add "$data" "$goal" "$id" || return 1
  return 0
}

# Clear KURU link fields from meta and drop task from durable index.
fm_kuru_link_clear() {  # <state-dir> <data-dir> <task-id>
  local state=$1 data=$2 id=$3 meta gen prior_goal
  fm_kuru_task_id_valid "$id" || return 2
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  prior_goal=$(fm_kuru_meta_get "$meta" kuru_goal)
  gen=$(fm_reconcile_meta_generation "$meta") || return 1
  fm_reconcile_meta_update "$state" "$id" "$gen" \
    --remove kuru_goal --remove kuru_dispatch || return $?
  if [ -n "$prior_goal" ]; then
    fm_kuru_index_remove_one "$data" "$prior_goal" "$id"
  else
    fm_kuru_index_remove_task "$data" "$id"
  fi
  return 0
}

# Print "goal=<slug>\ndispatch=<id-or-empty>" for a task, or nothing if unlinked.
fm_kuru_link_show() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta goal dispatch
  fm_kuru_task_id_valid "$id" || return 2
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  goal=$(fm_kuru_meta_get "$meta" kuru_goal)
  [ -n "$goal" ] || return 0
  dispatch=$(fm_kuru_meta_get "$meta" kuru_dispatch)
  printf 'goal=%s\n' "$goal"
  printf 'dispatch=%s\n' "$dispatch"
}

# List task ids linked to a goal (union of durable index + live meta scan).
# Bash 3.2 compatible (no associative arrays): de-dupe via a temp file.
fm_kuru_find_goal_tasks() {  # <state-dir> <data-dir> <goal-slug>
  local state=$1 data=$2 goal=$3 path f meta g id tmp
  fm_kuru_slug_valid "$goal" || return 2
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-kuru-find.XXXXXX") || return 1
  path=$(fm_kuru_index_path "$data" "$goal")
  if [ -f "$path" ]; then
    while IFS= read -r id || [ -n "$id" ]; do
      [ -n "$id" ] || continue
      printf '%s\n' "$id" >> "$tmp"
    done < "$path"
  fi
  for f in "$state"/*.meta; do
    [ -f "$f" ] || continue
    meta=$f
    g=$(fm_kuru_meta_get "$meta" kuru_goal)
    [ "$g" = "$goal" ] || continue
    id=${f##*/}
    id=${id%.meta}
    printf '%s\n' "$id" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    sort -u "$tmp"
  fi
  rm -f "$tmp"
}

fm_kuru_organ_verb_ok() {
  local verb=$1 v
  for v in $FM_KURU_ORGAN_VERBS; do
    [ "$v" = "$verb" ] && return 0
  done
  return 1
}

fm_kuru_organ_verb_refuse_reason() {
  local verb=$1 v
  for v in $FM_KURU_ROUTING_VERBS; do
    if [ "$v" = "$verb" ]; then
      printf 'organ_call.verb %s is routing authority — refused (Brain owns routing; organ has no second router)\n' "$verb"
      return 0
    fi
  done
  if ! fm_kuru_organ_verb_ok "$verb"; then
    printf 'organ_call.verb must be one of: %s\n' "$FM_KURU_ORGAN_VERBS"
    return 0
  fi
  return 1
}

# Scan JSON text or file for forbidden outcome/routing keys at top level or under .refs.
# Prints each forbidden key on its own line. Returns 1 when any are present.
fm_kuru_evidence_forbidden_key_scan() {
  local src=$1
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 required for evidence key scan\n' >&2
    return 2
  fi
  FORBIDDEN="$FM_KURU_FORBIDDEN_EVIDENCE_KEYS" python3 - "$src" <<'PY'
import json, os, sys
forbidden = set(os.environ.get("FORBIDDEN", "").split())
src = sys.argv[1]
if src == "-":
    raw = sys.stdin.read()
else:
    with open(src, encoding="utf-8") as f:
        raw = f.read()
try:
    data = json.loads(raw)
except Exception as e:
    print(f"invalid-json:{e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(data, dict):
    print("not-object", file=sys.stderr)
    sys.exit(2)
bad = []
for k in forbidden:
    if k in data:
        bad.append(k)
refs = data.get("refs")
if isinstance(refs, dict):
    for k in forbidden:
        if k in refs:
            bad.append(f"refs.{k}")
for k in bad:
    print(k)
sys.exit(1 if bad else 0)
PY
}

# Emit one evidence JSON object. Never includes outcome/attained.
# Args (flags):
#   --id --dispatch-id --goal --surface --result --summary [--task-id] [--adapter firstmate]
#   [--refs-json '{}'] [--ts EPOCH]
fm_kuru_make_evidence() {
  local evidence_id="" dispatch_id="" goal="" surface="" result="" summary=""
  local task_id="" adapter="firstmate" refs_json="{}" ts=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) shift; evidence_id=${1:-} ;;
      --dispatch-id) shift; dispatch_id=${1:-} ;;
      --goal) shift; goal=${1:-} ;;
      --surface) shift; surface=${1:-} ;;
      --result) shift; result=${1:-} ;;
      --summary) shift; summary=${1:-} ;;
      --task-id) shift; task_id=${1:-} ;;
      --adapter) shift; adapter=${1:-} ;;
      --refs-json) shift; refs_json=${1:-} ;;
      --ts) shift; ts=${1:-} ;;
      *) printf 'fm_kuru_make_evidence: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done
  case "$surface" in
    task|pr|run|validator|log|other) ;;
    *) printf 'fm_kuru_make_evidence: bad surface %s\n' "$surface" >&2; return 2 ;;
  esac
  case "$result" in
    ok|failed|blocked|needs_decision|pending) ;;
    *) printf 'fm_kuru_make_evidence: bad result %s\n' "$result" >&2; return 2 ;;
  esac
  fm_kuru_slug_valid "$evidence_id" || { printf 'fm_kuru_make_evidence: bad evidence id\n' >&2; return 2; }
  fm_kuru_slug_valid "$dispatch_id" || { printf 'fm_kuru_make_evidence: bad dispatch id\n' >&2; return 2; }
  fm_kuru_slug_valid "$goal" || { printf 'fm_kuru_make_evidence: bad goal slug\n' >&2; return 2; }
  [ -n "$summary" ] || summary=""
  if [ -z "$ts" ]; then
    ts=$(date +%s 2>/dev/null || echo 0)
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 required for evidence JSON\n' >&2
    return 2
  fi
  EVIDENCE_ID=$evidence_id DISPATCH_ID=$dispatch_id GOAL=$goal SURFACE=$surface \
  RESULT=$result SUMMARY=$summary TASK_ID=$task_id ADAPTER=$adapter \
  REFS_JSON=$refs_json TS=$ts python3 <<'PY'
import json, os, sys
refs = json.loads(os.environ.get("REFS_JSON") or "{}")
if not isinstance(refs, dict):
    print("refs must be an object", file=sys.stderr)
    sys.exit(2)
task_id = os.environ.get("TASK_ID") or ""
if task_id:
    refs = dict(refs)
    refs.setdefault("task_id", task_id)
# Explicitly mark evidence-only; never set outcome.
refs = dict(refs)
refs["evidence_only"] = True
forbidden = {
    "outcome", "attained", "criterion_outcome", "goal_outcome",
    "chosen_model", "chosen_harness", "route", "routing", "profile_choice",
}
for k in forbidden:
    if k in refs:
        print(f"refs must not carry {k!r}", file=sys.stderr)
        sys.exit(2)
ev = {
    "type": "evidence",
    "id": os.environ["EVIDENCE_ID"],
    "dispatch_id": os.environ["DISPATCH_ID"],
    "goal_slug": os.environ["GOAL"],
    "organ": "orchestration",
    "adapter": os.environ.get("ADAPTER") or "firstmate",
    "surface": os.environ["SURFACE"],
    "result": os.environ["RESULT"],
    "summary": os.environ.get("SUMMARY") or "",
    "refs": refs,
    "ts": float(os.environ.get("TS") or 0),
}
for k in forbidden:
    if k in ev:
        print(f"evidence must not carry {k!r}", file=sys.stderr)
        sys.exit(2)
json.dump(ev, sys.stdout, sort_keys=True)
sys.stdout.write("\n")
PY
}

# Minimal dispatch validation for the organ boundary (type/organ/status/no outcome).
# Accepts a path or "-" for stdin. Prints error on stderr; rc 0 = ok.
fm_kuru_validate_dispatch_json() {
  local src=$1
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 required for dispatch validation\n' >&2
    return 2
  fi
  python3 - "$src" <<'PY'
import json, re, sys
src = sys.argv[1]
raw = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
try:
    d = json.loads(raw)
except Exception as e:
    print(f"dispatch: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(d, dict):
    print("dispatch must be an object", file=sys.stderr)
    sys.exit(1)
if d.get("type") != "dispatch":
    print("dispatch.type must be 'dispatch'", file=sys.stderr)
    sys.exit(1)
slug_re = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
for field in ("id", "goal_slug"):
    v = d.get(field)
    if not isinstance(v, str) or not slug_re.match(v):
        print(f"dispatch.{field} must be a portable slug", file=sys.stderr)
        sys.exit(1)
if d.get("organ") != "orchestration":
    print("dispatch.organ must be 'orchestration'", file=sys.stderr)
    sys.exit(1)
statuses = {"queued", "running", "blocked", "needs_decision", "done", "failed", "cancelled"}
if d.get("status") not in statuses:
    print("dispatch.status invalid", file=sys.stderr)
    sys.exit(1)
if "outcome" in d or d.get("attained") is True:
    print("dispatch must not carry outcome authority", file=sys.stderr)
    sys.exit(1)
for k in ("chosen_model", "chosen_harness", "route_decision"):
    if k in d:
        print(f"dispatch must not carry organ route key {k!r}", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
}
