# shellcheck shell=bash
# Shared tasks-axi backend selection, compatibility probe, and lifecycle receipt
# invalidation for bootstrap, teardown, and backlog operations.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, while lifecycle show/Done and validated secondmate
# handoffs still use their serialized tasks-axi paths.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_tasks_axi_valid_task_id() {  # <id>
  case "${1:-}" in
    [A-Za-z0-9]*)
      case "$1" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

fm_tasks_axi_remove_completion_claim() {  # <claim-path>
  local claim=$1 proof
  if [ -L "$claim" ] || [ ! -d "$claim" ]; then
    rm -f "$claim"
    return $?
  fi
  proof="$claim/proof"
  if [ -e "$proof" ] || [ -L "$proof" ]; then
    rm -f "$proof" || return 1
  fi
  rmdir "$claim"
}

fm_tasks_axi_invalidate_completion_receipt() {  # <state-dir> <id>
  local state=$1 id=$2 claim status=0
  fm_tasks_axi_valid_task_id "$id" || return 1
  rm -f "$state/$id.teardown-complete" || status=1
  for claim in "$state"/."$id".teardown-complete.claimed.*; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    fm_tasks_axi_remove_completion_claim "$claim" || status=1
  done
  return "$status"
}

fm_tasks_axi_invalidate_all_completion_receipts() {  # <state-dir>
  local state=$1 receipt claim status=0
  for receipt in "$state"/*.teardown-complete; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    rm -f "$receipt" || status=1
  done
  for claim in "$state"/.*.teardown-complete.claimed.*; do
    [ -e "$claim" ] || [ -L "$claim" ] || continue
    fm_tasks_axi_remove_completion_claim "$claim" || status=1
  done
  return "$status"
}

fm_tasks_axi_task_fingerprint() {
  local normalized
  normalized=$(awk '
    $0 == "task:" {
      in_task = 1
      found_task = 1
      print
      next
    }
    in_task && /^[^[:space:]]/ { exit }
    in_task {
      if ($0 ~ /^  id:/)
        found_id = 1
      print
    }
    END {
      if (!found_task || !found_id)
        exit 1
    }
  ') || return 1
  [ -n "$normalized" ] || return 1
  printf '%s' "$normalized" | cksum | awk '{print $1 ":" $2}'
}

fm_firstmate_scout_report_path() {  # <firstmate-home> <task-id>
  local home=$1 id=$2 data_dir data_root task_dir task_root report report_parent
  fm_tasks_axi_valid_task_id "$id" || return 1
  home=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  data_dir="$home/data"
  [ -d "$data_dir" ] || return 1
  data_root=$(cd "$data_dir" 2>/dev/null && pwd -P) || return 1
  case "$data_root" in
    "$home"|"$home"/*) ;;
    *) return 1 ;;
  esac
  task_dir="$data_dir/$id"
  [ -d "$task_dir" ] || return 1
  task_root=$(cd "$task_dir" 2>/dev/null && pwd -P) || return 1
  [ "$task_root" = "$data_root/$id" ] || return 1
  report="$task_dir/report.md"
  [ ! -L "$report" ] && [ -f "$report" ] || return 1
  report_parent=$(cd "$(dirname "$report")" 2>/dev/null && pwd -P) || return 1
  [ "$report_parent" = "$task_root" ] || return 1
  printf '%s/report.md\n' "$report_parent"
}

fm_tasks_axi_markdown_archive() {  # <config>
  local config=$1 parsed count valid rest value
  parsed=$(awk '
    {
      stripped = ""
      in_quote = ""
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (char == "\"" || char == "\047") {
          if (in_quote == "")
            in_quote = char
          else if (in_quote == char)
            in_quote = ""
        }
        if (char == "#" && in_quote == "")
          break
        stripped = stripped char
      }
      line = stripped
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      if (line ~ /^\[[^]]+\]$/) {
        section = line
        sub(/^\[/, "", section)
        sub(/\]$/, "", section)
        sub(/^[[:space:]]*/, "", section)
        sub(/[[:space:]]*$/, "", section)
        in_markdown = (section == "markdown")
        next
      }
      if (!in_markdown || line !~ /^archive[[:space:]]*=/)
        next
      count++
      rhs = line
      sub(/^archive[[:space:]]*=[[:space:]]*/, "", rhs)
      quote = substr(rhs, 1, 1)
      if (length(rhs) < 2 || (quote != "\"" && quote != "\047") || substr(rhs, length(rhs), 1) != quote)
        next
      value = substr(rhs, 2, length(rhs) - 2)
      nonblank = value
      sub(/^[[:space:]]*/, "", nonblank)
      sub(/[[:space:]]*$/, "", nonblank)
      if (nonblank == "")
        next
      valid++
      last = value
    }
    END { printf "%d\t%d\t%s", count, valid, last }
  ' "$config") || return 1
  count=${parsed%%$'\t'*}
  rest=${parsed#*$'\t'}
  valid=${rest%%$'\t'*}
  value=${rest#*$'\t'}
  if [ "$count" -ne 1 ]; then
    echo "error: $config must declare markdown.archive exactly once (found $count)" >&2
    return 1
  fi
  if [ "$valid" -ne 1 ] || [ -z "$value" ]; then
    echo "error: $config markdown.archive must be one non-empty single- or double-quoted string" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
