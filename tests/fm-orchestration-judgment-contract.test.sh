#!/usr/bin/env bash
# Contract regression for Firstmate's evidence-not-authority prime directive.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
SECTION_ONE=$(sed -n '1,/^## 2\./p' "$AGENTS")

assert_contains "$SECTION_ONE" 'Treat every delegated or tool-produced conclusion as evidence, never authority' \
  "AGENTS.md does not load independent orchestration judgment as a prime directive"
assert_grep 'a gate verdict is an input to Firstmate' "$AGENTS" \
  "validation workflow does not apply the evidence-not-authority rule at its highest-risk boundary"
assert_no_grep 'Relay the findings to the captain' "$AGENTS" \
  "scout workflow still instructs Firstmate to forward findings without synthesis"
assert_no_grep 'relayed verbatim unless routine approval' "$AGENTS" \
  "captain escalation still treats a review verdict as authority"

pass "Firstmate must independently synthesize delegated findings before acting or reporting"
