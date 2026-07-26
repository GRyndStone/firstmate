#!/usr/bin/env bash
# fm-fold.sh - build, install, and verify folded tools.
#
# A folded tool is a third-party dependency brought under the captain's own
# control. docs/folding-tools.md owns the procedure and the reasoning; this
# script owns the mechanics. vendor/<fold>/fold.json owns each fold's identity.
#
# Usage:
#   fm-fold.sh list                                  declared folds and install state
#   fm-fold.sh build <fold> --source <checkout> [--out <dir>]
#                                                    build our artifact from a source tree
#   fm-fold.sh install <fold> --artifact <path>      install it and record its identity
#   fm-fold.sh identity <fold>                       print the installed fold's identity
#   fm-fold.sh verify <fold>                         assert the installed artifact is still ours
#
# WHY IDENTITY IS NOT A VERSION STRING
# A quota-axi built locally from the unmerged fix branch reports version
# "0.1.13" - byte-for-byte the same string the published npm release reports -
# while carrying different code. Any check that compares version strings calls
# that install current. So `install` records the artifact's sha256 in an
# identity sidecar and `verify` re-digests the file on disk. Replacing our
# artifact with anything else, including an upstream build that reports the same
# version, fails verification loudly.
#
# The stronger guard is naming: our command is `gs-<tool>`, installed to
# ~/.local/bin, so an ordinary `npm install -g <upstream>` or an upstream
# installer writes a DIFFERENT path and cannot reach our artifact at all.
# `verify` is the backstop that catches deliberate or accidental overwrite.
#
# FM_FOLD_PREFIX overrides the install prefix. The anti-replacement proof and
# every test use it so nothing touches the captain's real ~/.local/bin.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-fold-lib.sh disable=SC1091
. "$ROOT/bin/fm-fold-lib.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

die() {
  printf 'fm-fold: %s\n' "$1" >&2
  exit "${2:-1}"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required" 127
}

cmd_list() {
  local id cmd upstream state artifact
  printf '%-14s %-14s %-18s %s\n' FOLD COMMAND REPLACES STATE
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    cmd=$(fm_fold_command "$id" 2>/dev/null || echo '?')
    upstream=$(fm_fold_upstream_command "$id" 2>/dev/null || echo '?')
    if fm_fold_installed "$id" 2>/dev/null; then
      artifact=$(fm_fold_artifact_path "$id")
      if "$ROOT/bin/fm-fold.sh" verify "$id" >/dev/null 2>&1; then
        state="installed ($artifact)"
      else
        state="INSTALLED BUT UNVERIFIED ($artifact)"
      fi
    else
      state="not installed"
    fi
    printf '%-14s %-14s %-18s %s\n' "$id" "$cmd" "$upstream" "$state"
  done < <(fm_fold_ids)
}

# Build our artifact from a source checkout. The source tree is whatever the
# captain's own repository for this fold contains; before that repository
# exists, a pinned upstream checkout plus our carried fixes stands in, which is
# exactly what `fm-fold-seed.sh` materializes.
cmd_build() {
  local id=${1:-} source='' out='' kind entry artifact_name
  shift || true
  [ -n "$id" ] || usage
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -gt 1 ] || die "--source requires a path" 2; source=$2; shift 2 ;;
      --source=*) source=${1#--source=}; shift ;;
      --out) [ "$#" -gt 1 ] || die "--out requires a path" 2; out=$2; shift 2 ;;
      --out=*) out=${1#--out=}; shift ;;
      *) die "unknown build flag '$1'" 2 ;;
    esac
  done
  fm_fold_known "$id" || die "unknown fold '$id'" 66
  [ -n "$source" ] || die "build requires --source <checkout>" 2
  [ -d "$source" ] || die "source checkout not found: $source" 66

  kind=$(fm_fold_field "$id" build.kind) || die "manifest has no build.kind" 65
  artifact_name=$(fm_fold_command "$id")
  [ -n "$out" ] || out="$source/.fold-build"
  mkdir -p "$out"

  case "$kind" in
    go)
      entry=$(fm_fold_field "$id" build.entry) || entry=.
      # Stamp OUR identity into the binary, not upstream's. An unstamped Go
      # build reports a module pseudo-version, which is meaningless as identity.
      ( cd "$source" && go build \
          -ldflags "-X main.version=$(cmd_stamp "$id")" \
          -o "$out/$artifact_name" "$entry" ) \
        || die "go build failed for $id" 70
      ;;
    node)
      entry=$(fm_fold_field "$id" build.entry) || die "manifest has no build.entry" 65
      ( cd "$source" && { [ -d node_modules ] || npm install --silent >/dev/null 2>&1 || true; } \
        && npm run build --silent >/dev/null 2>&1 ) \
        || die "node build failed for $id" 70
      [ -f "$source/$entry" ] || die "built entry missing: $source/$entry" 70
      # A node fold installs as a launcher that pins OUR entry point, so the
      # artifact is a single executable path the identity sidecar can digest.
      {
        printf '#!/usr/bin/env node\n'
        printf '// gs-fold launcher for %s - built from %s\n' "$id" "$(cmd_stamp "$id")"
        printf 'import(%s);\n' "$(printf '%s' "file://$source/$entry" | jq -Rs .)"
      } > "$out/$artifact_name"
      chmod +x "$out/$artifact_name"
      ;;
    *) die "unsupported build.kind '$kind'" 65 ;;
  esac
  printf '%s\n' "$out/$artifact_name"
}

# The version string our build stamps: umbrella-qualified so it can never be
# confused with an upstream release string.
cmd_stamp() { # <fold>
  local id=${1:-} base
  base=$(fm_fold_field "$id" upstream.baseTag 2>/dev/null || echo unknown)
  printf 'gs-fold/%s (base %s)\n' "$id" "$base"
}

cmd_install() {
  local id=${1:-} artifact='' prefix target identity digest
  shift || true
  [ -n "$id" ] || usage
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --artifact) [ "$#" -gt 1 ] || die "--artifact requires a path" 2; artifact=$2; shift 2 ;;
      --artifact=*) artifact=${1#--artifact=}; shift ;;
      *) die "unknown install flag '$1'" 2 ;;
    esac
  done
  fm_fold_known "$id" || die "unknown fold '$id'" 66
  [ -n "$artifact" ] || die "install requires --artifact <path>" 2
  [ -f "$artifact" ] || die "artifact not found: $artifact" 66

  prefix=$(fm_fold_prefix "$id")
  target=$(fm_fold_artifact_path "$id")
  identity=$(fm_fold_identity_path "$id")
  mkdir -p "$prefix" "$(dirname "$identity")"

  # Keep a rollback beside the artifact, matching the no-mistakes precedent.
  [ -f "$target" ] && cp "$target" "$target.rollback"
  install -m 755 "$artifact" "$target"
  digest=$(fm_fold_digest "$target") || die "cannot digest installed artifact" 70

  jq -n \
    --arg fold "$id" \
    --arg command "$(fm_fold_command "$id")" \
    --arg replaces "$(fm_fold_upstream_command "$id")" \
    --arg umbrella "$(fm_fold_field "$id" umbrella)" \
    --arg repo "$(fm_fold_field "$id" ours.repo)" \
    --arg upstreamRepo "$(fm_fold_field "$id" upstream.repo)" \
    --arg baseCommit "$(fm_fold_field "$id" upstream.baseCommit)" \
    --arg baseTag "$(fm_fold_field "$id" upstream.baseTag)" \
    --arg path "$target" \
    --arg digest "$digest" \
    '{
      fold: $fold, command: $command, replaces: $replaces, umbrella: $umbrella,
      ours: $repo,
      base: {repo: $upstreamRepo, tag: $baseTag, commit: $baseCommit},
      artifact: {path: $path, sha256: $digest},
      note: "identity is the sha256 above, never the version string: an upstream build can report an identical version"
    }' > "$identity"
  printf '%s\n' "$target"
}

cmd_identity() {
  local id=${1:-} identity
  [ -n "$id" ] || usage
  fm_fold_known "$id" || die "unknown fold '$id'" 66
  identity=$(fm_fold_identity_path "$id")
  [ -f "$identity" ] || die "fold '$id' is not installed (no identity record at $identity)" 66
  cat "$identity"
}

# The anti-replacement check. Fails loudly when the artifact on disk is not the
# one we installed - which is what an upstream package landing on our path
# would look like - and stays silent-clean when it is ours.
cmd_verify() {
  local id=${1:-} identity target recorded actual
  [ -n "$id" ] || usage
  fm_fold_known "$id" || die "unknown fold '$id'" 66
  identity=$(fm_fold_identity_path "$id")
  [ -f "$identity" ] || die "fold '$id' is not installed" 66
  target=$(jq -r '.artifact.path' "$identity")
  recorded=$(jq -r '.artifact.sha256' "$identity")
  [ -f "$target" ] || die "fold '$id' artifact is missing from $target" 1
  actual=$(fm_fold_digest "$target") || die "cannot digest $target" 70
  if [ "$actual" != "$recorded" ]; then
    printf 'fm-fold: %s at %s is NOT our artifact\n' "$id" "$target" >&2
    printf '  recorded sha256 %s\n  on-disk  sha256 %s\n' "$recorded" "$actual" >&2
    printf '  something replaced the folded tool; reinstall from %s\n' \
      "$(jq -r '.ours' "$identity")" >&2
    exit 1
  fi
  printf 'gs-fold %s verified: %s (%s)\n' "$id" "$target" "$recorded"
}

require_jq
case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  build) shift; cmd_build "$@" ;;
  install) shift; cmd_install "$@" ;;
  identity) shift; cmd_identity "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  stamp) shift; cmd_stamp "$@" ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
