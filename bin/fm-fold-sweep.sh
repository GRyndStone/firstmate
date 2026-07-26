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
#   fm-fold-sweep.sh --strict        exit 1 if any un-allowlisted reach site remains
#   fm-fold-sweep.sh --coverage      exit 1 if any tracked file is neither swept
#                                    nor declared excluded (enumeration completeness)
#
# Exit status is 0 unless --strict is set and an un-allowlisted invocation was
# found, so the sweep is readable during a migration and enforceable after it.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-fold-lib.sh disable=SC1091
. "$ROOT/bin/fm-fold-lib.sh"
cd "$ROOT"

STRICT=0
COVERAGE=0
FOLDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --coverage) COVERAGE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# here, and tests/fm-fold-sweep.test.sh fails if the list stops covering every
# tracked file. That test was written only after this comment was found claiming
# a coverage guarantee that did not exist while five hook directories and the
# public skills/ tree went unswept.
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
    instructions directive 'AGENTS.md CLAUDE.md' \
    scripts exec 'bin' \
    backends exec 'bin/backends' \
    hooks exec '.claude .codex .grok .opencode .pi' \
    briefs directive 'bin/fm-brief.sh' \
    skills directive '.agents/skills' \
    public-skills directive 'skills' \
    ci exec '.github' \
    config exec '.tasks.toml .no-mistakes.yaml .gitignore' \
    deps exec 'deps' \
    docs prose 'docs README.md CONTRIBUTING.md' \
    tests prose 'tests' \
    vendor prose 'vendor absorb'
}

# Tracked paths deliberately NOT swept, each with a reason. The amended AC-2
# requires naming exclusions rather than letting them vanish, so this list is
# printed by --coverage and asserted by tests/fm-fold-sweep.test.sh.
surface_exclusions() {
  printf '%s\t%s\n' \
    'LICENSE' 'legal text; cannot contain a tool invocation' \
    'assets/banner.png' 'binary image; not text-searchable'
}

# Files in a surface class. Symlinks are included deliberately: CLAUDE.md and
# .claude/skills are tracked symlinks, and `find -type f` skips them, which would
# silently drop two directive surfaces from the enumeration.
class_files() { # <space-separated paths>
  local p
  # shellcheck disable=SC2086 # deliberate word-split: the field holds several paths
  for p in $1; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    if [ -d "$p" ] && [ ! -L "$p" ]; then
      find "$p" \( -type f -o -type l \) ! -path '*/.git/*' 2>/dev/null
    else
      printf '%s\n' "$p"
    fi
  done
}

# Every tracked file reached by some declared surface class, normalised.
covered_tracked_files() {
  local class kind paths
  while IFS=$'\t' read -r class kind paths; do
    [ -n "$class" ] || continue
    class_files "$paths"
  done < <(surface_classes) | sed 's|^\./||' | sort -u
}

# Completeness gate. The amended AC-2 makes an under-counting sweep an outright
# failure, so completeness must be verifiable rather than asserted in a comment.
# Prints any tracked file that no surface class reaches and that is not named in
# surface_exclusions; exits 1 when any exist.
cmd_coverage() {
  local tracked covered excluded unexplained
  tracked=$(git ls-files | sort)
  covered=$(covered_tracked_files)
  excluded=$(surface_exclusions | cut -f1 | sort)

  printf 'tracked files:   %s\n' "$(printf '%s\n' "$tracked" | grep -c .)"
  printf 'reached by class: %s\n' "$(comm -12 <(printf '%s\n' "$tracked") <(printf '%s\n' "$covered") | grep -c .)"
  printf 'declared exclusions:\n'
  surface_exclusions | while IFS=$'\t' read -r path why; do
    printf '  %-20s %s\n' "$path" "$why"
  done

  unexplained=$(comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$covered") |
    comm -23 - <(printf '%s\n' "$excluded"))
  if [ -n "$unexplained" ]; then
    printf '\nUNCOVERED tracked files (neither swept nor declared excluded):\n'
    printf '%s\n' "$unexplained" | sed 's/^/  /'
    printf 'fm-fold-sweep: enumeration is incomplete; add a surface class or an exclusion\n' >&2
    return 1
  fi
  printf '\nenumeration complete: every tracked file is swept or explicitly excluded\n'
  return 0
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

if [ "$COVERAGE" -eq 1 ]; then
  cmd_coverage
  exit $?
fi

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
