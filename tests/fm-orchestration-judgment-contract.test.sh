#!/usr/bin/env bash
# Contract regression for Firstmate's evidence-not-authority prime directive.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
SECTION_ONE=$(sed -n '1,/^## 2\./p' "$AGENTS")

assert_contains "$SECTION_ONE" 'Treat every delegated or tool-produced conclusion as evidence, never authority' \
  "AGENTS.md does not load independent orchestration judgment as a prime directive"
assert_contains "$SECTION_ONE" "reconstruct the captain-approved ideal state from the captain's intent and project truth" \
  "AGENTS.md does not require reconstructing the captain-approved ideal state"
assert_contains "$SECTION_ONE" 'inspect the primary evidence' \
  "AGENTS.md does not require inspecting primary evidence"
assert_contains "$SECTION_ONE" 'distinguish proven facts, assumptions, uncertainty or confidence limits, and contradictions' \
  "AGENTS.md does not require distinguishing evidence, uncertainty, and contradictions"
assert_contains "$SECTION_ONE" 'decide the real implication and recommended action' \
  "AGENTS.md does not require independent implication analysis and recommendation"
assert_contains "$SECTION_ONE" 'Never adopt or forward a conclusion merely because' \
  "AGENTS.md does not prohibit adopting delegated or tool conclusions on assertion alone"
# shellcheck disable=SC2016 # Single-quoted contract text intentionally preserves literal Markdown backticks.
assert_contains "$SECTION_ONE" 'use this response shape: `Question (verbatim): <full original question>` followed by `Firstmate analysis: <independent implication analysis>` and `Recommendation: <recommended captain action>`' \
  "AGENTS.md does not require the verbatim question alongside independent analysis and recommendation"
assert_contains "$SECTION_ONE" 'Never omit, paraphrase, merge into analysis, or answer the quoted question for the captain' \
  "AGENTS.md does not protect the captain-owned question from omission or paraphrase"
assert_grep 'a gate verdict is an input to Firstmate' "$AGENTS" \
  "validation workflow does not apply the evidence-not-authority rule at its highest-risk boundary"
assert_no_grep 'Relay the findings to the captain' "$AGENTS" \
  "scout workflow still instructs Firstmate to forward findings without synthesis"
assert_no_grep 'relayed verbatim unless routine approval' "$AGENTS" \
  "captain escalation still treats a review verdict as authority"

pass "Firstmate must independently synthesize delegated findings before acting or reporting"
