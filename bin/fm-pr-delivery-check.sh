#!/usr/bin/env bash
# Verify a pull request's delivery path against firstmate's opt-in no-mistakes rule.
#
# Default delivery is direct-PR: a PR body without the no-mistakes pipeline
# signature is accepted. Explicit no-mistakes mode still fails closed without
# the deterministic signature no-mistakes writes into the PR body.
#
# Usage:
#   fm-pr-delivery-check.sh
#     Reads PR body from PR_BODY (or --body-file) and optional labels from
#     PR_LABELS (comma-separated) or --labels.
#
# Exit codes:
#   0  accepted (direct-PR, or no-mistakes with signature)
#   1  rejected (explicit no-mistakes required but signature missing)
#   2  usage error
#
# Explicit no-mistakes is required when any of:
#   - a label exactly equal to "no-mistakes" is present
#   - the PR body contains a line "delivery: no-mistakes" (case-insensitive;
#     optional surrounding whitespace; optional trailing comment after the value)
#
# The no-mistakes signature marker is owned here as the single CI match string;
# CONTRIBUTING.md and tests cross-reference this script rather than restating it.
set -eu

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

# Canonical signature substring written by private no-mistakes into PR bodies.
FM_NO_MISTAKES_PR_MARKER='Updates from [git push no-mistakes](https://github.com/GRyndStone/no-mistakes)'

BODY=
LABELS=${PR_LABELS:-}
BODY_FROM_ENV=0
[ -n "${PR_BODY+x}" ] && BODY_FROM_ENV=1 && BODY=${PR_BODY:-}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --body-file)
      [ "$#" -ge 2 ] || { echo "usage: --body-file needs a path" >&2; exit 2; }
      BODY=$(cat "$2")
      BODY_FROM_ENV=0
      shift 2
      ;;
    --labels)
      [ "$#" -ge 2 ] || { echo "usage: --labels needs a value" >&2; exit 2; }
      LABELS=$2
      shift 2
      ;;
    --marker)
      # Test override only; production workflow uses the built-in constant.
      [ "$#" -ge 2 ] || { echo "usage: --marker needs a value" >&2; exit 2; }
      FM_NO_MISTAKES_PR_MARKER=$2
      shift 2
      ;;
    --print-marker)
      printf '%s\n' "$FM_NO_MISTAKES_PR_MARKER"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$BODY_FROM_ENV" -eq 0 ] && [ -z "${BODY+x}" ]; then
  # No --body-file and PR_BODY unset: treat as empty direct-PR body.
  BODY=
fi

body_has_signature() {
  printf '%s' "$BODY" | grep -qF -- "$FM_NO_MISTAKES_PR_MARKER"
}

explicit_no_mistakes_required() {
  local lab
  # Labels: comma or newline separated; exact token match.
  if [ -n "$LABELS" ]; then
    while IFS= read -r lab; do
      lab=${lab#"${lab%%[![:space:]]*}"}
      lab=${lab%"${lab##*[![:space:]]}"}
      [ -n "$lab" ] || continue
      if [ "$lab" = no-mistakes ]; then
        return 0
      fi
    done <<EOF
$(printf '%s' "$LABELS" | tr ',' '\n')
EOF
  fi
  # Body declaration: delivery: no-mistakes
  if printf '%s\n' "$BODY" | grep -qiE '^[[:space:]]*delivery:[[:space:]]*no-mistakes([[:space:]]|#|$)'; then
    return 0
  fi
  return 1
}

if body_has_signature; then
  echo "Accepted: no-mistakes signature present."
  exit 0
fi

if explicit_no_mistakes_required; then
  {
    echo "::error::This PR requires the no-mistakes delivery path but the PR body is missing the pipeline signature."
    echo
    echo "Explicit no-mistakes mode was selected (label 'no-mistakes' and/or a"
    echo "'delivery: no-mistakes' line in the PR body)."
    echo "Submit via 'git push no-mistakes' so the pipeline writes:"
    echo
    echo "    $FM_NO_MISTAKES_PR_MARKER"
    echo
    echo "See CONTRIBUTING.md. For ordinary direct-PR work, omit the no-mistakes"
    echo "label and delivery line; focused tests/lint plus gh-axi are enough."
  } >&2
  exit 1
fi

echo "Accepted: direct-PR path (no-mistakes signature not required)."
exit 0
