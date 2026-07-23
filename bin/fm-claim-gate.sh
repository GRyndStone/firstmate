#!/usr/bin/env bash
# Stop-event claim gate for the firstmate PRIMARY session only.
#
# AGENTS.md section 1 hard rule 5 requires treating every delegated or
# tool-produced conclusion as evidence and never as authority. That rule is
# prose. Prose without mechanical enforcement decays: the rule was in force for
# four consecutive repair rounds while this primary forwarded a verifier's
# conclusion to the captain as its own finding, every single round, and nothing
# noticed.
#
# This is that rule with teeth, in the one shape that has been shown to work:
# THE MESSAGE IS A CLAIM; THE TRANSCRIPT IS THE EVIDENCE. When the final message
# asserts an outcome as established fact and the turn ran no command of
# firstmate's own that could have falsified it, the claim came from somewhere
# else - a report, a status line, a worker, a memory - and the turn is blocked.
#
# Design constraints, each load-bearing:
#   * It grades the TRANSCRIPT, not the prose. An earlier generation of this
#     idea elsewhere graded the message's own wording and died of it, because a
#     wording gate teaches you to reword. Here, rewording cannot pass; probing
#     or downgrading can.
#   * An honest downgrade always passes. "The verifier reports X; I have not
#     confirmed it" is a correct message and must never be blocked. That is what
#     makes the gate reward honesty instead of punishing disclosure.
#   * It blocks at most once per turn (stop_hook_active), so it can never spin
#     the turn. A blocked Stop re-emits the whole response, which is expensive;
#     only a substantive claim is worth that, never a formatting nit.
#   * It fails open everywhere: wrong checkout, no jq, unreadable transcript,
#     malformed payload. A guard that breaks the session is worse than no guard.
#   * Kill switch: FM_CLAIM_GATE_OFF=1.
#
# Ships as TRACKED material, so this file is checked out into every worktree of
# this repo. It must scope itself to the PRIMARY at runtime and stay a fast,
# silent no-op everywhere else, exactly as bin/fm-turnend-guard.sh does.
set -u

[ "${FM_CLAIM_GATE_OFF:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# --- scope precisely to the PRIMARY checkout --------------------------------
# Same predicate as bin/fm-turnend-guard.sh: secondmate homes carry a marker,
# and a linked worktree's git-dir differs from the shared common git-dir, so
# only the main non-worktree checkout has the two equal.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$STATE" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# --- loop safety -------------------------------------------------------------
# One block per turn, always. The forced continuation is the primary's chance to
# probe or downgrade; a second block would spin the turn without adding
# information.
STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

MESSAGE=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
[ -n "$MESSAGE" ] || exit 0

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
MSG_LC=$(lower "$MESSAGE")

# --- the honest-downgrade escape --------------------------------------------
# Attribution and uncertainty are the CORRECT way to report a delegated result.
# A message that names its source, or states that firstmate has not confirmed
# the result itself, is already compliant with hard rule 5 and must pass
# untouched. This escape is deliberately generous: the gate exists to make
# honesty cheaper than assertion, not to make disclosure risky.
DOWNGRADES='reports that|reported that|the report says|according to the report|per the report|the verifier|claims to|claims that|i have not confirmed|i have not independently|not independently confirmed|not independently verified|unverified|unconfirmed|have not verified|without independent|on their report|on its report|taking .* at face value|evidence i have not'
if printf '%s' "$MSG_LC" | grep -Eq "$DOWNGRADES"; then
  exit 0
fi

# --- the claim detector ------------------------------------------------------
# Strong, unhedged assertions that a piece of work reached a verified end state.
# Kept narrow on purpose: a broad detector fires on ordinary conversation, gets
# switched off, and then protects nothing.
CLAIMS='checks are green|checks green|ci is green|ci passed|build is green|tests pass|tests are passing|all tests pass|suite passes|is verified|has been verified|i verified|independently confirmed|is fixed|now works|working correctly|no issues found|nothing blocking|nothing is blocking|has converged|is merged|was merged|merged cleanly|ready to merge|is ready for review|is complete|completed successfully'
printf '%s' "$MSG_LC" | grep -Eq "$CLAIMS" || exit 0

# --- the evidence test -------------------------------------------------------
# Did THIS turn run any command of firstmate's own? A Bash tool call is the only
# way this primary can probe anything: read a file with a shell, run a test,
# check a PR, inspect a worktree. Zero Bash calls in a turn that asserts a
# verified outcome means the assertion was inherited, not established.
#
# Bounded tail: Stop hooks must be fast, and the current turn is always at the
# end of the transcript.
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -n "$TRANSCRIPT" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0

RAN_COMMAND=$(tail -n 600 "$TRANSCRIPT" 2>/dev/null | jq -rs '
  # Locate the last genuine captain prompt. Tool results also arrive as "user"
  # entries, so a genuine prompt is one whose content is a bare string or whose
  # content array carries a text block and no tool_result block.
  def genuine_user:
    (.type == "user")
    and (
      (.message.content | type == "string")
      or (
        (.message.content | type == "array")
        and ((.message.content | map(select(.type == "tool_result")) | length) == 0)
        and ((.message.content | map(select(.type == "text")) | length) > 0)
      )
    );
  . as $all
  | ([range(0; ($all | length)) | select($all[.] | genuine_user)] | last) as $start
  | (if $start == null then $all else $all[$start:] end)
  | map(select(.type == "assistant"))
  | map(.message.content // [] | map(select(.type == "tool_use" and .name == "Bash")) | length)
  | add // 0
  | if . > 0 then "yes" else "no" end
' 2>/dev/null || echo "yes")

# Any parse trouble resolves to "yes" above: fail open, never block on a
# transcript this script could not read.
[ "$RAN_COMMAND" = "no" ] || exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  UNVERIFIED CLAIM - THE MESSAGE ASSERTS AN OUTCOME THIS TURN DID NOT ESTABLISH\n'
  printf '●  The reply states a verified end state, and this turn ran no command of\n'
  printf '●  its own that could have falsified it. That conclusion was inherited from a\n'
  printf '●  worker, a report, or a status line - which AGENTS.md section 1 rule 5 says\n'
  printf '●  is evidence, never authority.\n'
  printf '●\n'
  printf '●  Two ways past this, and rewording is not one of them:\n'
  printf '●    probe it     - run the check yourself, then report what you observed.\n'
  printf '●    downgrade it - name the source and say plainly that you have not\n'
  printf '●                   confirmed it. An attributed claim always passes.\n'
  printf '●%s\n' "$rule"
} >&2
exit 2
