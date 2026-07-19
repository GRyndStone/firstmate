#!/usr/bin/env bash
# Contract tests for Firstmate's private no-mistakes workflow and operator references.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

workflow="$ROOT/.github/workflows/no-mistakes-required.yml"
contributing="$ROOT/CONTRIBUTING.md"
marker='Updates from [git push no-mistakes](https://github.com/GRyndStone/no-mistakes)'

grep -F "marker='$marker'" "$workflow" >/dev/null \
  || fail "required PR signature marker does not reference the canonical private repository"
grep -F 'https://github.com/GRyndStone/no-mistakes' "$contributing" >/dev/null \
  || fail "contribution guidance does not reference the canonical private repository"

legacy_owner='kunchenguid'
legacy_repo='no-mistakes'
private_suffix='-private'
for forbidden in \
  "github.com/$legacy_owner/$legacy_repo" \
  "raw.githubusercontent.com/$legacy_owner/$legacy_repo" \
  "$legacy_repo$private_suffix" \
  "GRyndStone/$legacy_repo$private_suffix"
do
  if git -C "$ROOT" grep -n -F "$forbidden"; then
    fail "active tracked Firstmate files contain forbidden no-mistakes reference: $forbidden"
  fi
done

pass "private no-mistakes workflow and operator references are canonical"
