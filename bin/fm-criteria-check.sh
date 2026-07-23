#!/usr/bin/env bash
# Dispatch gate: refuse to send work out whose criteria do not trace to the captain.
#
# The failure this closes: four consecutive repair briefs were written whose
# every criterion came from the previous round's findings. Each brief was a new
# document inheriting nothing, the link back to what the captain actually asked
# for was made by hand once and then dropped, and the work optimized hard for a
# concern the captain's stated ideal never contained. Nothing refused any of it.
#
# The obvious gate - "a brief must have criteria" - is circular: the same
# judgement that wrote the bad brief also invents the criteria meant to catch
# it. This gates on PROVENANCE instead. Every criterion names where it came
# from, and a criterion cannot claim the captain as its source without carrying
# his literal words. Run against those four repair briefs, every criterion would
# have declared source: execution and not one would have declared captain, so
# every round would have been refused at dispatch.
#
# The artifact is data/<id>/criteria.md:
#
#   # Ideal state
#   > <the captain's own words, verbatim>
#
#   ## AC-1
#   claim:  <falsifiable end-state statement, not an action>
#   source: captain | inferred | research | execution
#   origin: <the quote when source is captain; a path or reference otherwise>
#   probe:  <the command or observation that decides it>
#   anti:   <what a vacuous pass would look like>   (at least one across the set)
#
# usage: fm-criteria-check.sh <id> [--brief <path>] [--criteria <path>]
# exit 0 = dispatchable. exit 1 = refused, with repair: lines on stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SOURCES="captain inferred research execution"

ID=""
BRIEF=""
CRITERIA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) BRIEF=${2:-}; shift 2 ;;
    --criteria) CRITERIA=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) [ -n "$ID" ] && { echo "usage: fm-criteria-check.sh <id> [--brief P] [--criteria P]" >&2; exit 2; }
       ID=$1; shift ;;
  esac
done
[ -n "$ID" ] || { echo "usage: fm-criteria-check.sh <id> [--brief P] [--criteria P]" >&2; exit 2; }
[ -n "$BRIEF" ] || BRIEF="$DATA/$ID/brief.md"
[ -n "$CRITERIA" ] || CRITERIA="$DATA/$ID/criteria.md"

FAILED=0

# A scaffold slot left as-is. The criteria file ships as a template, so without
# this every placeholder would satisfy its own check and the whole gate would
# pass on an untouched scaffold - a gate that always passes is theater.
is_placeholder() {
  case "$1" in
    '{'*'}') return 0 ;;
    *) return 1 ;;
  esac
}

# Echo a field, or nothing when it is still a scaffold slot.
unfilled() {
  if is_placeholder "$1"; then
    printf ''
  else
    printf '%s' "$1"
  fi
}

fail_with() {
  FAILED=1
  printf 'FAIL: %s\n' "$1"
  [ $# -gt 1 ] && printf 'repair: %s\n' "$2"
  return 0
}

# --- the brief ---------------------------------------------------------------

if [ ! -f "$BRIEF" ]; then
  fail_with "no brief at $BRIEF" "scaffold it with bin/fm-brief.sh $ID <repo>"
  printf 'REFUSED: %s is not dispatchable\n' "$ID"
  exit 1
fi

# An unfilled slot is a line whose ENTIRE content is a placeholder token. Prose
# elsewhere in the scaffold legitimately mentions {TASK} while explaining what to
# replace, and a naive count of the token matches that prose too - which is
# exactly how a worker was once launched on a brief whose task section still
# read {TASK}. Only a whole-line occurrence is a slot.
UNFILLED=$(grep -nE '^[[:space:]]*\{[A-Z_]+\}[[:space:]]*$' "$BRIEF" 2>/dev/null || true)
if [ -n "$UNFILLED" ]; then
  fail_with "brief has an unfilled slot: $(printf '%s' "$UNFILLED" | head -1)" \
    "replace the placeholder line in $BRIEF with the real content before dispatching"
fi

# --- the criteria artifact ---------------------------------------------------

if [ ! -f "$CRITERIA" ]; then
  fail_with "no criteria at $CRITERIA" \
    "write it: the captain's own words under '# Ideal state' as a > quote, then one '## AC-N' per criterion with claim/source/origin/probe"
  printf 'REFUSED: %s is not dispatchable\n' "$ID"
  exit 1
fi

# The captain's literal, preserved rather than paraphrased. It is evidence of
# what was asked for, not a target to optimize - which is why it is quoted and
# never rewritten.
GOAL=$(awk '
  /^#+[[:space:]]*Ideal state[[:space:]]*$/ { inblock=1; next }
  inblock && /^#/ { inblock=0 }
  inblock && /^[[:space:]]*>/ { sub(/^[[:space:]]*>[[:space:]]*/, ""); print }
' "$CRITERIA" 2>/dev/null | tr -d '[:space:]')
if [ -z "$GOAL" ] || is_placeholder "$GOAL"; then
  fail_with "criteria carry no captain literal under '# Ideal state'" \
    "quote the captain's own words as a '> ' line under a '# Ideal state' heading in $CRITERIA"
fi

IDS=$(grep -oE '^##[[:space:]]*AC-[0-9]+' "$CRITERIA" 2>/dev/null | grep -oE 'AC-[0-9]+' || true)
if [ -z "$IDS" ]; then
  fail_with "criteria list no AC-N entries" \
    "add at least one '## AC-N' section with claim/source/origin/probe to $CRITERIA"
  printf 'REFUSED: %s is not dispatchable\n' "$ID"
  exit 1
fi

field_of() {
  # field_of <id> <key> -> value text (empty when absent)
  awk -v want="$1" -v key="$2" '
    $0 ~ "^##[[:space:]]*"want"([^0-9]|$)" { inblock=1; next }
    inblock && /^##/ { inblock=0 }
    inblock {
      if (match($0, "^[[:space:]]*"key":")) {
        sub("^[[:space:]]*"key":[[:space:]]*", "")
        print
      }
    }
  ' "$3" 2>/dev/null | head -1
}

CAPTAIN_SOURCED=0
ANTI_PRESENT=0
BRIEF_TEXT=$(cat "$BRIEF" 2>/dev/null || true)

for id in $IDS; do
  claim=$(field_of "$id" claim "$CRITERIA")
  source=$(field_of "$id" source "$CRITERIA")
  origin=$(field_of "$id" origin "$CRITERIA")
  probe=$(field_of "$id" probe "$CRITERIA")
  anti=$(field_of "$id" anti "$CRITERIA")

  # An untouched scaffold slot counts as absent, never as content.
  claim=$(unfilled "$claim")
  source=$(unfilled "$source")
  origin=$(unfilled "$origin")
  probe=$(unfilled "$probe")
  anti=$(unfilled "$anti")

  [ -n "$claim" ] || fail_with "$id has no claim:" "state $id as a falsifiable end state in $CRITERIA"
  [ -n "$probe" ] || fail_with "$id names no probe:" \
    "name the command or observation that decides $id; if you cannot name one, the criterion is too coarse - split it"

  if [ -z "$source" ]; then
    fail_with "$id has no source:" "tag $id with one of: $SOURCES"
  else
    case " $SOURCES " in
      *" $source "*) : ;;
      *) fail_with "$id has an unrecognized source: $source" "use one of: $SOURCES" ;;
    esac
    if [ "$source" = "captain" ]; then
      if [ -n "$origin" ]; then
        CAPTAIN_SOURCED=1
      else
        fail_with "$id claims source: captain with no origin:" \
          "quote the captain's actual words in $id's origin:, or retag $id as inferred"
      fi
    elif [ -z "$origin" ]; then
      fail_with "$id has no origin:" "name where $id came from - a report path, a finding, a reference"
    fi
  fi

  [ -n "$anti" ] && ANTI_PRESENT=1

  # The brief quotes criteria; it never restates them in new words. A paraphrase
  # is how a criterion silently becomes a different criterion between the
  # artifact and the worker.
  if [ -n "$claim" ]; then
    case "$BRIEF_TEXT" in
      *"$claim"*) : ;;
      *) fail_with "$id's claim does not appear verbatim in the brief" \
           "the brief must quote $id's claim as written; regenerate it with bin/fm-brief.sh so the copy is mechanical" ;;
    esac
  fi
done

if [ "$CAPTAIN_SOURCED" -eq 0 ]; then
  fail_with "no criterion traces to the captain" \
    "at least one AC must carry source: captain with his own words in origin:. If nothing here traces to something the captain asked for, this work has no mandate - take it back to him rather than dispatching it"
fi

if [ "$ANTI_PRESENT" -eq 0 ]; then
  fail_with "no criterion carries an anti: line" \
    "name, on at least one AC, what a vacuous pass would look like - a criterion that cannot fail proves nothing"
fi

if [ "$FAILED" -ne 0 ]; then
  printf 'REFUSED: %s is not dispatchable\n' "$ID"
  exit 1
fi

printf 'PASS: %s criteria trace to the captain and each names its probe\n' "$ID"
exit 0
