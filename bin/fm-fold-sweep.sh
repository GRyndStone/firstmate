#!/usr/bin/env bash
# fm-fold-sweep.sh - enumerate every firstmate surface that reaches a folded
# tool's upstream name.
#
# A rename that misses one surface leaves a silent dependency exactly where
# nobody looks, so this sweep is enumerated per surface class rather than being
# one repo-wide grep: each class is listed by name and reported on even when it
# is clean, so a class that was never checked is visible as a missing row rather
# than as silence.
#
# It separates two very different things:
#
#   INVOCATION - the upstream name in command position: firstmate would actually
#                execute the upstream tool. This is the dependency. Once a fold
#                is adopted, invocations must be zero.
#   REFERENCE  - the upstream name in prose, a comment, a manifest, or a test
#                fixture. Naming upstream is legitimate and necessary: the fold
#                manifests, this sweep, and docs/folding-tools.md all must say
#                which upstream they replace. References are counted, not failed.
#
# Sites that must keep an invocation for a stated reason are allowlisted in
# vendor/sweep-allow.txt, one "<path>  <reason>" per line. An allowlisted site
# is reported as ALLOWED so it stays visible instead of disappearing.
#
# Usage:
#   fm-fold-sweep.sh                 sweep every declared fold
#   fm-fold-sweep.sh <fold>...       sweep only the named folds
#   fm-fold-sweep.sh --strict        exit 1 if any un-allowlisted invocation remains
#
# Exit status is 0 unless --strict is set and an un-allowlisted invocation was
# found, so the sweep is readable during a migration and enforceable after it.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-fold-lib.sh disable=SC1091
. "$ROOT/bin/fm-fold-lib.sh"
cd "$ROOT"

STRICT=0
FOLDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'fm-fold-sweep: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) FOLDS+=("$1"); shift ;;
  esac
done
if [ "${#FOLDS[@]}" -eq 0 ]; then
  while IFS= read -r id; do [ -n "$id" ] && FOLDS+=("$id"); done < <(fm_fold_ids)
fi

ALLOW_FILE="$ROOT/vendor/sweep-allow.txt"

# The enumerated surface classes, each tagged with how an upstream name there
# reaches the tool. Adding a new kind of surface to the repo means adding a row
# here; tests/fm-fold-sweep.test.sh asserts the list covers the repo.
#
#   exec      - firstmate executes it. ANY occurrence of the bare upstream name
#               counts as reach, because the classifier cannot prove which code
#               path resolves it: the real quota-axi call site is an indirect
#               ${FM_DISPATCH_QUOTA_AXI:-quota-axi} default, which command-
#               position matching misses entirely.
#   directive - an agent reads it and then runs the tool. "Use gh-axi for all
#               GitHub operations" is reach even though no shell executes it.
#   prose     - documentation, tests, and the fold manifests. Naming upstream
#               here is legitimate and required; counted, never failed.
surface_classes() {
  printf '%s\t%s\t%s\n' \
    instructions directive 'AGENTS.md' \
    scripts exec 'bin' \
    hooks exec 'bin/backends' \
    briefs directive 'bin/fm-brief.sh' \
    skills directive '.agents/skills' \
    ci exec '.github/workflows' \
    config exec '.tasks.toml .no-mistakes.yaml' \
    docs prose 'docs README.md CONTRIBUTING.md' \
    tests prose 'tests' \
    vendor prose 'vendor'
}

# Files in a surface class that exist and are tracked.
class_files() { # <paths...>
  local p
  for p in $1; do
    [ -e "$p" ] || continue
    if [ -d "$p" ]; then
      find "$p" -type f ! -path '*/.git/*' 2>/dev/null
    else
      printf '%s\n' "$p"
    fi
  done
}

allow_reason_text() { # <path>
  [ -f "$ALLOW_FILE" ] || return 1
  awk -v want="$1" '
    /^[[:space:]]*#/ || NF == 0 { next }
    { path = $1; $1 = ""; sub(/^[[:space:]]+/, ""); if (path == want) { print; exit } }
  ' "$ALLOW_FILE"
}

allow_reason() { # <path>
  [ -n "$(allow_reason_text "$1" 2>/dev/null)" ]
}

# The bare upstream name, not a substring of a longer token. `quota-axi` must
# not match `gs-quota-axi-thing`, and `treehouse` must not match `.treehouse`
# (the worktree POOL PATH, which the fold does not rename: the pool directory is
# owned by treehouse.toml config, not by the command name).
bare_name_re() { # <name>
  printf '(^|[^-._[:alnum:]/])%s([^-._[:alnum:]]|$)' "$1"
}

total_reach=0
total_allowed=0

for fold in "${FOLDS[@]}"; do
  if ! fm_fold_known "$fold"; then
    printf 'fm-fold-sweep: unknown fold %s\n' "$fold" >&2
    exit 66
  fi
  upstream=$(fm_fold_upstream_command "$fold")
  ours=$(fm_fold_command "$fold")
  printf '\n=== fold %s: %s -> %s ===\n' "$fold" "$upstream" "$ours"
  printf '%-14s %-10s %-7s %-6s %s\n' SURFACE KIND REACH PROSE FILES

  while IFS=$'\t' read -r class kind paths; do
    [ -n "$class" ] || continue
    reach=0; refs=0; files=0; hits=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      grep -Iq . "$f" 2>/dev/null || continue
      grep -IEq -- "$(bare_name_re "$upstream")" "$f" 2>/dev/null || continue
      files=$((files + 1))
      case "$kind" in
        exec|directive)
          if allow_reason "$f"; then
            total_allowed=$((total_allowed + 1))
            hits="$hits\n    ALLOWED  $f  ($(allow_reason_text "$f"))"
          else
            reach=$((reach + 1))
            total_reach=$((total_reach + 1))
            hits="$hits\n    REACH    $f"
          fi
          ;;
        *)
          refs=$((refs + 1))
          hits="$hits\n    prose    $f"
          ;;
      esac
    done < <(class_files "$paths")
    printf '%-14s %-10s %-7s %-6s %s\n' "$class" "$kind" "$reach" "$refs" "$files"
    [ -n "$hits" ] && printf '%b\n' "$hits"
  done < <(surface_classes)
done

printf '\n---\nun-allowlisted reach sites: %s\nallowlisted reach sites:    %s\n' \
  "$total_reach" "$total_allowed"

if [ "$STRICT" -eq 1 ] && [ "$total_reach" -gt 0 ]; then
  printf 'fm-fold-sweep: %s surface(s) can still reach an upstream name\n' "$total_reach" >&2
  exit 1
fi
exit 0
