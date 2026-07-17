# shellcheck shell=bash
# Shared discovery of convention-named durable program sources.
# The discovery is pointer-only: callers may report that a source exists, but
# only supervisor judgment may decide whether its prose obligations have all
# been materialized as backlog tasks.
# Usage: . bin/fm-program-lib.sh; fm_program_source_lines <data-dir> <home-dir>

fm_program_source_lines() {  # <data-dir> <home-dir>, prints <relative-path><TAB><absolute-path>
  local data=$1 home=${2:-${FM_HOME:-$(dirname "$1")}} data_real home_real source source_real parent relative
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || return 0
  data_real=$(cd "$data" 2>/dev/null && pwd -P) || return 0
  case "$data_real" in
    "$home_real"|"$home_real"/*) ;;
    *) return 0 ;;
  esac
  {
    printf '%s\n' "$data/program.md"
    printf '%s\n' "$data"/*-program.md
    if [ ! -L "$data/programs" ]; then
      printf '%s\n' "$data/programs"/*.md
    fi
  } | while IFS= read -r source; do
    [ -f "$source" ] || continue
    [ ! -L "$source" ] || continue
    parent=$(cd "$(dirname "$source")" 2>/dev/null && pwd -P) || continue
    source_real="$parent/$(basename "$source")"
    case "$source_real" in
      "$home_real"/*) ;;
      *) continue ;;
    esac
    relative=${source#"$data"/}
    printf '%s\t%s\n' "$relative" "$source"
  done | LC_ALL=C sort -u
}
