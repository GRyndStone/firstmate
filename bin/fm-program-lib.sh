# shellcheck shell=bash
# Shared discovery of convention-named durable program sources.
# The discovery is pointer-only: callers may report that a source exists, but
# only supervisor judgment may decide whether its prose obligations have all
# been materialized as backlog tasks.
# Usage: . bin/fm-program-lib.sh; fm_program_source_lines <data-dir>

fm_program_source_lines() {  # <data-dir>, prints <relative-path><TAB><absolute-path>
  local data=$1 source relative
  for source in "$data/program.md" "$data"/*-program.md "$data/programs"/*.md; do
    [ -f "$source" ] || continue
    relative=${source#"$data"/}
    printf '%s\t%s\n' "$relative" "$source"
  done | LC_ALL=C sort -u
}
