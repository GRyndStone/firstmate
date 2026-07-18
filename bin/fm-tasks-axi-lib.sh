# shellcheck shell=bash
# Shared tasks-axi backend selection, compatibility probe, durable mutation
# ownership, and lifecycle receipt invalidation.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` suppresses the tasks-axi availability notice;
# every mutation still uses the serialized home-scoped wrapper.

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

fm_tasks_axi_mutation_pid_identity() {  # <pid>
  local identity
  identity=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) || return 1
  identity=$(printf '%s\n' "$identity" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

fm_tasks_axi_mutation_owner_token() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
  case "$token" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s\n' "$token" ;;
    *) return 1 ;;
  esac
}

fm_tasks_axi_mutation_owner_state() {  # <state-dir>
  local state=$1 owner record pid identity token current_identity process_state
  owner="$state/.backlog-mutation-owner"
  if [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    return 1
  fi
  [ -d "$owner" ] && [ ! -L "$owner" ] || return 2
  record="$owner/record"
  [ -f "$record" ] && [ ! -L "$record" ] || return 2
  [ -z "$(find "$owner" -mindepth 1 -maxdepth 1 ! -name record ! -name start -print -quit 2>/dev/null)" ] || return 2
  [ ! -e "$owner/start" ] || { [ -f "$owner/start" ] && [ ! -L "$owner/start" ] && [ ! -s "$owner/start" ]; } || return 2
  [ "$(sed -n '1p' "$record")" = version=1 ] || return 2
  pid=$(sed -n 's/^pid=//p' "$record") || return 2
  identity=$(sed -n 's/^identity=//p' "$record") || return 2
  token=$(sed -n 's/^token=//p' "$record") || return 2
  [ -z "$(sed -n '5p' "$record")" ] || return 2
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  case "$token" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 2 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  process_state=$(ps -p "$pid" -o stat= 2>/dev/null) || return 2
  read -r process_state _ <<< "$process_state"
  case "$process_state" in Z*) return 1 ;; '') return 2 ;; esac
  current_identity=$(fm_tasks_axi_mutation_pid_identity "$pid") || return 2
  [ "$current_identity" = "$identity" ] || return 1
  return 0
}

fm_tasks_axi_reconcile_mutation_owner() {  # <state-dir>
  local state=$1 owner status=0
  owner="$state/.backlog-mutation-owner"
  fm_tasks_axi_mutation_owner_state "$state" || status=$?
  case "$status" in
    0|2) return 1 ;;
    1)
      [ -e "$owner" ] || [ -L "$owner" ] || return 0
      [ -d "$owner" ] && [ ! -L "$owner" ] || return 1
      rm -f "$owner/start" "$owner/record" || return 1
      rmdir "$owner"
      ;;
  esac
}

fm_tasks_axi_publish_mutation_owner() {  # <state-dir> <pid> <identity> <token>
  local state=$1 pid=$2 identity=$3 token=$4 owner temporary
  owner="$state/.backlog-mutation-owner"
  [ ! -e "$owner" ] && [ ! -L "$owner" ] || return 1
  temporary=$(mktemp -d "$state/.backlog-mutation-owner.tmp.XXXXXXXX") || return 1
  if ! {
    printf 'version=1\n'
    printf 'pid=%s\n' "$pid"
    printf 'identity=%s\n' "$identity"
    printf 'token=%s\n' "$token"
  } > "$temporary/record" || ! mv "$temporary" "$owner"; then
    rm -f "$temporary/record" 2>/dev/null || true
    rmdir "$temporary" 2>/dev/null || true
    return 1
  fi
}

fm_tasks_axi_start_mutation_owner() {  # <state-dir> <token>
  local state=$1 token=$2 owner recorded
  owner="$state/.backlog-mutation-owner"
  [ -d "$owner" ] && [ ! -L "$owner" ] || return 1
  recorded=$(sed -n 's/^token=//p' "$owner/record" 2>/dev/null) || return 1
  [ "$recorded" = "$token" ] || return 1
  (umask 077 && : > "$owner/start")
}

fm_tasks_axi_clear_mutation_owner() {  # <state-dir> <token>
  local state=$1 token=$2 owner recorded
  owner="$state/.backlog-mutation-owner"
  [ -d "$owner" ] && [ ! -L "$owner" ] || return 1
  recorded=$(sed -n 's/^token=//p' "$owner/record" 2>/dev/null) || return 1
  [ "$recorded" = "$token" ] || return 1
  rm -f "$owner/start" "$owner/record" || return 1
  rmdir "$owner"
}

fm_tasks_axi_mutation_owner_start_path() {  # <state-dir>
  printf '%s/.backlog-mutation-owner/start\n' "$1"
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
  if [ -e "$claim/done-ack" ] || [ -L "$claim/done-ack" ]; then
    rm -f "$claim/done-ack" || return 1
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
