#!/usr/bin/env bash
# Shared exact-path proof for a worktree released back to Treehouse's reusable
# pool. `treehouse return --force` intentionally keeps the git worktree and
# directory registered, so path absence alone is not a valid completion test.

fm_treehouse_normalize_system_alias() {  # <absolute-path>
  local path=$1 alias_root
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in
    /var|/var/*)
      alias_root=$(cd /var 2>/dev/null && pwd -P) || return 1
      [ "$alias_root" != /private/var ] || path="/private$path"
      ;;
    /tmp|/tmp/*)
      alias_root=$(cd /tmp 2>/dev/null && pwd -P) || return 1
      [ "$alias_root" != /private/tmp ] || path="/private$path"
      ;;
  esac
  printf '%s\n' "$path"
}

fm_treehouse_worktree_available_for_project() {  # <project> <worktree>
  local project=$1 target=$2 abs_target status line availability path path_abs
  target=$(fm_treehouse_normalize_system_alias "$target") || return 1
  [ ! -L "$target" ] || return 1
  [ -d "$project" ] && [ -d "$target" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  abs_target=$(cd "$target" 2>/dev/null && pwd -P) || return 1
  status=$( ( cd "$project" && treehouse status ) 2>/dev/null) || return 1
  while IFS= read -r line; do
    read -r _ availability path <<EOF
$line
EOF
    [ "$availability" = available ] && [ -n "$path" ] || continue
    case "$path" in
      \~/*) [ -n "${HOME:-}" ] || continue; path="${HOME}/${path#\~/}" ;;
    esac
    path=$(fm_treehouse_normalize_system_alias "$path") || continue
    [ ! -L "$path" ] || continue
    path_abs=$(cd "$path" 2>/dev/null && pwd -P) || continue
    [ "$path_abs" = "$abs_target" ] && return 0
  done <<EOF
$status
EOF
  return 1
}
