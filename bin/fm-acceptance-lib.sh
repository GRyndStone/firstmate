#!/usr/bin/env bash
# shellcheck shell=bash
# Single owner of firstmate's criterion-to-evidence acceptance contract.
#
# Ship completion must not advance from unstructured worker claims. Concrete
# acceptance criteria carry stable ids (AC-N). The completion handoff at
# data/<id>/acceptance.md maps each id to direct same-surface evidence.
# Status prose and worker authority are claims, never evidence. Proxy
# substitutions across evidence classes fail closed.
#
# Each entry also carries a relevance: classification against the
# captain-approved ideal state - blocks-ideal, later-scope, or out-of-model -
# because a finding being true is not by itself a reason to act on it. A missing
# or unrecognized value fails closed like any other incomplete mapping.
#
# Public entrypoints (also exposed by bin/fm-acceptance-check.sh):
#   fm_acceptance_extract_ids <brief-path>          # prints AC-N lines
#   fm_acceptance_required_class <statement-text>   # prints one class token
#   fm_acceptance_class_compatible <required> <offered>
#   fm_acceptance_check <brief-path> <evidence-path>  # stdout report; rc 0|1
#   fm_acceptance_paths_for_task <home> <task-id>     # sets BRIEF EVIDENCE
#
# Full operator contract: docs/acceptance-evidence.md

_FM_ACCEPTANCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_ACCEPTANCE_LIB_DIR="."

# Keywords that force a non-proxyable required class. Order matters: first match wins.
# UI/live/security must never be satisfied by catalog/config/unit alone.
fm_acceptance_required_class() {
  local text
  text=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$text" in
    *user-facing*|*user\ facing*|*chooser*|*switcher*|*menu*|*ui/*|*\ ui\ *|*telegram*|*click*|*screenshot*)
      printf 'ui\n'
      return 0
      ;;
  esac
  case "$text" in
    *security*|*destructive*|*production*|*live\ server*|*live-server*|*on\ the\ live*|*against\ the\ live*)
      printf 'live\n'
      return 0
      ;;
  esac
  case "$text" in
    *unit\ test*|*unit-test*|*focused\ test*|*regression\ test*)
      printf 'unit\n'
      return 0
      ;;
  esac
  case "$text" in
    *catalog*|*provider\ list*|*model\ list*)
      printf 'catalog\n'
      return 0
      ;;
  esac
  case "$text" in
    *config*|*yaml*|*ini\ *|*.json*)
      printf 'config\n'
      return 0
      ;;
  esac
  case "$text" in
    *api\ *|*api/*|*endpoint*|*http*)
      printf 'api\n'
      return 0
      ;;
  esac
  # Default: code-level evidence is acceptable for ordinary ship criteria.
  printf 'code\n'
}

# Return 0 when offered evidence class may satisfy the required class.
fm_acceptance_class_compatible() {
  local required=${1:-} offered=${2:-}
  required=$(printf '%s' "$required" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  offered=$(printf '%s' "$offered" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

  # Status prose / worker claims never count as evidence.
  case "$offered" in
    status|claim|prose|authority|done) return 1 ;;
  esac
  [ -n "$required" ] && [ -n "$offered" ] || return 1

  if [ "$required" = "$offered" ]; then
    return 0
  fi

  case "$required" in
    ui)
      # UI/menu/chooser criteria accept only UI-surface evidence.
      return 1
      ;;
    live)
      # Live/world/security criteria accept only live observation (not unit/config).
      return 1
      ;;
    catalog)
      return 1
      ;;
    config)
      # Config may be evidenced by reading code that embeds the same value.
      [ "$offered" = code ] && return 0
      return 1
      ;;
    api)
      return 1
      ;;
    unit)
      return 1
      ;;
    code)
      # Ordinary code criteria accept code-level and stronger world surfaces.
      case "$offered" in
        code|unit|config|process|api|live|ui) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    process)
      [ "$offered" = live ] && return 0
      return 1
      ;;
    inference)
      case "$offered" in
        inference|live|ui) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

# Extract stable criterion ids (AC-N) from the Task section of a ship brief.
# Ignores the scaffold's own Acceptance-evidence instructions so example AC-N
# tokens there do not invent criteria.
fm_acceptance_extract_ids() {
  local brief=$1
  local in_task=0 line id
  local -a seen=()
  [ -f "$brief" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '# Task'|'# Task '*)
        in_task=1
        continue
        ;;
      '# '*)
        if [ "$in_task" -eq 1 ]; then
          # Leave the Task section at the next top-level heading.
          case "$line" in
            '# Task'|'# Task '*) ;;
            *) in_task=0 ;;
          esac
        fi
        ;;
    esac
    [ "$in_task" -eq 1 ] || continue
    # Match AC-1, AC-12, etc. as whole tokens.
    while [[ "$line" =~ (^|[^A-Za-z0-9_])(AC-[0-9]+)([^A-Za-z0-9_]|$) ]]; do
      id=${BASH_REMATCH[2]}
      if ! printf '%s\n' "${seen[@]:-}" | grep -Fxq "$id" 2>/dev/null; then
        seen+=("$id")
        printf '%s\n' "$id"
      fi
      # Strip the matched id so the loop can find further ids on the same line.
      line=${line/${BASH_REMATCH[2]}/}
    done
  done < "$brief"
}

# Extract the free-text statement for one AC id from the Task section (best effort).
fm_acceptance_extract_statement() {
  local brief=$1 want=$2
  local in_task=0 line
  [ -f "$brief" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '# Task'|'# Task '*) in_task=1; continue ;;
      '# '*)
        if [ "$in_task" -eq 1 ]; then
          case "$line" in
            '# Task'|'# Task '*) ;;
            *) in_task=0 ;;
          esac
        fi
        ;;
    esac
    [ "$in_task" -eq 1 ] || continue
    case "$line" in
      *"$want"*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done < "$brief"
  return 0
}

# Parse a single ## AC-N section from an evidence file into key=value lines on stdout.
# Keys: statement, surface, class, command, result, head, relevance, required_class
fm_acceptance_parse_entry() {
  local evidence=$1 want=$2
  local in=0 line key val
  [ -f "$evidence" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## $want"|"## $want:"*)
        in=1
        continue
        ;;
      '## '*)
        [ "$in" -eq 1 ] && break
        ;;
    esac
    [ "$in" -eq 1 ] || continue
    case "$line" in
      '- '*)
        line=${line#- }
        line=${line#-}
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        key=${line%%:*}
        val=${line#*:}
        key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr '-' '_')
        val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//')
        case "$key" in
          statement|surface|class|command|result|head|freshness|relevance|required_class|required)
            if [ "$key" = freshness ]; then
              key="head"
            fi
            if [ "$key" = required ]; then
              key="required_class"
            fi
            printf '%s=%s\n' "$key" "$val"
            ;;
        esac
        ;;
    esac
  done < "$evidence"
}

fm_acceptance_entry_field() {
  local blob=$1 field=$2
  printf '%s\n' "$blob" | grep -E "^${field}=" | head -n1 | sed "s/^${field}=//"
}

fm_acceptance_none_declared() {
  local evidence=$1
  [ -f "$evidence" ] || return 1
  grep -Eiq '^[[:space:]]*none:[[:space:]]*no concrete acceptance criteria[[:space:]]*$' "$evidence"
}

# Sets caller-visible BRIEF and EVIDENCE paths for a task under a firstmate home.
fm_acceptance_paths_for_task() {
  local home=$1 id=$2
  # shellcheck disable=SC2034 # intentionally assigned for the calling script
  BRIEF="$home/data/$id/brief.md"
  # shellcheck disable=SC2034 # intentionally assigned for the calling script
  EVIDENCE="$home/data/$id/acceptance.md"
}

# Core check. Prints a human report. Returns 0 only when the handoff is complete
# and every criterion maps to compatible direct evidence.
fm_acceptance_check() {
  local brief=$1 evidence=$2
  local -a ids=()
  local id entry statement required offered surface command result head relevance missing rc=0
  local repair=()

  if [ ! -f "$brief" ]; then
    printf 'FAIL: brief missing at %s\n' "$brief"
    printf 'repair: ensure the task brief exists before acceptance check\n'
    return 1
  fi

  while IFS= read -r id; do
    [ -n "$id" ] && ids+=("$id")
  done < <(fm_acceptance_extract_ids "$brief")

  if [ ! -f "$evidence" ]; then
    printf 'FAIL: acceptance evidence handoff missing at %s\n' "$evidence"
    if [ "${#ids[@]}" -eq 0 ]; then
      printf 'repair: write %s with a single line: none: no concrete acceptance criteria\n' "$evidence"
    else
      printf 'repair: write %s mapping each of: %s\n' "$evidence" "${ids[*]}"
      printf 'repair: each ## AC-N entry needs surface, class, command, result, relevance (and head when relevant)\n'
    fi
    printf 'note: a bare done: status line is a claim, not evidence; it cannot advance the task\n'
    return 1
  fi

  if [ "${#ids[@]}" -eq 0 ]; then
    if fm_acceptance_none_declared "$evidence"; then
      printf 'PASS: no concrete AC-* criteria; proportional none: declaration accepted\n'
      return 0
    fi
    printf 'FAIL: brief has no AC-* criteria but evidence file lacks the proportional none: line\n'
    printf 'repair: either tag concrete criteria as AC-1.. in the Task section, or set evidence to: none: no concrete acceptance criteria\n'
    return 1
  fi

  if fm_acceptance_none_declared "$evidence"; then
    printf 'FAIL: evidence declares none: but brief lists concrete criteria: %s\n' "${ids[*]}"
    printf 'repair: remove none: and map each criterion with direct same-surface evidence\n'
    return 1
  fi

  printf 'criteria: %s\n' "${ids[*]}"

  for id in "${ids[@]}"; do
    missing=0
    entry=$(fm_acceptance_parse_entry "$evidence" "$id" || true)
    if [ -z "$entry" ]; then
      printf 'FAIL %s: no ## %s section in evidence handoff\n' "$id" "$id"
      repair+=("repair $id: add a ## $id section with surface, class, command, result, relevance")
      rc=1
      continue
    fi

    statement=$(fm_acceptance_entry_field "$entry" statement)
    if [ -z "$statement" ]; then
      statement=$(fm_acceptance_extract_statement "$brief" "$id")
    fi
    required=$(fm_acceptance_entry_field "$entry" required_class)
    if [ -z "$required" ]; then
      required=$(fm_acceptance_required_class "$statement")
    fi
    offered=$(fm_acceptance_entry_field "$entry" class)
    surface=$(fm_acceptance_entry_field "$entry" surface)
    command=$(fm_acceptance_entry_field "$entry" command)
    result=$(fm_acceptance_entry_field "$entry" result)
    head=$(fm_acceptance_entry_field "$entry" head)

    for field_name in surface class command result; do
      case "$field_name" in
        surface) [ -n "$surface" ] || missing=1 ;;
        class) [ -n "$offered" ] || missing=1 ;;
        command) [ -n "$command" ] || missing=1 ;;
        result) [ -n "$result" ] || missing=1 ;;
      esac
    done
    if [ "$missing" -eq 1 ]; then
      printf 'FAIL %s: incomplete evidence (need surface, class, command, result)\n' "$id"
      printf '  have: surface=%q class=%q command=%q result=%q head=%q\n' \
        "${surface:-}" "${offered:-}" "${command:-}" "${result:-}" "${head:-}"
      repair+=("repair $id: fill missing fields among surface/class/command/result; head recommended for live/UI")
      rc=1
      continue
    fi

    # Status-class or claim-like results fail even if other fields exist.
    case "$(printf '%s' "$offered" | tr '[:upper:]' '[:lower:]')" in
      status|claim|prose|authority|done)
        printf 'FAIL %s: class %s is a claim, not evidence\n' "$id" "$offered"
        repair+=("repair $id: replace status/claim class with the real observation surface class")
        rc=1
        continue
        ;;
    esac

    if ! fm_acceptance_class_compatible "$required" "$offered"; then
      printf 'FAIL %s: proxy rejected (required_class=%s offered_class=%s)\n' "$id" "$required" "$offered"
      printf '  statement: %s\n' "${statement:-"(none)"}"
      printf '  surface: %s\n' "$surface"
      repair+=("repair $id: required class is $required; provide direct $required evidence (not $offered). config/catalog/api ≠ ui; unit ≠ live; current selection ≠ alternatives selectable")
      rc=1
      continue
    fi

    # For UI and live criteria, require head/freshness attribution.
    case "$required" in
      ui|live)
        if [ -z "$head" ]; then
          printf 'FAIL %s: %s evidence requires head/freshness attribution\n' "$id" "$required"
          repair+=("repair $id: add head: <git-sha or observation timestamp> for $required evidence")
          rc=1
          continue
        fi
        ;;
    esac

    # Truth is not sufficient. A criterion closes only when its finding has also
    # been weighed against the captain-approved ideal state, so a verified but
    # out-of-model finding is declared out-of-model instead of silently setting
    # the agenda. Checked last so class, proxy, and freshness failures keep
    # reporting their own cause.
    relevance=$(fm_acceptance_entry_field "$entry" relevance)
    if [ -z "$relevance" ]; then
      printf 'FAIL %s: no relevance: classification against the ideal state\n' "$id"
      repair+=("repair $id: add relevance: one of blocks-ideal, later-scope, out-of-model")
      rc=1
      continue
    fi
    case "$(printf '%s' "$relevance" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      blocks-ideal|later-scope|out-of-model) ;;
      *)
        printf 'FAIL %s: unrecognized relevance value: %s\n' "$id" "$relevance"
        repair+=("repair $id: relevance must be exactly one of blocks-ideal, later-scope, out-of-model")
        rc=1
        continue
        ;;
    esac

    printf 'PASS %s: class=%s surface=%s relevance=%s\n' "$id" "$offered" "$surface" "$relevance"
  done

  if [ "$rc" -ne 0 ]; then
    printf '\n'
    local r
    for r in "${repair[@]}"; do
      printf '%s\n' "$r"
    done
    printf 'note: status prose and worker done: lines are claims; return incomplete mappings to the worker, do not advance\n'
    return 1
  fi

  printf 'PASS: all criteria mapped to compatible direct evidence\n'
  return 0
}
