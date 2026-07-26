#!/usr/bin/env bash
# fm-deps.sh - firstmate's incorporation ledger: what it incorporates, whether
# each piece is current, and whether an upgrade broke a contract it depends on.
#
# The inventory is DECLARED in deps/incorporations.conf, the pinned contracts
# live in deps/contracts/, the parsing and cache format are owned by
# bin/fm-deps-lib.sh, and the operator-facing rationale is
# docs/dependency-currency.md. Read those before changing behavior here.
#
# Usage:
#   fm-deps.sh list                     table of every declared component and its verdict
#   fm-deps.sh validate                 check the inventory itself; silent when valid
#   fm-deps.sh refresh [--offline|--if-due]  look up currency, verify contracts, update the cache
#   fm-deps.sh report                   print DEPS: problem lines from the cache; SILENT when all good
#   fm-deps.sh check [--offline]        refresh then report (the manual "tell me now")
#   fm-deps.sh upgrade <id> --approve [--to <version>] [--despite-fleet]
#   fm-deps.sh rollback <id> [--approve]
#   fm-deps.sh ledger                   print the recorded upgrade history
#   fm-deps.sh access-check [<id>]      verify (not assume) whether a fix could be
#                                       landed upstream; needs auth and network, so
#                                       it is never on the session-start path
#
# `report` is the ordinary path: bin/fm-bootstrap.sh calls it on every session
# start, so staleness and contract breaks arrive without anyone thinking to ask.
# It prints NOTHING when every component is current and every contract holds -
# a check that speaks when all is well is ignored within a week and is then
# worse than nothing, because it looks like coverage.
#
# Upgrading is never silent and never automatic. `upgrade` refuses without
# --approve, and refuses again while the fleet has tasks in flight unless the
# captain explicitly passes --despite-fleet. Every upgrade is recorded in the
# ledger with the version it moved from, which is what makes `rollback` a real
# recovery path rather than a described one.
#
# Exit codes:
#   0  success (report: printed nothing or printed advisories)
#   1  usage or operational error
#   2  refused: approval missing, or the fleet is in flight
#   3  the contract broke after the upgrade (the upgrade happened; recover)
#
# Test seams (all default to the real thing):
#   FM_DEPS_DIR, FM_DEPS_CACHE, FM_DEPS_LEDGER, FM_DEPS_NPM,
#   FM_DEPS_NOW_EPOCH, FM_DEPS_NOW_ISO, FM_DEPS_PROBE_<ID>_<NAME>,
#   FM_DEPS_VERSION_<ID>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-deps-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-deps-lib.sh"

LEDGER="${FM_DEPS_LEDGER:-$DATA/dep-upgrades.md}"

now_iso() {
  printf '%s\n' "${FM_DEPS_NOW_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

die() {
  printf 'fm-deps: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Tools bin/fm-bootstrap.sh requires but which no stanza declares. This is the
# enforcement half of "declared, not inferred": adding a tool to bootstrap
# without declaring it here is visible on the ordinary path AND red in
# tests/fm-deps.test.sh, instead of quietly joining the set of things nobody
# tracks.
undeclared_bootstrap_tools() {
  local bootstrap line tool
  bootstrap="$FM_ROOT/bin/fm-bootstrap.sh"
  [ -f "$bootstrap" ] || return 0
  # Every TOOLS assignment in bootstrap's backend case, unioned.
  line=$(sed -n 's/^[[:space:]]*[a-z*|]*)[[:space:]]*TOOLS="\([^"]*\)".*$/\1/p' "$bootstrap")
  for tool in $line; do
    fm_deps_declared "$tool" || printf '%s\n' "$tool"
  done | sort -u
}

# True when the tooling a component's declared currency source needs is present.
# A component with no registry source at all is never reported on, so it answers
# true and the caller's other conditions decide.
lookup_tool_available() { # <id>
  local source
  source=$(fm_deps_field "${1:-}" currency 2>/dev/null || true)
  case "$source" in
    npm:?*) command -v "${FM_DEPS_NPM:-npm}" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

fleet_in_flight() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    basename "$meta" .meta
  done
}

# --- refresh ----------------------------------------------------------------

# True when the network half of a refresh is due: no cache at all, or the most
# recent successful lookup is older than the refresh interval.
network_lookup_due() {
  local cache newest now
  cache=$(fm_deps_cache_file)
  [ -f "$cache" ] || return 0
  newest=$(awk -F '\t' '$4 ~ /^[0-9]+$/ { if ($4 > m) m = $4 } END { print m + 0 }' "$cache")
  [ "$newest" -gt 0 ] 2>/dev/null || return 0
  now=$(fm_deps_now_epoch)
  [ "$((now - newest))" -ge "${FM_DEPS_REFRESH_INTERVAL:-43200}" ]
}

refresh() { # [--offline|--if-due]
  local offline=0 id installed latest latest_epoch cached_latest cached_epoch
  local contract_decl contract_version contract_verdict contract_detail status out budget_end
  local prev_artifact_version prev_reading artifact_version artifact_reading
  local provenance_observed artifact_detail pkg pkg_dir new_reading published_reading
  case "${1:-}" in
    --offline) offline=1 ;;
    # The cheap half - reading installed versions and re-verifying any contract
    # whose installed version moved - always runs, because that is what catches
    # an upgrade someone performed outside this script. Only the registry
    # lookups are rate-limited, so a session start does not pay for the network
    # every time.
    --if-due) network_lookup_due || offline=1 ;;
  esac
  budget_end=$(( $(fm_deps_now_epoch) + ${FM_DEPS_REFRESH_BUDGET:-12} ))
  while read -r id; do
    [ -n "$id" ] || continue
    installed=$(fm_deps_installed_version "$id" 2>/dev/null || true)

    # Currency. A failed lookup must never overwrite a good cached answer with
    # nothing: the previous latest and the epoch it was learned at are what let
    # `report` distinguish "offline for an afternoon" from "nobody has been able
    # to check this for a week".
    cached_latest=$(fm_deps_cache_get "$id" 3 2>/dev/null || true)
    cached_epoch=$(fm_deps_cache_get "$id" 4 2>/dev/null || true)
    latest=$cached_latest
    latest_epoch=$cached_epoch
    if [ "$offline" -eq 0 ] && [ "$(fm_deps_now_epoch)" -ge "$budget_end" ]; then
      # The network phase has a whole-run budget, not just a per-lookup bound:
      # session start must not pay one timeout per declared component when the
      # registry is unreachable. Remaining components keep their cached answers,
      # which the unchecked-horizon rule will eventually surface if it persists.
      offline=1
    fi
    if [ "$offline" -eq 0 ]; then
      out=$(fm_deps_lookup_latest "$id")
      status=$?
      case "$status" in
        0)
          latest=$out
          latest_epoch=$(fm_deps_now_epoch)
          ;;
        1)
          # No registry to query at all. Declared, not a failure; record it so
          # report never nags about a component whose currency the inventory
          # already says cannot be established.
          latest=
          latest_epoch=
          ;;
        *) ;; # lookup attempted and failed: keep the previous answer and epoch
      esac
    fi

    # Contract. Re-verified only when the installed version differs from the one
    # the cached verdict was produced against - an upgrade therefore re-checks
    # its own contract automatically, and an unchanged install costs nothing.
    contract_decl=$(fm_deps_field "$id" contract 2>/dev/null || true)
    contract_version=$(fm_deps_cache_get "$id" 5 2>/dev/null || true)
    contract_verdict=$(fm_deps_cache_get "$id" 6 2>/dev/null || true)
    contract_detail=$(fm_deps_cache_get "$id" 7 2>/dev/null || true)
    if [ "$contract_decl" = pinned ]; then
      if [ -z "$installed" ]; then
        contract_version=
        contract_verdict=unknown
        contract_detail="not installed"
      elif [ "$installed" != "$contract_version" ] || [ -z "$contract_verdict" ] ||
        [ "${FM_DEPS_FORCE_CONTRACT:-0}" = 1 ]; then
        out=$(fm_deps_contract_check "$id")
        status=$?
        contract_version=$installed
        case "$status" in
          0)
            contract_verdict=ok
            contract_detail=
            ;;
          1)
            contract_verdict=broken
            contract_detail=$(printf '%s' "$out" | tr '\n' ';' | sed 's/;$//')
            ;;
          *)
            contract_verdict=unknown
            contract_version=
            contract_detail="contract could not be evaluated"
            ;;
        esac
      fi
    else
      contract_version=
      contract_verdict=
      contract_detail=
    fi

    # Artifact identity. A version number is not identity, so this reads the
    # installed tree itself and compares it two ways: against the registry's own
    # metadata for that exact version (divergence), and against the reading last
    # recorded for the same version (continuity). See bin/fm-deps-lib.sh.
    prev_artifact_version=$(fm_deps_cache_get "$id" 8 2>/dev/null || true)
    prev_reading=$(fm_deps_cache_get "$id" 9 2>/dev/null || true)
    artifact_version=$prev_artifact_version
    artifact_reading=$prev_reading
    provenance_observed=$(fm_deps_cache_get "$id" 10 2>/dev/null || true)
    artifact_detail=$(fm_deps_cache_get "$id" 11 2>/dev/null || true)
    pkg=$(fm_deps_field "$id" currency 2>/dev/null || true)
    case "$pkg" in npm:?*) pkg=${pkg#npm:} ;; *) pkg= ;; esac
    if [ -n "$pkg" ] && [ -n "$installed" ]; then
      pkg_dir=$(fm_deps_npm_prefix "$pkg" 2>/dev/null || true)
      if [ -n "$pkg_dir" ]; then
        new_reading=$(fm_deps_artifact_reading "$pkg_dir" 2>/dev/null || true)
        if [ -n "$new_reading" ]; then
          if [ -n "$prev_reading" ] && [ "$prev_artifact_version" = "$installed" ] &&
            [ "$prev_reading" != "$new_reading" ]; then
            # Same version string, different bytes. Whatever else is true, this
            # is the fact worth surfacing: the code moved and nothing else would
            # have said so.
            provenance_observed=changed
            artifact_detail="was ${prev_reading% *} now ${new_reading% *} under an unchanged version $installed"
          elif [ "$offline" -eq 0 ] &&
            { [ -z "$provenance_observed" ] || [ "$prev_artifact_version" != "$installed" ] ||
              [ "$prev_reading" != "$new_reading" ]; }; then
            # Same discipline as the contract cache: the published reading is only
            # re-queried when the thing it describes actually moved. Without this
            # the identity check spends a registry call per component on every
            # refresh and starves the currency lookups of their shared budget.
            published_reading=$(fm_deps_published_reading "$pkg" "$installed" 2>/dev/null || true)
            if [ -n "$published_reading" ]; then
              if [ "${new_reading% *}" = "$published_reading" ]; then
                provenance_observed=published
                artifact_detail=
              else
                provenance_observed=local-build
                artifact_detail="installed ${new_reading% *} vs published $published_reading, both calling themselves $installed"
              fi
            fi
          fi
          artifact_version=$installed
          artifact_reading=$new_reading
        fi
      fi
    fi

    fm_deps_cache_put "$id" "$installed" "$latest" "$latest_epoch" \
      "$contract_version" "$contract_verdict" "$contract_detail" \
      "$artifact_version" "$artifact_reading" "$provenance_observed" "$artifact_detail"
  done < <(refresh_order)
}

# Declared components, stalest currency answer first. A registry lookup costs
# seconds, so a bounded refresh cannot always reach every component - and if the
# order were fixed, the same components would be starved every time and their
# answers would never move. Spending the budget on the least recently answered
# first makes coverage rotate, so a full sweep completes across a few refreshes
# instead of never.
refresh_order() {
  local id epoch
  while read -r id; do
    [ -n "$id" ] || continue
    epoch=$(fm_deps_cache_get "$id" 4 2>/dev/null || printf '0')
    printf '%s\t%s\n' "${epoch:-0}" "$id"
  done < <(fm_deps_ids) | sort -n -k1,1 -s | cut -f2
}

# --- report -----------------------------------------------------------------

# Prints one DEPS: line per problem, nothing when there is none. Reads only the
# cache and the inventory; never touches the network, so it is safe on the
# read-only session-start path.
report() {
  local id installed latest epoch verdict detail age horizon problem now
  local currency sibling_version sibling_dir provenance_decl provenance_obs artifact_detail fallback_rung
  problem=$(fm_deps_validate_inventory)
  if [ -n "$problem" ]; then
    printf '%s\n' "$problem" | while IFS= read -r line; do
      [ -n "$line" ] && printf 'DEPS: inventory invalid: %s\n' "$line"
    done
  fi
  undeclared_bootstrap_tools | while IFS= read -r tool; do
    [ -n "$tool" ] &&
      printf 'DEPS: undeclared: %s is required by bin/fm-bootstrap.sh but has no stanza in deps/incorporations.conf\n' "$tool"
  done

  now=$(fm_deps_now_epoch)
  horizon=$((FM_DEPS_UNCHECKED_HORIZON_DAYS * 86400))
  while read -r id; do
    [ -n "$id" ] || continue
    installed=$(fm_deps_cache_get "$id" 2 2>/dev/null || true)
    latest=$(fm_deps_cache_get "$id" 3 2>/dev/null || true)
    epoch=$(fm_deps_cache_get "$id" 4 2>/dev/null || true)
    verdict=$(fm_deps_cache_get "$id" 6 2>/dev/null || true)
    detail=$(fm_deps_cache_get "$id" 7 2>/dev/null || true)
    fm_deps_field_into currency "$id" currency || true

    fm_deps_field_into provenance_decl "$id" provenance || true
    case "$provenance_decl" in local-build*) provenance_decl=local-build ;; *) provenance_decl=published ;; esac
    if [ -n "$installed" ] && [ -n "$latest" ] && fm_deps_semver_lt "$installed" "$latest"; then
      if [ "$provenance_decl" = local-build ]; then
        # Upgrading would discard the local build. Say what moved upstream, and
        # do not hand over an upgrade command that silently drops the fix.
        printf 'DEPS: %s upstream released %s while this home runs a local build of %s (see deps/incorporations.conf before upgrading; upgrading discards the local build)\n' \
          "$id" "$latest" "$installed"
      else
        printf 'DEPS: %s behind: installed %s, latest %s (upgrade: bin/fm-deps.sh upgrade %s --approve)\n' \
          "$id" "$installed" "$latest" "$id"
      fi
    fi

    # The captain's own clone having moved past what is installed is the exact
    # shape quota-axi drifted in, and it is knowable with no network at all.
    sibling_version=
    if [ -n "$installed" ] && fm_deps_field_into sibling_dir "$id" sibling; then
      sibling_version=$(fm_deps_sibling_version "$id" 2>/dev/null || true)
    fi
    if [ -n "$installed" ] && [ -n "$sibling_version" ] &&
      fm_deps_semver_lt "$installed" "$sibling_version" && [ "$sibling_version" != "$latest" ]; then
      printf 'DEPS: %s sibling ahead: installed %s, own clone %s tagged %s\n' \
        "$id" "$installed" "$sibling_dir" "$sibling_version"
    fi

    case "$currency" in
      none:*) ;; # declared unknowable; never nag
      *)
        if [ -z "$epoch" ]; then
          # Three conditions before this is worth saying, because each of the
          # alternatives is already owned elsewhere or is not yet a fact:
          #   * a refresh has actually recorded a row (a home where the check has
          #     simply never run is not a finding; the first locked session start
          #     resolves it),
          #   * the component is actually installed (an absent tool is already
          #     reported by bootstrap's own MISSING: line - one owner, not two),
          #   * and the machine HAS the lookup tool (with no npm at all, firstmate
          #     cannot query npm for anything, and saying so once per npm-backed
          #     component turns one environment fact into a wall of noise).
          if fm_deps_cache_has_row "$id" && [ -n "$installed" ] && lookup_tool_available "$id"; then
            printf 'DEPS: %s currency never established (lookups have been attempted and none succeeded; run bin/fm-deps.sh check)\n' "$id"
          fi
        else
          age=$((now - epoch))
          if [ "$age" -gt "$horizon" ]; then
            printf 'DEPS: %s currency unchecked for %s days (last successful lookup said %s)\n' \
              "$id" "$((age / 86400))" "${latest:-unknown}"
          fi
        fi
        ;;
    esac

    # Identity, reported next to ownership because they are the same question:
    # what is actually running here, and can we do anything about it.
    provenance_obs=$(fm_deps_cache_get "$id" 10 2>/dev/null || true)
    artifact_detail=$(fm_deps_cache_get "$id" 11 2>/dev/null || true)
    case "$provenance_obs" in
      changed)
        printf 'DEPS: %s artifact changed under an unchanged version: %s (a version number is not identity; confirm what is installed)\n' \
          "$id" "${artifact_detail:-no detail recorded}"
        ;;
      local-build)
        if [ "$provenance_decl" != local-build ]; then
          printf 'DEPS: %s is NOT the published package it claims to be: %s (declare it as provenance = local-build, or reinstall the published one)\n' \
            "$id" "${artifact_detail:-no detail recorded}"
        fi
        ;;
      published)
        if [ "$provenance_decl" = local-build ]; then
          fm_deps_field_into fallback_rung "$id" fallback || true
          # The regression that would otherwise be invisible: a plain
          # `npm install -g` replaces a deliberate local build, the version
          # string does not move, and whatever fix it carried is silently gone.
          printf 'DEPS: %s local build has been replaced by the published package: the fix it carried is no longer installed (see deps/incorporations.conf, and %s)\n' \
            "$id" "${fallback_rung%%:*}"
        fi
        ;;
    esac

    case "$verdict" in
      broken)
        printf 'DEPS: %s CONTRACT BROKEN at installed %s: %s (recover: bin/fm-deps.sh rollback %s --approve)\n' \
          "$id" "${installed:-unknown}" "${detail:-unspecified}" "$id"
        ;;
      unknown)
        # "not installed" is already bootstrap's MISSING: line. Repeating it here
        # would give one fact two owners and make an absent tool report twice.
        [ "$detail" = "not installed" ] ||
          printf 'DEPS: %s contract unverified: %s\n' "$id" "${detail:-no reason recorded}"
        ;;
    esac
  done < <(fm_deps_ids)
}

# --- list -------------------------------------------------------------------

list() {
  local id installed latest verdict contract currency state
  printf '%-22s %-10s %-10s %-10s %s\n' COMPONENT INSTALLED LATEST CONTRACT PURPOSE
  while read -r id; do
    [ -n "$id" ] || continue
    installed=$(fm_deps_cache_get "$id" 2 2>/dev/null || fm_deps_installed_version "$id" 2>/dev/null || echo -)
    latest=$(fm_deps_cache_get "$id" 3 2>/dev/null || echo -)
    verdict=$(fm_deps_cache_get "$id" 6 2>/dev/null || true)
    contract=$(fm_deps_field "$id" contract 2>/dev/null || echo -)
    currency=$(fm_deps_field "$id" currency 2>/dev/null || echo -)
    case "$contract" in
      pinned) state=${verdict:-unchecked} ;;
      *) state=unpinned ;;
    esac
    case "$currency" in
      none:*) latest=n/a ;;
    esac
    printf '%-22s %-10s %-10s %-10s %s\n' \
      "$id" "${installed:--}" "${latest:--}" "$state" "$(fm_deps_field "$id" purpose 2>/dev/null || true)"
  done < <(fm_deps_ids)
}

# --- ledger -----------------------------------------------------------------

ledger_append() { # <id> <from> <to> <action> <contract> [detail]
  local dir
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" 2>/dev/null || return 1
  if [ ! -f "$LEDGER" ]; then
    {
      printf '# Dependency upgrade ledger\n\n'
      printf 'Append-only record of every deliberate move, written by bin/fm-deps.sh.\n'
      printf 'The from version is what rollback reinstalls, so this file is the recovery path.\n\n'
    } > "$LEDGER"
  fi
  printf -- '- %s %s %s -> %s %s contract=%s%s\n' \
    "$(now_iso)" "$1" "${2:-unknown}" "${3:-unknown}" "$4" "$5" \
    "${6:+ ($6)}" >> "$LEDGER"
}

# Most recent recorded `from` version for a component, i.e. what to go back to.
ledger_previous_version() { # <id>
  [ -f "$LEDGER" ] || return 1
  awk -v want="$1" '
    $3 == want && $5 == "->" && $7 == "upgrade" { v = $4 }
    END { if (v != "") print v }
  ' "$LEDGER"
}

# --- access ------------------------------------------------------------------

# Verify, rather than assume, whether a needed fix could actually be landed
# upstream. The inventory records the answer with the date it was checked; this
# is how that answer gets checked. It needs auth and network, so it is never on
# the ambient session-start path - it is something an operator runs when the
# recorded answer is stale or when a fix is about to be needed.
access_check() { # [<id>]
  local id repo gh out ids
  gh='gh-axi'
  command -v "$gh" >/dev/null 2>&1 || gh=gh
  command -v "$gh" >/dev/null 2>&1 || die "neither gh-axi nor gh is available to check repository access"
  ids=${1:-$(fm_deps_ids)}
  for id in $ids; do
    repo=$(fm_deps_field "$id" repo 2>/dev/null || true)
    if [ -z "$repo" ]; then
      printf '%-22s %s\n' "$id" "no repo declared; nothing to check"
      continue
    fi
    out=$(fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" "$gh" api "repos/$repo" --jq .permissions 2>/dev/null) || out=
    if [ -z "$out" ]; then
      # An unreadable answer is "unknown", never "yes" - assuming access is the
      # failure this check exists to remove.
      printf '%-22s %s\n' "$id" "unknown: could not read permissions for $repo"
      continue
    fi
    printf '%-22s %s\n' "$id" "$repo $out"
    case "$out" in
      *'"push":true'* | *'"push": true'*)
        printf '%-22s   -> record: write-access = yes: verified %s via %s api repos/%s\n' "" "$(now_iso)" "$gh" "$repo"
        ;;
      *)
        printf '%-22s   -> record: write-access = none: verified %s via %s api repos/%s (%s)\n' "" "$(now_iso)" "$gh" "$repo" "$out"
        ;;
    esac
  done
}

# --- install / upgrade ------------------------------------------------------

install_version() { # <id> <version>
  local id=$1 version=$2 kind pkg npm_cmd currency
  kind=$(fm_deps_field "$id" kind 2>/dev/null || true)
  currency=$(fm_deps_field "$id" currency 2>/dev/null || true)
  case "$kind" in
    npm) ;;
    *)
      printf 'fm-deps: %s is kind=%s; firstmate does not automate its install.\n' "$id" "${kind:-unknown}" >&2
      printf 'fm-deps: install it the way bin/fm-bootstrap.sh documents, then rerun: bin/fm-deps.sh check\n' >&2
      return 1
      ;;
  esac
  case "$currency" in
    npm:?*) pkg=${currency#npm:} ;;
    *)
      printf 'fm-deps: %s declares no npm package to install from\n' "$id" >&2
      return 1
      ;;
  esac
  npm_cmd=${FM_DEPS_NPM:-npm}
  command -v "$npm_cmd" >/dev/null 2>&1 || {
    printf 'fm-deps: %s not found; cannot install %s\n' "$npm_cmd" "$id" >&2
    return 1
  }
  printf 'fm-deps: installing %s@%s\n' "$pkg" "$version"
  "$npm_cmd" install -g "$pkg@$version"
}

upgrade() { # <id> [flags]
  local id=${1:-} approve=0 despite=0 target='' arg from to inflight verdict out status
  [ -n "$id" ] || die "usage: fm-deps.sh upgrade <id> --approve [--to <version>] [--despite-fleet]"
  shift
  while [ $# -gt 0 ]; do
    arg=$1
    case "$arg" in
      --approve) approve=1 ;;
      --despite-fleet) despite=1 ;;
      --to)
        shift
        target=${1:-}
        ;;
      *) die "unknown flag: $arg" ;;
    esac
    shift
  done
  fm_deps_declared "$id" || die "$id is not declared in $(fm_deps_inventory_file)"

  from=$(fm_deps_installed_version "$id" 2>/dev/null || true)
  to=$target
  if [ -z "$to" ]; then
    out=$(fm_deps_lookup_latest "$id")
    status=$?
    [ "$status" -eq 0 ] || die "cannot determine the latest version of $id; pass --to <version>"
    to=$out
  fi

  if [ "$approve" -ne 1 ]; then
    printf 'fm-deps: REFUSED - upgrading is a deliberate operation and needs the captain'"'"'s word.\n' >&2
    printf 'fm-deps: would move %s from %s to %s\n' "$id" "${from:-absent}" "$to" >&2
    printf 'fm-deps: rerun with --approve to do it.\n' >&2
    return 2
  fi

  inflight=$(fleet_in_flight | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$inflight" ] && [ "$despite" -ne 1 ]; then
    printf 'fm-deps: REFUSED - the fleet has work in flight: %s\n' "$inflight" >&2
    printf 'fm-deps: changing a tool under running crewmates can break them mid-task.\n' >&2
    printf 'fm-deps: wait for the fleet to clear, or rerun with --despite-fleet if the captain says go.\n' >&2
    return 2
  fi

  install_version "$id" "$to" || die "install failed; $id is unchanged at ${from:-absent}"

  # Re-read what is actually installed rather than trusting the requested
  # version: a package manager that silently resolved something else must not be
  # recorded as if it did what it was asked.
  to=$(fm_deps_installed_version "$id" 2>/dev/null || printf '%s' "$to")
  FM_DEPS_FORCE_CONTRACT=1 refresh --offline
  verdict=$(fm_deps_cache_get "$id" 6 2>/dev/null || printf 'unknown')
  out=$(fm_deps_cache_get "$id" 7 2>/dev/null || true)
  ledger_append "$id" "$from" "$to" upgrade "$verdict" "$out"

  case "$verdict" in
    ok)
      printf 'fm-deps: %s upgraded %s -> %s; pinned contract still holds.\n' "$id" "${from:-absent}" "$to"
      return 0
      ;;
    broken)
      printf 'fm-deps: %s upgraded %s -> %s but its PINNED CONTRACT BROKE:\n' "$id" "${from:-absent}" "$to" >&2
      printf 'fm-deps:   %s\n' "$out" >&2
      printf 'fm-deps: nothing else consumed the new version yet. Recover with:\n' >&2
      printf 'fm-deps:   bin/fm-deps.sh rollback %s --approve\n' "$id" >&2
      return 3
      ;;
    *)
      printf 'fm-deps: %s upgraded %s -> %s; contract could not be verified (%s).\n' \
        "$id" "${from:-absent}" "$to" "${out:-no reason recorded}" >&2
      return 0
      ;;
  esac
}

rollback() { # <id> [--approve] [--to <version>]
  local id=${1:-} approve=0 target='' arg to from verdict out
  [ -n "$id" ] || die "usage: fm-deps.sh rollback <id> --approve [--to <version>]"
  shift
  while [ $# -gt 0 ]; do
    arg=$1
    case "$arg" in
      --approve) approve=1 ;;
      --to)
        shift
        target=${1:-}
        ;;
      *) die "unknown flag: $arg" ;;
    esac
    shift
  done
  fm_deps_declared "$id" || die "$id is not declared in $(fm_deps_inventory_file)"

  from=$(fm_deps_installed_version "$id" 2>/dev/null || true)
  to=$target
  [ -n "$to" ] || to=$(ledger_previous_version "$id" 2>/dev/null || true)
  [ -n "$to" ] || die "no recorded previous version for $id in $LEDGER; pass --to <version>"

  if [ "$approve" -ne 1 ]; then
    printf 'fm-deps: REFUSED - rollback changes an installed tool and needs the captain'"'"'s word.\n' >&2
    printf 'fm-deps: would move %s from %s back to %s\n' "$id" "${from:-absent}" "$to" >&2
    printf 'fm-deps: rerun with --approve to do it.\n' >&2
    return 2
  fi

  install_version "$id" "$to" || die "rollback install failed; $id is unchanged at ${from:-absent}"
  to=$(fm_deps_installed_version "$id" 2>/dev/null || printf '%s' "$to")
  FM_DEPS_FORCE_CONTRACT=1 refresh --offline
  verdict=$(fm_deps_cache_get "$id" 6 2>/dev/null || printf 'unknown')
  out=$(fm_deps_cache_get "$id" 7 2>/dev/null || true)
  ledger_append "$id" "$from" "$to" rollback "$verdict" "$out"
  case "$verdict" in
    ok)
      printf 'fm-deps: %s rolled back %s -> %s; pinned contract holds again.\n' "$id" "${from:-absent}" "$to"
      return 0
      ;;
    broken)
      printf 'fm-deps: %s rolled back %s -> %s but the contract is STILL broken: %s\n' \
        "$id" "${from:-absent}" "$to" "$out" >&2
      return 3
      ;;
    *)
      printf 'fm-deps: %s rolled back %s -> %s; contract could not be verified.\n' "$id" "${from:-absent}" "$to" >&2
      return 0
      ;;
  esac
}

# --- main -------------------------------------------------------------------

case "${1:-report}" in
  list)
    list
    ;;
  validate)
    out=$(fm_deps_validate_inventory)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" >&2
      exit 1
    fi
    ;;
  refresh)
    shift
    refresh "${1:-}"
    ;;
  report)
    report
    ;;
  check)
    shift
    refresh "${1:-}"
    report
    ;;
  upgrade)
    shift
    upgrade "$@"
    ;;
  rollback)
    shift
    rollback "$@"
    ;;
  ledger)
    [ -f "$LEDGER" ] && cat "$LEDGER"
    ;;
  access-check)
    shift
    access_check "${1:-}"
    ;;
  -h | --help | help)
    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "unknown command: $1 (try --help)"
    ;;
esac
