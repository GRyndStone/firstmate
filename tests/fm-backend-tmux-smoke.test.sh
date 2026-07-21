#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
fm_test_add_cleanup cleanup_all

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
fm_test_tmproot SHIM_DIR fm-backend-smoke
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
WID=$(fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME") \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ '" Enter
sleep 0.3
tmux send-keys -t "$TARGET" -l "clear" ; tmux send-keys -t "$TARGET" Enter
sleep 0.3

fm_backend_tmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "fm_backend_tmux_send_literal failed"
sleep 0.2
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
sleep 0.6
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- strict existence probe, live window --------------------------------------
# Regression for the endpoint-gone corroboration (docs/tmux-backend.md "Strict
# window-existence probe"): a legitimately-alive window must read alive in every
# target shape callers record, so recovery digests never misread live crews.

PANE_ID=$(tmux list-panes -t "$WID" -F '#{pane_id}') || fail "could not read the task window's pane id"
fm_backend_target_exists tmux "$TARGET" "$WINDOW" \
  || fail "strict probe: live session:name target with label read as gone"
fm_backend_target_exists tmux "$TARGET" \
  || fail "strict probe: live session:name target without label read as gone"
fm_backend_target_exists tmux "$WID" "$WINDOW" \
  || fail "strict probe: live window-id target with label read as gone"
fm_backend_target_exists tmux "$PANE_ID" \
  || fail "strict probe: live pane-id target read as gone"
if fm_backend_target_exists tmux "$WID" "fm-some-other-label"; then
  fail "strict probe: a live window id must not satisfy a mismatched expected label"
fi
pass "real tmux: fm_backend_target_exists reads a live window alive in every recorded target shape"

# --- strict existence probe, pane-qualified and session-qualified shapes -------
# Regression for the option-C shape extension (docs/tmux-backend.md "Strict
# window-existence probe"): explicit user-supplied targets like
# `session:window.pane` (fm-send explicit targets, FM_SUPERVISOR_TARGET
# overrides) must read alive strictly while present, and a shape the strict
# parser does not model must fall back to the lenient resolution probe rather
# than reading gone.

PANE_IDX=$(tmux display-message -p -t "$WID" '#{pane_index}') || fail "could not read the task window's pane index"
WIN_IDX=$(tmux display-message -p -t "$WID" '#{window_index}') || fail "could not read the task window's index"
fm_backend_target_exists tmux "$SESSION:$WINDOW.$PANE_IDX" \
  || fail "strict probe: live session:window.pane-index target read as gone"
fm_backend_target_exists tmux "$SESSION:$WINDOW.$PANE_ID" \
  || fail "strict probe: live session:window.pane-id target read as gone"
fm_backend_target_exists tmux "$SESSION:$WIN_IDX.$PANE_IDX" \
  || fail "strict probe: live session:window-index.pane-index target read as gone"
fm_backend_target_exists tmux "$SESSION:$PANE_ID" \
  || fail "strict probe: live session-qualified pane-id target read as gone"
if fm_backend_target_exists tmux "$SESSION:$WINDOW.99"; then
  fail "strict probe: a nonexistent pane index on a live window must read gone"
fi
pass "real tmux: fm_backend_target_exists reads pane-qualified and session-qualified pane targets alive strictly"

fm_backend_target_exists tmux "=$SESSION:$WINDOW" \
  || fail "lenient fallback: an unrecognized =exact-prefixed target read as gone while resolvable"
fm_backend_target_exists tmux "$SESSION:$WINDOW.{top-left}" \
  || fail "lenient fallback: an unrecognized {marker} pane specifier read as gone while resolvable"
pass "real tmux: unrecognized explicit target shapes fall back to the lenient resolution probe instead of reading gone"

# --- strict existence probe, glob shapes and label-aware strictness -----------
# Regression for the option-B label-aware rule (docs/tmux-backend.md "Strict
# window-existence probe"): a glob window part is pattern syntax, never a
# literal fm-<id> task name, so it resolves leniently even though it parses as
# session:name; a label-less literal session:name that strict-misses (tmux
# also resolves unique name prefixes) retries leniently instead of
# false-reading gone; a labeled strict miss stays a confident gone.

WINDOW_PREFIX=${WINDOW%?}
fm_backend_target_exists tmux "$SESSION:${WINDOW_PREFIX}*" \
  || fail "glob routing: a resolvable session:name glob target read as gone instead of resolving leniently"
fm_backend_target_exists tmux "$SESSION:$WINDOW_PREFIX" \
  || fail "label-aware fallback: a label-less unique-name-prefix target read as gone while tmux resolves it"
if fm_backend_target_exists tmux "$SESSION:$WINDOW_PREFIX" "$WINDOW"; then
  fail "label-aware strictness: a labeled strict miss must stay gone, not retry leniently"
fi
pass "real tmux: glob window parts resolve leniently and label-less literal misses retry leniently while labeled misses stay gone"

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

# --- strict existence probe, killed window with a SURVIVING session ------------
# THE incident-class regression: `tmux display-message -p -t <gone>` exits 0 by
# silently resolving to another window (tmux 3.7b), so a resolution-based probe
# reads the dead task window as alive and the watcher's endpoint-gone wake never
# fires. The strict inventory match must read it gone while the session lives.

tmux has-session -t "$SESSION" 2>/dev/null \
  || fail "precondition: the session must survive the window kill for this regression"
if fm_backend_target_exists tmux "$TARGET" "$WINDOW"; then
  fail "strict probe: killed window (session surviving) read as alive via session:name"
fi
if fm_backend_target_exists tmux "$WID" "$WINDOW"; then
  fail "strict probe: killed window (session surviving) read as alive via window id"
fi
if fm_backend_target_exists tmux "$PANE_ID"; then
  fail "strict probe: killed window (session surviving) read as alive via pane id"
fi
if fm_backend_target_exists tmux "no-such-session:$WINDOW" "$WINDOW"; then
  fail "strict probe: a nonexistent session read as alive"
fi
if fm_backend_target_exists tmux "$SESSION:$WINDOW.$PANE_IDX"; then
  fail "strict probe: killed window (session surviving) read as alive via session:window.pane"
fi
if fm_backend_target_exists tmux "$SESSION:$PANE_ID"; then
  fail "strict probe: killed window (session surviving) read as alive via session-qualified pane id"
fi
fm_backend_target_exists tmux "$TARGET" \
  || fail "label-aware fallback: a label-less session:name miss must retry leniently (deliberate fail-open for explicit targets), not read gone"
pass "real tmux: fm_backend_target_exists reads a killed window as gone while its session survives"

# The watcher's endpoint-gone trigger for ordinary crews is a FAILED capture
# (bin/fm-watch.sh), so capture-pane must not share display-message's lenient
# resolution and quietly read another window's pane instead. Pin the verified
# behavior (docs/tmux-backend.md "Strict window-existence probe", 2026-07-12):
# capture-pane fails outright on a killed window whose session survives.
if fm_backend_tmux_capture "$TARGET" 40 >/dev/null 2>&1; then
  fail "fm_backend_tmux_capture leniently resolved a killed window (session surviving) instead of failing - the watcher's endpoint-gone trigger would never fire"
fi
pass "real tmux: fm_backend_tmux_capture fails on a killed window while its session survives"

# --- strict existence probe, whole server down ---------------------------------

tmux kill-server >/dev/null 2>&1 || true
if fm_backend_target_exists tmux "$TARGET" "$WINDOW"; then
  fail "strict probe: a downed server read as alive"
fi
if fm_backend_target_exists tmux "$TARGET"; then
  fail "strict probe: a downed server read as alive via the label-less lenient fallback"
fi
pass "real tmux: fm_backend_target_exists reads a downed server as gone"

# EXIT trap (fm_test_cleanup + session hook) tears down the private socket and SHIM_DIR.
