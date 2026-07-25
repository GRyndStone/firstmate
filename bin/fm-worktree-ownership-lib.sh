#!/usr/bin/env bash
# Shared checks that a task meta's recorded worktree is the task's own worktree.
# A recorded worktree is trusted only when it matches the treehouse lease holder
# for this task generation, or it is the git worktree that holds branch fm/<id>.
# Return codes from fm_worktree_validate_task_ownership:
#   0 owned/safe
#   1 proved not-owned; stdout names the mismatch
#   2 indeterminate because the recorded worktree is absent and no other
#     ownership proof found the task branch or holder elsewhere

fm_worktree_meta_get() {  # <meta> <key>
  if command -v fm_meta_get >/dev/null 2>&1; then
    fm_meta_get "$1" "$2"
  else
    [ -f "$1" ] || return 0
    grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
  fi
}

fm_worktree_abs_dir() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  [ -d "$path" ] || return 1
  ( cd "$path" && pwd -P )
}

fm_worktree_expected_branch() {  # <task-id>
  printf 'fm/%s' "$1"
}

fm_worktree_holder_for_meta() {  # <task-id> <meta>
  local id=$1 meta=$2 generation
  generation=$(fm_worktree_meta_get "$meta" generation)
  [ -n "$generation" ] || return 1
  printf '%s-%s' "$id" "$generation"
}

fm_worktree_branch_paths() {  # <project> <branch>
  local project=$1 branch=$2 raw path real
  [ -n "$project" ] && [ -n "$branch" ] || return 2
  raw=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null \
    | awk -v want="refs/heads/$branch" '
        /^worktree / { if (path != "" && branch == want) print path; path=substr($0, 10); branch="" }
        /^branch / { branch=substr($0, 8) }
        /^$/ { if (path != "" && branch == want) print path; path=""; branch="" }
        END { if (path != "" && branch == want) print path }
      ') || return 2
  [ -n "$raw" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if real=$(fm_worktree_abs_dir "$path"); then
      printf '%s\n' "$real"
    else
      printf '%s\n' "$path"
    fi
  done <<EOF
$raw
EOF
}

fm_worktree_path_in_list() {  # <path> <newline-list>
  local needle=$1 list=$2 line
  [ -n "$needle" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

fm_worktree_join_paths() {  # <newline-list>
  awk 'NF { if (out != "") out = out ", "; out = out $0 } END { print out }'
}

fm_worktree_treehouse_holder_path() {  # <project> <holder>
  local project=$1 holder=$2 path real
  [ -n "$project" ] && [ -n "$holder" ] || return 2
  command -v fm_backend_treehouse_lease_path >/dev/null 2>&1 || return 2
  path=$(fm_backend_treehouse_lease_path "$project" "$holder" 2>/dev/null) || return $?
  if real=$(fm_worktree_abs_dir "$path"); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

fm_worktree_validate_task_ownership() {  # <task-id> <meta> [audit|strict]
  local id=$1 meta=$2 mode=${3:-audit}
  local kind backend project recorded expected_branch recorded_real holder holder_path
  local holder_matches=0
  local branch_paths branch_paths_rc branch_at_record joined
  kind=$(fm_worktree_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" != secondmate ] || return 0
  backend=$(fm_worktree_meta_get "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  [ "$backend" != orca ] || return 0

  project=$(fm_worktree_meta_get "$meta" project)
  recorded=$(fm_worktree_meta_get "$meta" worktree)
  expected_branch=$(fm_worktree_expected_branch "$id")
  recorded_real=
  if [ -n "$recorded" ]; then
    recorded_real=$(fm_worktree_abs_dir "$recorded" 2>/dev/null || true)
    [ -n "$recorded_real" ] || recorded_real=$recorded
  fi

  if holder=$(fm_worktree_holder_for_meta "$id" "$meta" 2>/dev/null); then
    holder_path=$(fm_worktree_treehouse_holder_path "$project" "$holder" 2>/dev/null || true)
    if [ -n "$holder_path" ] && [ "$recorded_real" != "$holder_path" ]; then
      printf 'MISMATCH: task %s recorded worktree %s, but treehouse holder %s leases %s.\n' \
        "$id" "${recorded_real:-<missing>}" "$holder" "$holder_path"
      return 1
    fi
    [ -z "$holder_path" ] || holder_matches=1
  fi

  branch_paths=
  branch_paths_rc=0
  branch_paths=$(fm_worktree_branch_paths "$project" "$expected_branch" 2>/dev/null) || branch_paths_rc=$?
  if [ "$branch_paths_rc" -eq 0 ] && [ -n "$branch_paths" ]; then
    if ! fm_worktree_path_in_list "$recorded_real" "$branch_paths"; then
      joined=$(printf '%s\n' "$branch_paths" | fm_worktree_join_paths)
      printf 'MISMATCH: task %s recorded worktree %s does not hold branch %s; branch is checked out at %s.\n' \
        "$id" "${recorded_real:-<missing>}" "$expected_branch" "$joined"
      return 1
    fi
    return 0
  fi

  [ "$holder_matches" -eq 0 ] || return 0
  [ "$mode" = strict ] || return 0
  if [ -z "$recorded" ] || [ ! -d "$recorded" ]; then
    return 2
  fi
  branch_at_record=$(git -C "$recorded" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ "$branch_at_record" != "$expected_branch" ]; then
    printf 'MISMATCH: task %s recorded worktree %s is on branch %s, not expected branch %s.\n' \
      "$id" "$recorded_real" "${branch_at_record:-<unknown>}" "$expected_branch"
    return 1
  fi
  return 0
}
