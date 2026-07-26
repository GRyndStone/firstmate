# shellcheck shell=bash
# Shared manifest access for the folded-tool system.
# Usage: . bin/fm-fold-lib.sh
#
# A "fold" is a third-party tool firstmate depends on that has been brought
# under the captain's own control: our own command name, our own build, our own
# install route, and a recorded upstream baseline. The captain's precedent is
# GRyndStone/no-mistakes - an INDEPENDENT private repository, not a GitHub fork,
# installed to ~/.local/bin rather than a public registry. docs/folding-tools.md
# owns the procedure and the rationale; this library owns only manifest access
# so every fold script reads one schema from one place.
#
# Each fold is declared by vendor/<fold>/fold.json. That file is the single
# source of the fold's identity: our command name, the upstream repo and the
# exact base commit we forked from, the build kind, and the trim/declined
# ledgers. Nothing else may re-spell those facts.
#
# Sourced only; not executed as a main program.

_FM_FOLD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_FOLD_LIB_DIR="."

# Repo root that owns vendor/. FM_FOLD_ROOT overrides for tests.
fm_fold_root() {
  if [ -n "${FM_FOLD_ROOT:-}" ]; then
    printf '%s\n' "$FM_FOLD_ROOT"
    return 0
  fi
  (cd "$_FM_FOLD_LIB_DIR/.." && pwd)
}

fm_fold_vendor_dir() {
  printf '%s/vendor\n' "$(fm_fold_root)"
}

fm_fold_manifest_path() { # <fold>
  printf '%s/%s/fold.json\n' "$(fm_fold_vendor_dir)" "${1:-}"
}

# Every declared fold, one id per line, in directory order.
fm_fold_ids() {
  local vendor
  vendor=$(fm_fold_vendor_dir)
  [ -d "$vendor" ] || return 0
  find "$vendor" -mindepth 2 -maxdepth 2 -name fold.json -print 2>/dev/null |
    sed "s|^$vendor/||; s|/fold.json$||" |
    sort
}

fm_fold_known() { # <fold>
  local id=${1:-}
  [ -n "$id" ] || return 1
  [ -f "$(fm_fold_manifest_path "$id")" ]
}

# Read one dotted field out of a fold manifest, e.g. upstream.baseCommit.
# Prints nothing and returns non-zero when the field is absent or null, so a
# caller can distinguish "declared empty" from "not declared".
fm_fold_field() { # <fold> <dotted-path>
  local id=${1:-} path=${2:-} manifest value
  manifest=$(fm_fold_manifest_path "$id")
  [ -f "$manifest" ] || {
    printf 'fm-fold: no manifest for fold %s\n' "$id" >&2
    return 66
  }
  value=$(jq -er --arg p "$path" '
    reduce ($p | split(".")[]) as $k (.; if type == "object" then .[$k] else null end)
    | if . == null then error("absent") else . end
    | if type == "string" then . else tojson end
  ' "$manifest" 2>/dev/null) || return 1
  printf '%s\n' "$value"
}

# Our command name for a fold (what firstmate must invoke).
fm_fold_command() { # <fold>
  fm_fold_field "${1:-}" command
}

# The upstream command name this fold replaces (what must disappear from
# firstmate's surfaces once the fold is installed).
fm_fold_upstream_command() { # <fold>
  fm_fold_field "${1:-}" upstreamCommand
}

# Every upstream command name across all declared folds, one per line.
# This is the sweep target list: any of these still reachable from a firstmate
# surface is an unfolded dependency.
fm_fold_upstream_commands() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_fold_upstream_command "$id" 2>/dev/null || true
  done < <(fm_fold_ids)
}

# Where an installed fold artifact lives. FM_FOLD_PREFIX overrides the manifest
# prefix so tests and the anti-replacement proof can use an isolated prefix
# instead of touching the captain's machine.
fm_fold_prefix() { # <fold>
  local id=${1:-} prefix _fm_tilde
  # A manifest may record the prefix as "~/.local/bin". Expanding it here keeps
  # the tilde out of shell word-expansion entirely.
  _fm_tilde=$(printf '\176')
  if [ -n "${FM_FOLD_PREFIX:-}" ]; then
    printf '%s\n' "$FM_FOLD_PREFIX"
    return 0
  fi
  prefix=$(fm_fold_field "$id" install.prefix) || prefix="$HOME/.local/bin"
  case "$prefix" in
    "$_fm_tilde"/*) printf '%s/%s\n' "$HOME" "${prefix#"$_fm_tilde"/}" ;;
    *) printf '%s\n' "$prefix" ;;
  esac
}

fm_fold_artifact_path() { # <fold>
  local id=${1:-} cmd prefix
  cmd=$(fm_fold_command "$id") || return 1
  prefix=$(fm_fold_prefix "$id") || return 1
  printf '%s/%s\n' "$prefix" "$cmd"
}

# The identity sidecar for an installed fold. Identity must NOT rest on a
# version string: a locally built quota-axi reports the same "0.1.13" the
# published release reports while carrying different code, so a version compare
# calls an unfolded install current. The sidecar records the content digest.
fm_fold_identity_path() { # <fold>
  local id=${1:-} prefix
  prefix=$(fm_fold_prefix "$id") || return 1
  printf '%s/.gs-fold/%s.identity.json\n' "$prefix" "$id"
}

# Content digest of a built artifact. One definition, used by both the installer
# that records it and the verifier that checks it, so they cannot drift.
fm_fold_digest() { # <path>
  local path=${1:-}
  [ -f "$path" ] || return 1
  shasum -a 256 "$path" | awk '{print $1}'
}

fm_fold_installed() { # <fold>
  local artifact
  artifact=$(fm_fold_artifact_path "${1:-}") || return 1
  [ -x "$artifact" ]
}
