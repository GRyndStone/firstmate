# shellcheck shell=bash
# No-mistakes generation routing for Firstmate.
#
# Firstmate chooses which no-mistakes runtime generation a newly spawned ordinary
# task (ship/scout) validates against. The selection is local and gitignored
# (config/no-mistakes-generation), resolved once at spawn, snapshotted into
# task meta, and exported into that worker's pane. Later recovery and status
# reads use the task pin, not the live config, so a mid-flight config change
# never rewrites live metadata or force-switches an in-flight process.
#
# No-mistakes chooses its own validation agents from fresh quota evidence inside
# that generation. Firstmate must not derive NO_MISTAKES_RUN_AGENTS from the
# crewmate harness/model.
#
# Usage: . bin/fm-nm-generation-lib.sh
# Requires CONFIG (or pass paths explicitly to the helpers below).
#
# Config file (local, gitignored): config/no-mistakes-generation
#   # comments and blank lines ignored
#   id=<short-label>                 # optional; defaults to the home basename
#   binary=<absolute-path-to-cli>    # required when the file is present
#   home=<absolute-state-root>       # required when the file is present (NM_HOME)
#
# Absent file: ambient/default PATH no-mistakes and default NM_HOME (compat).
# Present but missing keys, relative paths, non-executable binary, missing home,
# or unhealthy generation: fail closed with an actionable diagnostic. Never
# silently fall back to the ambient installation when a generation is selected.
#
# Outputs (globals, never require command-substitution of resolve):
#   FM_NM_GEN_ID FM_NM_GEN_BINARY FM_NM_GEN_HOME  - resolved pin (empty = ambient)
#   FM_NM_GEN_ERR                                 - last failure diagnostic
#
# Health: NM_HOME=<home> <binary> daemon status reports a running daemon.
# Tests may set FM_NM_GENERATION_HEALTH_CMD to override the probe (must exit 0
# when healthy). Set FM_NM_GENERATION_SKIP_HEALTH=1 only in unit tests that
# intentionally cover parse/path gates without a daemon.

# fm_nm_generation_config_path [config-dir]
# Print the absolute path of the generation config file.
fm_nm_generation_config_path() {
  local config_dir=${1:-${CONFIG:-}}
  [ -n "$config_dir" ] || config_dir="${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}"
  printf '%s' "$config_dir/no-mistakes-generation"
}

fm_nm_generation_set_err() {
  FM_NM_GEN_ERR=$*
}

# fm_nm_generation_parse <config-file>
# Parse key=value lines into FM_NM_GEN_ID / FM_NM_GEN_BINARY / FM_NM_GEN_HOME.
# Returns 0 when the file is absent (leaves the three vars empty).
# Returns 1 and sets FM_NM_GEN_ERR when the file is present but invalid.
fm_nm_generation_parse() {
  local file=$1 line key val
  FM_NM_GEN_ID=
  FM_NM_GEN_BINARY=
  FM_NM_GEN_HOME=
  FM_NM_GEN_ERR=
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
    esac
    case "$line" in
      *=*)
        key=${line%%=*}
        val=${line#*=}
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
          id) FM_NM_GEN_ID=$val ;;
          binary) FM_NM_GEN_BINARY=$val ;;
          home) FM_NM_GEN_HOME=$val ;;
          *)
            fm_nm_generation_set_err "unknown key $key in $file (allowed: id, binary, home)"
            return 1
            ;;
        esac
        ;;
      *)
        fm_nm_generation_set_err "malformed line in $file (want key=value): $line"
        return 1
        ;;
    esac
  done < "$file"
  if [ -z "$FM_NM_GEN_BINARY" ] || [ -z "$FM_NM_GEN_HOME" ]; then
    fm_nm_generation_set_err "config/no-mistakes-generation is present but incomplete (need absolute binary= and home=)"
    return 1
  fi
  case "$FM_NM_GEN_BINARY" in
    /*) ;;
    *)
      fm_nm_generation_set_err "config/no-mistakes-generation binary must be an absolute path (got $FM_NM_GEN_BINARY)"
      return 1
      ;;
  esac
  case "$FM_NM_GEN_HOME" in
    /*) ;;
    *)
      fm_nm_generation_set_err "config/no-mistakes-generation home must be an absolute path (got $FM_NM_GEN_HOME)"
      return 1
      ;;
  esac
  if [ -z "$FM_NM_GEN_ID" ]; then
    FM_NM_GEN_ID=$(basename "$FM_NM_GEN_HOME")
  fi
  return 0
}

# fm_nm_generation_validate_resolved
# After parse or a meta pin restore: binary executable, home is a directory.
fm_nm_generation_validate_resolved() {
  FM_NM_GEN_ERR=
  if [ ! -x "$FM_NM_GEN_BINARY" ]; then
    fm_nm_generation_set_err "no-mistakes generation binary is missing or not executable: $FM_NM_GEN_BINARY"
    return 1
  fi
  if [ ! -d "$FM_NM_GEN_HOME" ]; then
    fm_nm_generation_set_err "no-mistakes generation home is missing or not a directory: $FM_NM_GEN_HOME"
    return 1
  fi
  return 0
}

# fm_nm_generation_health_check
# Fail closed when the selected generation's daemon is not running.
fm_nm_generation_health_check() {
  local out status=0
  FM_NM_GEN_ERR=
  if [ "${FM_NM_GENERATION_SKIP_HEALTH:-0}" = 1 ]; then
    return 0
  fi
  if [ -n "${FM_NM_GENERATION_HEALTH_CMD:-}" ]; then
    if ! out=$(NM_HOME="$FM_NM_GEN_HOME" sh -c "$FM_NM_GENERATION_HEALTH_CMD" 2>&1); then
      fm_nm_generation_set_err "no-mistakes generation unhealthy (id=${FM_NM_GEN_ID:-unknown} home=$FM_NM_GEN_HOME): health probe failed: $out"
      return 1
    fi
    return 0
  fi
  out=$(NM_HOME="$FM_NM_GEN_HOME" "$FM_NM_GEN_BINARY" daemon status 2>&1) || status=$?
  if [ "$status" -ne 0 ] || ! printf '%s\n' "$out" | grep -qiE 'daemon running|●.*running'; then
    fm_nm_generation_set_err "no-mistakes generation unhealthy (id=${FM_NM_GEN_ID:-unknown} home=$FM_NM_GEN_HOME binary=$FM_NM_GEN_BINARY): daemon not running${out:+; $out}"
    return 1
  fi
  return 0
}

# fm_nm_generation_resolve_for_spawn <config-dir> <existing-meta-path-or-empty>
# Resolve the generation pin for a new ordinary-task spawn.
# Prefer an existing task meta pin (recovery continuity) over the live config.
# On success sets FM_NM_GEN_* (may all be empty when no config and no prior pin).
# On hard failure sets FM_NM_GEN_ERR and returns 1. Call without command
# substitution so the pin globals remain in the caller shell.
fm_nm_generation_resolve_for_spawn() {
  local config_dir=$1 meta=${2:-} cfg
  local prior_id='' prior_bin='' prior_home=''

  FM_NM_GEN_ID=
  FM_NM_GEN_BINARY=
  FM_NM_GEN_HOME=
  FM_NM_GEN_ERR=

  if [ -n "$meta" ] && [ -f "$meta" ]; then
    prior_id=$(grep '^nm_generation=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    prior_bin=$(grep '^nm_binary=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    prior_home=$(grep '^nm_home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi

  if [ -n "$prior_bin" ] && [ -n "$prior_home" ]; then
    FM_NM_GEN_ID=$prior_id
    FM_NM_GEN_BINARY=$prior_bin
    FM_NM_GEN_HOME=$prior_home
    [ -n "$FM_NM_GEN_ID" ] || FM_NM_GEN_ID=$(basename "$FM_NM_GEN_HOME")
    if ! fm_nm_generation_validate_resolved; then
      fm_nm_generation_set_err "task-pinned no-mistakes generation is invalid (refusing ambient fallback): $FM_NM_GEN_ERR"
      return 1
    fi
    if ! fm_nm_generation_health_check; then
      fm_nm_generation_set_err "task-pinned no-mistakes generation is unhealthy (refusing ambient fallback): $FM_NM_GEN_ERR"
      return 1
    fi
    return 0
  fi

  cfg=$(fm_nm_generation_config_path "$config_dir")
  if [ ! -f "$cfg" ]; then
    return 0
  fi
  if ! fm_nm_generation_parse "$cfg"; then
    return 1
  fi
  if ! fm_nm_generation_validate_resolved; then
    return 1
  fi
  if ! fm_nm_generation_health_check; then
    return 1
  fi
  return 0
}

# fm_nm_shell_quote <value> - single-quote for shell.
fm_nm_shell_quote() {
  local s=$1
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# fm_nm_generation_export_lines
# Print shell export lines for the resolved pin (none when ambient).
fm_nm_generation_export_lines() {
  local bindir
  [ -n "${FM_NM_GEN_BINARY:-}" ] || return 0
  [ -n "${FM_NM_GEN_HOME:-}" ] || return 0
  bindir=$(dirname "$FM_NM_GEN_BINARY")
  printf 'export NM_HOME=%s\n' "$(fm_nm_shell_quote "$FM_NM_GEN_HOME")"
  # shellcheck disable=SC2016 # intentional ${PATH} for the worker shell to expand
  printf 'export PATH=%s:"${PATH}"\n' "$(fm_nm_shell_quote "$bindir")"
}

# fm_nm_generation_meta_lines
# Print meta key=value lines for the resolved pin (none when ambient).
fm_nm_generation_meta_lines() {
  [ -n "${FM_NM_GEN_BINARY:-}" ] || return 0
  [ -n "${FM_NM_GEN_HOME:-}" ] || return 0
  printf 'nm_generation=%s\n' "${FM_NM_GEN_ID:-}"
  printf 'nm_binary=%s\n' "$FM_NM_GEN_BINARY"
  printf 'nm_home=%s\n' "$FM_NM_GEN_HOME"
}

# fm_nm_generation_bootstrap_report [config-dir]
# Detect-only bootstrap diagnostic. Silent when the file is absent.
# Prints one NM_GENERATION: line when active, invalid, or unhealthy.
fm_nm_generation_bootstrap_report() {
  local config_dir=${1:-${CONFIG:-}} cfg
  cfg=$(fm_nm_generation_config_path "$config_dir")
  [ -f "$cfg" ] || return 0
  if ! fm_nm_generation_parse "$cfg"; then
    echo "NM_GENERATION: invalid config/no-mistakes-generation - $FM_NM_GEN_ERR"
    return 0
  fi
  if ! fm_nm_generation_validate_resolved; then
    echo "NM_GENERATION: invalid config/no-mistakes-generation - $FM_NM_GEN_ERR"
    return 0
  fi
  if ! fm_nm_generation_health_check; then
    echo "NM_GENERATION: unhealthy config/no-mistakes-generation - $FM_NM_GEN_ERR"
    return 0
  fi
  echo "NM_GENERATION: active id=${FM_NM_GEN_ID} binary=${FM_NM_GEN_BINARY} home=${FM_NM_GEN_HOME}"
}
