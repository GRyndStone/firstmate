# shellcheck shell=bash
# Shared parsing, currency, and contract-verification helpers for firstmate's
# declared incorporation inventory.
# Usage: . bin/fm-deps-lib.sh
#
# Owners:
#   deps/incorporations.conf   the declared inventory (what firstmate incorporates)
#   deps/contracts/<id>.contract  the pinned contract for components that have one
#   bin/fm-deps.sh             the operator entrypoint
#   docs/dependency-currency.md   the operator-facing story and rationale
#
# INVENTORY FORMAT
#   Stanza per component. `[<id>]` opens a stanza; `key = value` lines follow;
#   `#` comments and blank lines are ignored. Recognized keys:
#     kind       npm | binary | system
#     purpose    one line
#     relies-on  one line
#     currency   npm:<pkg> | brew:<formula> | github:<owner/repo> | none: <reason>
#     sibling    <dir under the home's projects/> (optional)
#     contract   pinned | none: <reason>
#     control     captain | third-party[:<who>] | vendor:<who> | system: <reason>
#     write-access yes|none|unknown: <how it was VERIFIED, and when>
#     fallback    direct|upstream-and-wait|own-build-of-fork|vendor|drop-and-degrade: <why>
#     degrades-to one line: what breaks if this is wrong or absent
#     provenance  published | local-build: <what we run instead, and why> (npm only)
#     artifact-baseline <version> <file-count> <byte-total> <fingerprint>
#                  required for local-build provenance; the expected installed
#                  tree identity that makes a matching local build silent
#     repo        <owner>/<name> (optional; what `fm-deps.sh access-check` queries)
#   control/fallback/degrades-to/write-access are REQUIRED unless kind = system,
#   because a dependency nobody can land a fix in is a different kind of risk
#   from a stale one, and it is knowable in advance rather than at the moment a
#   fix is needed. write-access must carry its verification, not an assumption.
#   `currency = none:` and `contract = none:` REQUIRE a reason after the colon;
#   a bare `none` is a parse error, because "we decided not to" must carry why.
#
# CONTRACT FORMAT
#   `probe <name> = <command line>` declares a named probe; its stdout+stderr is
#   the evidence assertions run against. A probe may be replaced by a fixture in
#   tests via FM_DEPS_PROBE_<ID>_<NAME> (id/name upper-cased, non-alphanumerics
#   mapped to _), which is how the suite stays deterministic and offline.
#   Assertion lines are `<kind> <probe> <rest>`:
#     json <probe> <jq filter>    jq filter must evaluate to exactly true
#     text <probe> <literal>      literal must appear in the probe output
#     min-version <probe> <x.y.z> first semver in the probe output must be >= x.y.z
#   A `#: <label>` comment immediately above an assertion becomes its label in
#   failure output. Assertions with no label fall back to the raw expression.
#
# CACHE
#   One TSV row per component in $STATE/dep-currency.tsv, twelve fields:
#     id  installed  latest  latest_epoch  contract_version  contract_verdict
#     contract_detail  artifact_version  artifact_reading  provenance_observed
#     artifact_detail  contract_reading
#   Empty fields are written as `-`. The cache exists so the ordinary session
#   path can report currency and contract verdicts WITHOUT a network call or a
#   probe run on every start.
#   `contract_version` and `contract_reading` together are what the recorded
#   verdict was produced against, and the verdict is re-verified when EITHER
#   moves. Keying only on the version string was a real defect: the same string
#   names two different builds routinely (a local build of a fork, a republished
#   artifact, a hand-patched install), so a same-version swap that broke the
#   contract stayed cached as `ok` and the break was invisible - which is the
#   exact failure class this tool exists to catch. It fails the other way too:
#   a verdict latched `broken` at version X never cleared while installed stayed
#   X, so a same-version repair left a permanent false alarm, and a stuck alarm
#   destroys the trust that makes silence meaningful. `contract_reading` is the
#   identity from fm_deps_contract_identity, so both directions re-verify.
#   Fields 8-10 hold artifact identity: file count, byte total, and a fingerprint
#   of the installed package. A VERSION NUMBER IS NOT IDENTITY - the same string
#   can name two different builds - so currency alone cannot tell whether what is
#   installed is what was published, or whether a deliberate local build has been
#   silently replaced by the published one.
#
# Sourced only; not executed as a main program.

_FM_DEPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_DEPS_LIB_DIR="."

# Days without a successful currency lookup after which "we do not know" becomes
# a reported problem in its own right. Short outages stay silent (a laptop off
# the network for an afternoon is not news); a component nothing has been able
# to check for a week is a real coverage hole and says so.
FM_DEPS_UNCHECKED_HORIZON_DAYS=${FM_DEPS_UNCHECKED_HORIZON_DAYS:-7}
# Bound on any single currency lookup, so an unreachable registry costs seconds
# at session start rather than hanging the digest.
FM_DEPS_LOOKUP_TIMEOUT=${FM_DEPS_LOOKUP_TIMEOUT:-5}
# Bound on any single contract probe.
FM_DEPS_PROBE_TIMEOUT=${FM_DEPS_PROBE_TIMEOUT:-20}

fm_deps_dir() {
  printf '%s\n' "${FM_DEPS_DIR:-$(cd "$_FM_DEPS_LIB_DIR/.." && pwd)/deps}"
}

fm_deps_inventory_file() {
  printf '%s\n' "$(fm_deps_dir)/incorporations.conf"
}

fm_deps_contract_file() { # <id>
  printf '%s\n' "$(fm_deps_dir)/contracts/${1}.contract"
}

fm_deps_now_epoch() {
  printf '%s\n' "${FM_DEPS_NOW_EPOCH:-$(date +%s)}"
}

# Run a command with a hard wall-clock bound. Mirrors the perl-alarm idiom used
# by fm-watch.sh and fm-crew-state.sh so behavior matches the rest of the fleet
# on hosts without GNU coreutils `timeout`. Exit 124 means it was killed.
fm_deps_run_bounded() { # <seconds> <cmd> [args...]
  local seconds=$1
  shift
  if [ "$seconds" -le 0 ] 2>/dev/null; then
    "$@"
    return $?
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$seconds" "$@"
    return $?
  fi
  "$@"
}

# --- inventory --------------------------------------------------------------

# The inventory is read ONCE per process into shell variables, and every lookup
# afterwards is a fork-free variable read. This is not premature optimization:
# `report` runs on every session start and asks for a dozen fields across a
# dozen components, so a subprocess per lookup put several hundred forks on the
# path the whole design depends on being cheap enough to leave switched on.
fm_deps_load_inventory() {
  local file line id field value key stale
  file=$(fm_deps_inventory_file)
  [ "${_FM_DEPS_INV_LOADED:-}" = "$file" ] && return 0
  # Clear what the PREVIOUS inventory set before loading another one. Without
  # this, a process that reads two inventories keeps the first one's fields and
  # a stanza missing a field silently answers with the other file's value - a
  # memo that lies is worse than no memo, and it is exactly what the validator
  # test caught.
  for stale in ${_FM_DEPS_INV_KEYS:-}; do
    unset "$stale"
  done
  _FM_DEPS_INV_KEYS=
  _FM_DEPS_IDS=
  [ -f "$file" ] || return 1
  # One awk pass emits "<id>\t<field>\t<value>"; the shell then assigns without
  # forking again. eval assigns FROM a variable, so a value containing quotes or
  # backslashes cannot be re-interpreted.
  while IFS=$'\t' read -r id field value; do
    [ -n "$id" ] || continue
    if [ "$field" = '[' ]; then
      _FM_DEPS_IDS="${_FM_DEPS_IDS}${id}"$'\n'
      continue
    fi
    # Inline, not a helper call: a command substitution here would fork once per
    # line and give back exactly the cost this whole load exists to remove.
    key="_fmdep_${id//[!A-Za-z0-9]/_}__${field//[!A-Za-z0-9]/_}"
    eval "$key=\$value"
    _FM_DEPS_INV_KEYS="${_FM_DEPS_INV_KEYS} $key"
  done < <(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      stanza = $0
      sub(/^[[:space:]]*\[/, "", stanza)
      sub(/\].*$/, "", stanza)
      printf "%s\t[\t\n", stanza
      next
    }
    stanza != "" && index($0, "=") > 0 {
      k = substr($0, 1, index($0, "=") - 1)
      v = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k != "") printf "%s\t%s\t%s\n", stanza, k, v
    }
  ' "$file")
  _FM_DEPS_INV_LOADED=$file
}

# Print every declared id, in declaration order.
fm_deps_ids() {
  fm_deps_load_inventory || return 1
  [ -n "${_FM_DEPS_IDS:-}" ] || return 1
  printf '%s' "$_FM_DEPS_IDS"
}

fm_deps_declared() { # <id>
  local id=${1:-}
  [ -n "$id" ] || return 1
  fm_deps_load_inventory || return 1
  case $'\n'"${_FM_DEPS_IDS:-}" in
    *$'\n'"$id"$'\n'*) return 0 ;;
  esac
  return 1
}

# Print one field of one stanza. Absent field prints nothing and returns 1.
fm_deps_field() { # <id> <field>
  local id=${1:-} field=${2:-} key value
  fm_deps_load_inventory || return 1
  key="_fmdep_${id//[!A-Za-z0-9]/_}__${field//[!A-Za-z0-9]/_}"
  value=${!key:-}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# Assign a field into a caller-named variable. Same answer as fm_deps_field, but
# without the command substitution a caller would otherwise wrap it in - which is
# a fork, and the hot paths ask for a dozen fields per component.
fm_deps_field_into() { # <varname> <id> <field>
  local __var=$1 id=${2:-} field=${3:-} key
  fm_deps_load_inventory || {
    printf -v "$__var" '%s' ''
    return 1
  }
  key="_fmdep_${id//[!A-Za-z0-9]/_}__${field//[!A-Za-z0-9]/_}"
  printf -v "$__var" '%s' "${!key:-}"
  [ -n "${!key:-}" ]
}

# Predicate form of the version comparison: true when a is older than b. Callers
# on the session-start path use this instead of $(fm_deps_semver_cmp ...) so the
# comparison costs no fork.
fm_deps_semver_lt() { # <a> <b>
  local a=${1:-0.0.0} b=${2:-0.0.0} i av bv
  local -a ap bp
  IFS=. read -r -a ap <<< "$a"
  IFS=. read -r -a bp <<< "$b"
  for i in 0 1 2; do
    av=${ap[$i]:-0}
    bv=${bp[$i]:-0}
    case "$av$bv" in *[!0-9]*) av=0 bv=0 ;; esac
    [ "$av" -lt "$bv" ] && return 0
    [ "$av" -gt "$bv" ] && return 1
  done
  return 1
}

# Validate the inventory. Prints one line per problem; empty output means valid.
# Enforces the two rules that keep the file honest: every stanza declares the
# required fields, and every `none:` opt-out carries a reason.
fm_deps_validate_inventory() {
  local id value contract_file ids kind
  if [ ! -f "$(fm_deps_inventory_file)" ]; then
    printf 'inventory missing: %s\n' "$(fm_deps_inventory_file)"
    return 0
  fi
  ids=$(fm_deps_ids)
  if [ -z "$ids" ]; then
    printf 'inventory declares no components\n'
    return 0
  fi
  for id in $ids; do
    for value in kind purpose relies-on currency contract; do
      fm_deps_field "$id" "$value" >/dev/null || printf '%s: missing required field %s\n' "$id" "$value"
    done
    fm_deps_field_into kind "$id" kind || true
    # Ownership is required for anything firstmate could realistically need a fix
    # in. System packages come from the operator's OS and are exempt: firstmate
    # patching git is not a real rung on anyone's ladder.
    if [ "$kind" != system ]; then
      for value in control write-access fallback degrades-to; do
        fm_deps_field "$id" "$value" >/dev/null || printf '%s: missing required field %s\n' "$id" "$value"
      done
    fi
    fm_deps_field_into value "$id" control || true
    case "$value" in
      captain | third-party | third-party:?* | vendor:?* | system:*[![:space:]]* | '') ;;
      *) printf '%s: unrecognized control %s\n' "$id" "$value" ;;
    esac
    fm_deps_field_into value "$id" write-access || true
    case "$value" in
      # The verdict alone is an assumption; the evidence after the colon is what
      # makes it a checked fact, so the format requires it.
      yes:*[![:space:]]* | none:*[![:space:]]* | unknown:*[![:space:]]* | '') ;;
      yes | none | unknown | yes:* | none:* | unknown:*)
        printf '%s: write-access must state how it was verified\n' "$id"
        ;;
      *) printf '%s: unrecognized write-access %s\n' "$id" "$value" ;;
    esac
    fm_deps_field_into value "$id" fallback || true
    case "$value" in
      direct:*[![:space:]]* | upstream-and-wait:*[![:space:]]* | own-build-of-fork:*[![:space:]]* | vendor:*[![:space:]]* | drop-and-degrade:*[![:space:]]* | '') ;;
      direct* | upstream-and-wait* | own-build-of-fork* | vendor* | drop-and-degrade*)
        printf '%s: fallback must state why that rung was chosen\n' "$id"
        ;;
      *) printf '%s: unrecognized fallback rung %s\n' "$id" "$value" ;;
    esac
    fm_deps_field_into value "$id" provenance || true
    case "$value" in
      published | local-build:*[![:space:]]* | '') ;;
      local-build | local-build:*) printf '%s: provenance local-build must say what is running instead and why\n' "$id" ;;
      *) printf '%s: unrecognized provenance %s\n' "$id" "$value" ;;
    esac
    case "$value" in
      local-build:*)
        fm_deps_field_into value "$id" artifact-baseline || true
        if [ -z "$value" ]; then
          printf '%s: provenance local-build requires artifact-baseline\n' "$id"
        elif ! printf '%s\n' "$value" |
          grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+ [0-9]+ [0-9]+ [0-9]+$'; then
          printf '%s: artifact-baseline must be <version> <file-count> <byte-total> <fingerprint>\n' "$id"
        fi
        ;;
    esac
    value=$kind
    case "$value" in
      npm | binary | system | '') ;;
      *) printf '%s: unknown kind %s\n' "$id" "$value" ;;
    esac
    fm_deps_field_into value "$id" currency || true
    case "$value" in
      npm:?* | brew:?* | github:?*/?*) ;;
      none:*[![:space:]]*) ;;
      none | none:*) printf '%s: currency none must state a reason\n' "$id" ;;
      '') ;;
      *) printf '%s: unrecognized currency source %s\n' "$id" "$value" ;;
    esac
    fm_deps_field_into value "$id" contract || true
    case "$value" in
      pinned)
        contract_file="$(fm_deps_dir)/contracts/${id}.contract"
        [ -f "$contract_file" ] || printf '%s: contract pinned but %s is missing\n' "$id" "$contract_file"
        ;;
      none:*[![:space:]]*) ;;
      none | none:*) printf '%s: contract none must state a reason\n' "$id" ;;
      '') ;;
      *) printf '%s: unrecognized contract value %s\n' "$id" "$value" ;;
    esac
  done
}

# --- versions ---------------------------------------------------------------

# First dotted triple in a blob, normalized to `x.y.z`.
# grep -Eo rather than sed: a greedy `.*` prefix in sed eats leading digits, so
# `v24.12.0` extracts as `4.12.0` - a wrong version silently compared against a
# right one is exactly the class of bug this file exists to prevent.
fm_deps_extract_semver() { # reads stdin
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Installed version of a component, or nothing when it is absent or silent.
fm_deps_installed_version() { # <id>
  local id=${1:-} out override
  override=$(fm_deps_env_override "FM_DEPS_VERSION" "$id" "") || true
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  command -v "$id" >/dev/null 2>&1 || return 1
  out=$(fm_deps_run_bounded "$FM_DEPS_PROBE_TIMEOUT" "$id" --version 2>&1) || true
  out=$(printf '%s\n' "$out" | fm_deps_extract_semver)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Compare two `x.y.z` versions. Prints -1, 0, or 1 (a<b, a==b, a>b).
fm_deps_semver_cmp() { # <a> <b>
  local a=${1:-0.0.0} b=${2:-0.0.0} i av bv
  local -a ap bp
  IFS=. read -r -a ap <<< "$a"
  IFS=. read -r -a bp <<< "$b"
  for i in 0 1 2; do
    av=${ap[$i]:-0}
    bv=${bp[$i]:-0}
    case "$av$bv" in *[!0-9]*) av=0 bv=0 ;; esac
    if [ "$av" -lt "$bv" ]; then
      printf '%s\n' -1
      return 0
    fi
    if [ "$av" -gt "$bv" ]; then
      printf '%s\n' 1
      return 0
    fi
  done
  printf '%s\n' 0
}

# Resolve a per-component environment override, e.g. FM_DEPS_VERSION_QUOTA_AXI.
# `<prefix>_<ID>[_<SUFFIX>]` with the id upper-cased and non-alphanumerics
# mapped to underscore. Empty/unset resolves to the supplied default.
fm_deps_env_override() { # <prefix> <id> [suffix]
  local prefix=${1:-} id=${2:-} suffix=${3:-} name
  name=$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')
  name="${prefix}_${name}"
  [ -n "$suffix" ] && name="${name}_$(printf '%s' "$suffix" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  printf '%s\n' "${!name:-}"
}

# --- currency ---------------------------------------------------------------

# Latest published version for a component, from its declared currency source.
# Prints the version on success. Returns 1 when the source declares no registry
# (`none: <reason>`), 2 when the lookup was attempted and failed - the caller
# must keep those apart, because "cannot be established" and "could not reach
# the registry today" are different facts about the world.
fm_deps_lookup_latest() { # <id>
  local id=${1:-} source pkg out status npm_cmd brew_cmd gh_cmd repo
  source=$(fm_deps_field "$id" currency 2>/dev/null || true)
  case "$source" in
    npm:?*) pkg=${source#npm:} ;;
    brew:?*)
      # A homebrew formula is a real registry answer, so a component installed
      # that way gets a currency verdict rather than a `none:` opt-out. The
      # formula name is declared explicitly and never guessed from the id: the
      # npm registry has an unrelated `herdr` at 0.0.0, and keying on the id
      # would have compared the installed tool against a stranger's package and
      # called the result currency.
      pkg=${source#brew:}
      brew_cmd=${FM_DEPS_BREW:-brew}
      command -v "$brew_cmd" >/dev/null 2>&1 || return 2
      command -v jq >/dev/null 2>&1 || return 2
      out=$(fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" "$brew_cmd" info --json=v2 --formula "$pkg" 2>/dev/null)
      status=$?
      [ "$status" -eq 0 ] || return 2
      out=$(printf '%s' "$out" | jq -r '.formulae[0].versions.stable // empty' 2>/dev/null)
      out=$(printf '%s\n' "$out" | fm_deps_extract_semver)
      [ -n "$out" ] || return 2
      printf '%s\n' "$out"
      return 0
      ;;
    github:?*/?*)
      # A component distributed outside a package registry can still have an
      # authoritative release stream. Declare the repository explicitly and
      # ask gh-axi for its newest non-draft, non-prerelease release instead of
      # treating a visible release history as unknowable.
      repo=${source#github:}
      gh_cmd=${FM_DEPS_GH_AXI:-gh-axi}
      command -v "$gh_cmd" >/dev/null 2>&1 || return 2
      out=$(GH_REPO="$repo" fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" \
        "$gh_cmd" release list --exclude-drafts --exclude-pre-releases --limit 1 2>/dev/null)
      status=$?
      [ "$status" -eq 0 ] || return 2
      out=$(printf '%s\n' "$out" | fm_deps_extract_semver)
      [ -n "$out" ] || return 2
      printf '%s\n' "$out"
      return 0
      ;;
    *) return 1 ;;
  esac
  npm_cmd=${FM_DEPS_NPM:-npm}
  command -v "$npm_cmd" >/dev/null 2>&1 || return 2
  out=$(fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" "$npm_cmd" view "$pkg" version 2>/dev/null)
  status=$?
  [ "$status" -eq 0 ] || return 2
  out=$(printf '%s\n' "$out" | fm_deps_extract_semver)
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# Newest semver tag in the captain's own local clone of a component, when the
# inventory declares one and the clone is present. This is the answer to "should
# the inventory cover the captain's own sibling projects" - yes, and it costs no
# network, because fleet sync already keeps those clones fresh. quota-axi drifted
# precisely because it is his own repo and nothing watched it.
fm_deps_sibling_version() { # <id>
  local id=${1:-} dir projects out
  dir=$(fm_deps_field "$id" sibling 2>/dev/null) || return 1
  projects=${FM_PROJECTS_OVERRIDE:-${FM_HOME:-}/projects}
  [ -d "$projects/$dir/.git" ] || return 1
  out=$(git -C "$projects/$dir" tag --list 2>/dev/null |
    fm_deps_extract_semver_list | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Normalize every line of stdin that carries a dotted triple to `x.y.z`.
fm_deps_extract_semver_list() {
  sed -n 's/^[vV]\{0,1\}\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\)$/\1.\2.\3/p'
}

# --- artifact identity ------------------------------------------------------
#
# A version number is not identity. The captain's machine currently runs a
# quota-axi packed from his maintained fork, carrying a local fix, reporting the
# same `0.1.13` string as the published release while containing different code.
# A currency check that compares version strings calls that install current and
# identical to upstream, and is wrong about what is actually running. It is the
# same class of defect as the identifier rename: the signal everyone looks at is
# intact while the thing underneath has moved.
#
# Two independent readings, because each catches a case the other cannot:
#   * DIVERGENCE - the installed artifact's file count and byte total against the
#     registry's own dist metadata for that exact version. One cheap metadata
#     call, no download. Sizes matching is not proof of identity; sizes differing
#     IS proof of difference, which is the direction that matters here.
#   * CONTINUITY - a fingerprint of the installed tree, compared against the one
#     recorded for the same version. Needs no network at all, and catches the
#     code moving under an unchanged version in either direction: a local build
#     replacing the published package, or `npm i -g` silently wiping a local
#     build that carried a fix nobody re-applied.

# Absolute path of a globally installed npm package, or nothing.
fm_deps_npm_prefix() { # <pkg>
  local root
  root=${FM_DEPS_NPM_ROOT:-}
  if [ -z "$root" ]; then
    command -v "${FM_DEPS_NPM:-npm}" >/dev/null 2>&1 || return 1
    root=$(fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" "${FM_DEPS_NPM:-npm}" root -g 2>/dev/null) || return 1
  fi
  [ -n "$root" ] && [ -d "$root/$1" ] || return 1
  printf '%s\n' "$root/$1"
}

# "<file-count> <byte-total> <fingerprint>" for an installed package tree.
# The package's OWN nested node_modules is excluded so the reading matches what
# the registry reports for the published tarball. Note the exclusion is anchored
# to the package directory: a bare */node_modules/* pattern also matches the
# global lib/node_modules/<pkg> prefix and silently excludes everything.
fm_deps_artifact_reading() { # <dir>
  local dir=${1:-} list count bytes fingerprint
  [ -d "$dir" ] || return 1
  list=$(find "$dir" -type f -not -path "$dir/node_modules/*" 2>/dev/null | LC_ALL=C sort)
  [ -n "$list" ] || return 1
  count=$(printf '%s\n' "$list" | wc -l | tr -d '[:space:]')
  bytes=$(printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 wc -c 2>/dev/null |
    awk '$2 != "total" { s += $1 } END { print s + 0 }')
  # Path names and file contents both feed the fingerprint, so a same-size edit
  # is caught too - cksum is weak against an adversary but this is drift
  # detection, not tamper-proofing.
  fingerprint=$( {
    printf '%s\n' "$list" | sed "s|^$dir/||"
    printf '%s\n' "$list" | tr '\n' '\0' | xargs -0 cat 2>/dev/null
  } | cksum | awk '{ print $1 }')
  printf '%s %s %s\n' "$count" "$bytes" "$fingerprint"
}

# "1 <bytes> <fingerprint>" for a single file, same shape as an artifact reading.
fm_deps_file_reading() { # <file>
  local f=${1:-} bytes sum
  [ -f "$f" ] || return 1
  bytes=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$bytes" ] || return 1
  sum=$(cksum < "$f" 2>/dev/null | awk '{ print $1 }') || return 1
  [ -n "$sum" ] || return 1
  printf '1 %s %s\n' "$bytes" "$sum"
}

# The identity a contract verdict is keyed to. Prefer the npm package tree - the
# same reading the provenance check uses - and fall back to the resolved
# executable, so a same-version swap is caught for a binary component too and
# not just for an npm one. Prints nothing when neither can be read; the caller
# then has only the version string to key on, which is the weaker behavior this
# function exists to avoid, so that case is deliberately visible rather than
# silently equivalent.
fm_deps_contract_identity() { # <id>
  local id=${1:-} pkg dir bin out
  pkg=$(fm_deps_field "$id" currency 2>/dev/null || true)
  case "$pkg" in npm:?*) pkg=${pkg#npm:} ;; *) pkg= ;; esac
  if [ -n "$pkg" ]; then
    dir=$(fm_deps_npm_prefix "$pkg" 2>/dev/null || true)
    if [ -n "$dir" ]; then
      out=$(fm_deps_artifact_reading "$dir" 2>/dev/null || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
  fi
  bin=$(command -v "$id" 2>/dev/null) || return 1
  [ -n "$bin" ] || return 1
  fm_deps_file_reading "$bin"
}

# "<file-count> <byte-total>" the registry reports for an exact published version.
fm_deps_published_reading() { # <pkg> <version>
  local out
  command -v "${FM_DEPS_NPM:-npm}" >/dev/null 2>&1 || return 1
  out=$(fm_deps_run_bounded "$FM_DEPS_LOOKUP_TIMEOUT" "${FM_DEPS_NPM:-npm}" view "$1@$2" \
    dist.fileCount dist.unpackedSize 2>/dev/null) || return 1
  # npm prints one "<field> = <value>" line per requested field. Key on the field
  # names rather than on line order or on "the digits in the output": the version
  # string itself carries digits, and a positional read would silently pick them.
  out=$(printf '%s\n' "$out" | awk '
    $1 == "dist.fileCount" { count = $3 }
    $1 == "dist.unpackedSize" { bytes = $3 }
    END { if (count != "" && bytes != "") print count, bytes }
  ')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# --- contract verification --------------------------------------------------

# Run a named probe from a contract file, honoring a fixture override.
fm_deps_run_probe() { # <id> <probe-name> <command-line>
  local id=${1:-} name=${2:-} cmdline=${3:-} override
  override=$(fm_deps_env_override "FM_DEPS_PROBE" "$id" "$name") || true
  if [ -n "$override" ]; then
    cmdline=$override
  fi
  fm_deps_run_bounded "$FM_DEPS_PROBE_TIMEOUT" bash -c "$cmdline" 2>&1
}

# Verify a component's pinned contract against what is installed.
# Prints one `<label>` line per failed assertion on stdout.
# Returns 0 all assertions held, 1 at least one failed, 2 the contract could not
# be evaluated at all (probe unavailable, jq missing for a json assertion).
# A 2 is never reported as a break: an unrunnable check has proven nothing, and
# saying otherwise is the failure mode this whole system exists to avoid.
#
# Bash 3.2 compatible on purpose: macOS ships 3.2 as /bin/bash and every other
# script in bin/ runs there, so no associative arrays and no mapfile. Probe
# declarations are held in a tab-separated string and probe output is memoized
# in a scratch dir, which is why each probe runs at most once per check.
fm_deps_contract_check() { # <id>
  local id=${1:-} file line kind probe rest label out failed evaluated
  local probes cmdline cache_dir safe observed rc
  file=$(fm_deps_contract_file "$id")
  [ -f "$file" ] || return 2
  cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-deps-probe.XXXXXX") || return 2
  probes=
  failed=0
  evaluated=0
  rc=
  label=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '#:'*)
        label=${line#'#:'}
        label=${label# }
        continue
        ;;
      '#'* | '') continue ;;
      'probe '*)
        rest=${line#probe }
        probe=${rest%%=*}
        probe=$(printf '%s' "$probe" | tr -d '[:space:]')
        rest=${rest#*=}
        rest=${rest# }
        probes="${probes}${probe}	${rest}
"
        continue
        ;;
    esac
    read -r kind probe rest <<< "$line"
    [ -n "$kind" ] && [ -n "$probe" ] && [ -n "$rest" ] || continue
    cmdline=$(printf '%s' "$probes" | awk -F '\t' -v n="$probe" '$1 == n { print $2; exit }')
    if [ -z "$cmdline" ]; then
      printf 'contract references undeclared probe %s\n' "$probe"
      failed=1
      label=
      continue
    fi
    safe=$(printf '%s' "$probe" | tr -c 'A-Za-z0-9' '_')
    if [ ! -f "$cache_dir/$safe" ]; then
      fm_deps_run_probe "$id" "$probe" "$cmdline" > "$cache_dir/$safe" 2>/dev/null
    fi
    out=$(cat "$cache_dir/$safe")
    [ -n "$label" ] || label="$kind $rest"
    case "$kind" in
      text)
        evaluated=1
        if ! printf '%s\n' "$out" | grep -F -- "$rest" >/dev/null 2>&1; then
          printf '%s (expected "%s" in probe: %s)\n' "$label" "$rest" "$cmdline"
          failed=1
        fi
        ;;
      json)
        if ! command -v jq >/dev/null 2>&1; then
          rc=2
          break
        fi
        evaluated=1
        if ! printf '%s\n' "$out" | jq -e "$rest" >/dev/null 2>&1; then
          printf '%s\n' "$label"
          failed=1
        fi
        ;;
      min-version)
        evaluated=1
        observed=$(printf '%s\n' "$out" | fm_deps_extract_semver)
        if [ -z "$observed" ]; then
          printf '%s (no version found in probe: %s)\n' "$label" "$cmdline"
          failed=1
        elif [ "$(fm_deps_semver_cmp "$observed" "$rest")" = "-1" ]; then
          printf '%s (installed %s, floor %s)\n' "$label" "$observed" "$rest"
          failed=1
        fi
        ;;
      *)
        printf 'unknown assertion kind %s\n' "$kind"
        failed=1
        ;;
    esac
    label=
  done < "$file"
  rm -rf "$cache_dir"
  [ -z "$rc" ] || return "$rc"
  # A contract file that pinned nothing has proven nothing. Reporting that as a
  # pass would manufacture exactly the false coverage this system exists to
  # prevent, so it reports unevaluable instead.
  [ "$evaluated" -eq 1 ] || return 2
  return "$failed"
}

# --- cache ------------------------------------------------------------------

fm_deps_cache_file() {
  printf '%s\n' "${FM_DEPS_CACHE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}/dep-currency.tsv}"
}

# Print one cached field for a component. Fields are 1-indexed per the header
# comment: 2 installed, 3 latest, 4 latest_epoch, 5 contract_version,
# 6 contract_verdict, 7 contract_detail. A `-` placeholder prints as empty.
# Same reasoning as the inventory: the cache is read once and split in-process.
fm_deps_cache_load() {
  local cache line id key stale
  cache=$(fm_deps_cache_file)
  [ "${_FM_DEPS_CACHE_LOADED:-}" = "$cache" ] && return 0
  # Same rule as the inventory: drop the previous file's rows rather than let
  # them answer for a file that no longer contains them.
  for stale in ${_FM_DEPS_CACHE_KEYS:-}; do
    unset "$stale"
  done
  _FM_DEPS_CACHE_KEYS=
  _FM_DEPS_CACHE_IDS=
  [ -f "$cache" ] || {
    _FM_DEPS_CACHE_LOADED=$cache
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    id=${line%%$'\t'*}
    [ -n "$id" ] && [ "$id" != "$line" ] || continue
    key="_fmdepc_${id//[!A-Za-z0-9]/_}"
    eval "$key=\$line"
    _FM_DEPS_CACHE_KEYS="${_FM_DEPS_CACHE_KEYS} $key"
    _FM_DEPS_CACHE_IDS="${_FM_DEPS_CACHE_IDS}${id}"$'\n'
  done < "$cache"
  _FM_DEPS_CACHE_LOADED=$cache
}

fm_deps_cache_get() { # <id> <field-number>
  local id=${1:-} field=${2:-} key row value
  local -a parts
  fm_deps_cache_load
  key="_fmdepc_${id//[!A-Za-z0-9]/_}"
  row=${!key:-}
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r -a parts <<< "$row"
  value=${parts[$((field - 1))]:-}
  [ -n "$value" ] && [ "$value" != "-" ] || return 1
  printf '%s\n' "$value"
}

# True when the cache holds a row for the component at all, which is the
# difference between "a lookup was attempted and never succeeded" and "no
# refresh has run here yet".
fm_deps_cache_has_row() { # <id>
  local key
  fm_deps_cache_load
  key="_fmdepc_${1//[!A-Za-z0-9]/_}"
  [ -n "${!key:-}" ]
}

# Replace (or append) a component's cache row atomically.
fm_deps_cache_put() { # <id> <installed> <latest> <latest_epoch> <contract_version> <contract_verdict> <contract_detail>
  local id=${1:-} cache tmp dir field row sep
  cache=$(fm_deps_cache_file)
  dir=$(dirname "$cache")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(mktemp "$dir/.dep-currency.XXXXXX") || return 1
  if [ -f "$cache" ]; then
    awk -F '\t' -v want="$id" '$1 != want' "$cache" > "$tmp" || true
  fi
  row=
  sep=
  for field in "$@"; do
    # Tabs and newlines are the row/field separators; a detail string carrying
    # either would corrupt every later read, so flatten it here.
    field=$(printf '%s' "${field:--}" | tr '\t\n' '  ')
    row="${row}${sep}${field}"
    sep=$'\t'
  done
  printf '%s\n' "$row" >> "$tmp"
  mv "$tmp" "$cache"
  # The in-process copy is now stale; the next read reloads it.
  _FM_DEPS_CACHE_LOADED=
}
