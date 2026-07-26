#!/usr/bin/env bash
# fm-fold-divergence.sh - report how a fold differs from its upstream, derived
# from the repositories rather than from prose.
#
# Breaking from upstream is a decision to OWN the code, not to stop learning
# from it: these projects ship near-daily, and a fold that stops reading
# upstream turns a deliberate position into drift. So this report is generated
# from git on demand, never hand-maintained. The GRyndStone/no-mistakes
# precedent keeps its equivalent as a prose "customization ledger" in
# PRIVATE_FIRSTMATE.md; that ledger is only as current as the last person who
# remembered to edit it. This is the same idea made regenerable.
#
# It answers three questions per fold:
#   CARRIED  - what we have that upstream does not (our diff from the base)
#   AVAILABLE- what upstream has landed since our base commit
#   DECLINED - which of those we have deliberately not taken, and why
#
# An upstream commit that is neither taken nor declined shows up as UNTRIAGED,
# which is the actionable output: it is the list a human must rule on.
#
# Usage:
#   fm-fold-divergence.sh <fold> [--ours <checkout>] [--upstream <checkout>]
#   fm-fold-divergence.sh --all [--fetch]
#
#   --ours      checkout holding our folded source (defaults to the seed tree)
#   --upstream  checkout of upstream (defaults to a cached clone under
#               ${FM_FOLD_CACHE:-$TMPDIR/fm-fold-cache})
#   --fetch     update the upstream cache before reporting (network)
#
# Output is Markdown on stdout so it can be pasted into a PR or written to a
# file; nothing is written to the repo, so the report can never go stale in
# tree.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-fold-lib.sh disable=SC1091
. "$ROOT/bin/fm-fold-lib.sh"

CACHE=${FM_FOLD_CACHE:-${TMPDIR:-/tmp}/fm-fold-cache}
FETCH=0
OURS=""
UPSTREAM=""
ALL=0
FOLDS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --fetch) FETCH=1; shift ;;
    --ours) OURS=$2; shift 2 ;;
    --ours=*) OURS=${1#--ours=}; shift ;;
    --upstream) UPSTREAM=$2; shift 2 ;;
    --upstream=*) UPSTREAM=${1#--upstream=}; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'fm-fold-divergence: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) FOLDS+=("$1"); shift ;;
  esac
done

if [ "$ALL" -eq 1 ] || [ "${#FOLDS[@]}" -eq 0 ]; then
  FOLDS=()
  while IFS= read -r id; do [ -n "$id" ] && FOLDS+=("$id"); done < <(fm_fold_ids)
fi

command -v jq >/dev/null 2>&1 || { printf 'fm-fold-divergence: jq required\n' >&2; exit 127; }

# A cached read-only clone of upstream. Fetch is read-only and submits nothing,
# which is the only upstream interaction a folded tool is permitted.
upstream_checkout() { # <fold>
  local id=$1 url dir
  [ -n "$UPSTREAM" ] && { printf '%s\n' "$UPSTREAM"; return 0; }
  url=$(fm_fold_field "$id" upstream.url) || return 1
  dir="$CACHE/$id"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$CACHE"
    git clone --quiet "$url" "$dir" >/dev/null 2>&1 || return 1
  elif [ "$FETCH" -eq 1 ]; then
    git -C "$dir" fetch --quiet --tags --prune origin >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$dir"
}

# Backticks in the printf formats below are Markdown code spans in the generated
# report, not command substitution, so single quotes are exactly right here.
# shellcheck disable=SC2016
report_fold() { # <fold>
  local id=$1 base repo ours_repo up head declined_json carried n
  base=$(fm_fold_field "$id" upstream.baseCommit) || base=""
  repo=$(fm_fold_field "$id" upstream.repo) || repo="?"
  ours_repo=$(fm_fold_field "$id" ours.repo) || ours_repo="?"

  printf '## %s\n\n' "$id"
  printf -- '- upstream: `%s`\n' "$repo"
  printf -- '- ours: `%s` (%s)\n' "$ours_repo" "$(fm_fold_field "$id" ours.status 2>/dev/null || echo '?')"
  printf -- '- base: `%s` (`%s`)\n\n' "$(fm_fold_field "$id" upstream.baseTag 2>/dev/null || echo '?')" "$base"

  if ! up=$(upstream_checkout "$id") || [ ! -d "$up/.git" ]; then
    printf '> upstream checkout unavailable; re-run with network or pass --upstream <checkout>\n\n'
    return 0
  fi
  if ! git -C "$up" cat-file -e "$base^{commit}" 2>/dev/null; then
    printf '> base commit `%s` not present in the upstream checkout; re-run with --fetch\n\n' "$base"
    return 0
  fi
  head=$(git -C "$up" rev-parse --verify --quiet origin/HEAD 2>/dev/null) ||
    head=$(git -C "$up" rev-parse --verify --quiet origin/main 2>/dev/null) || head=""
  [ -n "$head" ] || { printf '> cannot resolve upstream head\n\n'; return 0; }

  # CARRIED: our source delta from the base, when our checkout is available.
  printf '### Carried (ours, not upstream)\n\n'
  if [ -n "$OURS" ] && [ -d "$OURS/.git" ]; then
    carried=$(git -C "$OURS" diff --stat "$base"..HEAD 2>/dev/null | tail -20)
    if [ -n "$carried" ]; then printf '```\n%s\n```\n\n' "$carried"; else printf 'No source delta from base.\n\n'; fi
  else
    # No checkout supplied: fall back to the manifest's declared carried fixes,
    # which are the reviewed statement of intent rather than a computed diff.
    n=$(jq -r '(.carriedFixes // []) | length' "$(fm_fold_manifest_path "$id")")
    if [ "$n" -gt 0 ]; then
      jq -r '(.carriedFixes // [])[] | "- **\(.id)** - \(.summary)\n  - upstream: \(.upstreamState)\n  - why: \(.whyItMatters)"' \
        "$(fm_fold_manifest_path "$id")"
      printf '\n_declared in vendor/%s/fold.json; pass --ours <checkout> for the computed diff_\n\n' "$id"
    else
      printf 'None declared.\n\n'
    fi
  fi

  # AVAILABLE / DECLINED / UNTRIAGED, all computed from upstream history.
  declined_json=$(jq -c '(.declined // [])' "$(fm_fold_manifest_path "$id")")
  printf '### Upstream since base\n\n'
  local total=0 dec=0 untriaged=0 line sha subject reason
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha=${line%% *}
    subject=${line#* }
    total=$((total + 1))
    # Bind .commit before piping: inside `$s | startswith(.commit)` jq rebinds
    # `.` to the string $s, so `.commit` would index a string and error out.
    reason=$(printf '%s' "$declined_json" | jq -r --arg s "$sha" \
      '.[] | select(.commit != null) | .commit as $c | select($s | startswith($c)) | .why' 2>/dev/null | head -1)
    if [ -n "$reason" ]; then
      dec=$((dec + 1))
      printf -- '- DECLINED `%s` %s\n  - why: %s\n' "${sha:0:9}" "$subject" "$reason"
    else
      untriaged=$((untriaged + 1))
      printf -- '- UNTRIAGED `%s` %s\n' "${sha:0:9}" "$subject"
    fi
  done < <(git -C "$up" log --no-merges --format='%H %s' "$base..$head" 2>/dev/null)

  printf '\n**%s upstream commits since base: %s declined, %s untriaged.**\n' "$total" "$dec" "$untriaged"
  [ "$untriaged" -gt 0 ] && printf '\nUntriaged commits are the actionable list: each needs a take-or-decline ruling recorded in `vendor/%s/fold.json` `declined[]`.\n' "$id"
  printf '\n'
}

printf '# Fold divergence report\n\n'
# Markdown code span, not command substitution.
# shellcheck disable=SC2016
printf 'Generated by `bin/fm-fold-divergence.sh` from git history; do not hand-edit.\n\n'
for f in "${FOLDS[@]}"; do
  fm_fold_known "$f" || { printf 'fm-fold-divergence: unknown fold %s\n' "$f" >&2; exit 66; }
  report_fold "$f"
done
