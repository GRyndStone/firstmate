#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here. That extraction preserved the original command order; later lifecycle
# hardening added stable window ids and exact-home ownership tags. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> [home-identity] -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 home_identity=${4:-} wid filter inventory
  if [ -z "$home_identity" ]; then
    home_identity=$(fm_backend_home_identity) || return 1
  fi
  filter="#{==:#{window_name},$wname}"
  inventory=$(tmux list-windows -t "=$ses" -f "$filter" \
    -F $'#{window_id}\t#{window_name}\t#{@firstmate_home}\t_' 2>/dev/null) || return 1
  if [ -n "$inventory" ] && ! printf '%s\n' "$inventory" | awk -F '\t' -v label="$wname" '
    NF != 4 || $1 !~ /^@[0-9]+$/ || $2 != label || $4 != "_" { bad=1 }
    END { exit bad ? 1 : 0 }
  '; then
    echo "error: invalid tmux window inventory for $ses:$wname" >&2
    return 1
  fi
  if printf '%s\n' "$inventory" | awk -F '\t' -v owner="$home_identity" 'NF == 4 && $3 == owner { found=1 } END { exit found ? 0 : 1 }'; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  if printf '%s\n' "$inventory" | awk -F '\t' 'NF == 4 && $3 == "" { found=1 } END { exit found ? 0 : 1 }'; then
    echo "error: untagged legacy window $ses:$wname has ambiguous Firstmate-home ownership" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  if ! tmux set-window-option -t "$wid" @firstmate_home "$home_identity" 2>/dev/null; then
    tmux kill-window -t "$wid" 2>/dev/null || true
    return 1
  fi
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_probe_lenient: tmux's own target resolution as an existence
# read - `display-message` exits 0 whenever the target resolves and fails only
# when it cannot (no server on the socket being the common case). Kept ONLY as
# the fail-open fallback for explicit user-supplied target shapes the strict
# parser below does not recognize (an fm-send.sh explicit target, an
# FM_SUPERVISOR_TARGET daemon override), so an exotic-but-valid tmux target can
# never false-read as gone. Recognized task-shaped targets never reach it,
# because resolution is lenient enough to read a killed window as alive.
fm_backend_tmux_probe_lenient() {  # <target>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

# fm_backend_tmux_strict_miss: verdict for a literal-name window target the
# strict inventory match missed. Task-shaped call sites (the watcher's
# handle_gone_endpoint, the session-start and recovery digests, the fleet
# snapshot) pass the recorded fm-<id> as <expected-label>, and recorded
# window= metas are always literal, so a labeled miss is a confident gone. A
# label-less miss comes from the explicit user-supplied entry points (an
# fm-send explicit backend target, an FM_SUPERVISOR_TARGET daemon override),
# where tmux also resolves unique name prefixes the inventory match cannot
# model, so it falls back to the lenient resolution probe rather than
# false-reading a resolvable target as gone.
fm_backend_tmux_strict_miss() {  # <target> <expected-label>
  [ -n "$2" ] && return 1
  fm_backend_tmux_probe_lenient "$1"
}

# fm_backend_tmux_target_exists: strict existence probe backing
# fm_backend_target_exists's tmux arm. tmux's own target resolution is
# LENIENT: `tmux display-message -p -t <target>` exits 0 for a killed window
# whose session survives (it silently resolves the target to another window)
# and even for a nonexistent session - it only fails when no server is
# running on the socket (verified on tmux 3.7b; docs/tmux-backend.md "Strict
# window-existence probe"). So existence is an exact match against the
# server's own inventory - the same list-then-match shape as
# fm_backend_tmux_create_task's duplicate check - never a target-resolution
# probe. Recognized shapes, matched strictly: a pane id (%N - the away-mode
# daemon's TMUX_PANE supervisor target), a window id (@N - fm-spawn's stable
# window handle), session:name or session:index (supported explicit or legacy
# targets, including the daemon's firstmate:0 default), a bare window name, a
# session-qualified pane id (session:%N), and a pane-qualified window
# (session:window.pane, the window by exact name or index and the pane by
# index or %id, matched as one composite line against the pane inventory so a
# window name containing dots still matches whole). A window-id match also
# requires <expected-label> as the window name when given, so a recycled id
# after a server restart never reads as the recorded task. Any OTHER shape
# (session ids, =exact prefixes, {marker} pane specifiers, offset tokens) is
# not modeled here and falls back to fm_backend_tmux_probe_lenient rather
# than reading gone. Two further fail-open rules protect explicitly
# user-supplied targets: a window part containing a glob metacharacter
# (* ? [) is fnmatch pattern syntax, never a literal fm-<id> task window
# name, and routes straight to the lenient probe; and a literal session:name
# or session:index miss reads gone only when <expected-label> was passed
# (the task-shaped call sites), while a label-less miss retries leniently so
# a unique-name-prefix target never false-reads as gone
# (fm_backend_tmux_strict_miss above). Pane-id and window-id shapes stay
# strict regardless - they are exact identifiers, never patterns or
# prefixes. A downed server fails the listing - and the fallback probe - and
# reads gone, exactly as before.
fm_backend_tmux_target_exists() {  # <target> [expected-label]
  local target=$1 expected=${2:-} ses='' win='' pane='' pane_fmt=''
  case "$target" in
    %*)
      case "${target#%}" in
        ''|*[!0-9]*) fm_backend_tmux_probe_lenient "$target"; return ;;
      esac
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF -- "$target"
      return
      ;;
    *:*)
      ses=${target%%:*}; win=${target#*:}
      if [ -z "$ses" ] || [ -z "$win" ]; then
        fm_backend_tmux_probe_lenient "$target"; return
      fi
      case "$ses" in
        '$'*|'='*) fm_backend_tmux_probe_lenient "$target"; return ;;
      esac
      ;;
    *) win=$target ;;
  esac
  case "$win" in
    @*)
      case "${win#@}" in
        ''|*[!0-9]*) fm_backend_tmux_probe_lenient "$target"; return ;;
      esac
      if [ -n "$expected" ]; then
        tmux list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null | grep -qxF -- "$win $expected"
      else
        tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF -- "$win"
      fi
      return
      ;;
    %*)
      case "${win#%}" in
        ''|*[!0-9]*) fm_backend_tmux_probe_lenient "$target"; return ;;
      esac
      tmux list-panes -a -F '#{session_name}:#{pane_id}' 2>/dev/null | grep -qxF -- "$ses:$win"
      return
      ;;
    *[*?[]*) fm_backend_tmux_probe_lenient "$target"; return ;;
  esac
  if [ -n "$ses" ]; then
    tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -qxF -- "$ses:$win" \
      && return 0
    # An index-based window part (the daemon's firstmate:0 default) is not a
    # window NAME; retry against the index inventory before reading gone.
    case "$win" in
      *[!0-9]*) ;;
      *)
        tmux list-windows -a -F '#{session_name}:#{window_index}' 2>/dev/null | grep -qxF -- "$ses:$win" \
          && return 0
        fm_backend_tmux_strict_miss "$target" "$expected"
        return
        ;;
    esac
    case "$win" in
      *.*) ;;
      *) fm_backend_tmux_strict_miss "$target" "$expected"; return ;;
    esac
    # Pane-qualified window part (session:window.pane): recognize a pane index
    # or a %id after the LAST dot; anything else after it is an unmodeled pane
    # specifier and falls back to the lenient probe.
    pane=${win##*.}
    case "$pane" in
      %*)
        case "${pane#%}" in
          ''|*[!0-9]*) fm_backend_tmux_probe_lenient "$target"; return ;;
        esac
        pane_fmt='#{pane_id}'
        ;;
      ''|*[!0-9]*) fm_backend_tmux_probe_lenient "$target"; return ;;
      *) pane_fmt='#{pane_index}' ;;
    esac
    tmux list-panes -a -F "#{session_name}:#{window_name}.$pane_fmt" 2>/dev/null | grep -qxF -- "$ses:$win" \
      && return 0
    case "${win%.*}" in
      *[!0-9]*) return 1 ;;
      *) tmux list-panes -a -F "#{session_name}:#{window_index}.$pane_fmt" 2>/dev/null | grep -qxF -- "$ses:$win" ;;
    esac
  else
    tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qxF -- "$win" && return 0
    # A dotted bare name could equally be tmux's window.pane shorthand with no
    # session part; that shape is not modeled strictly, so fail open.
    case "$win" in
      *.*) fm_backend_tmux_probe_lenient "$target" ;;
      *) return 1 ;;
    esac
  fi
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove the task's window, best-effort. Mirrors
# fm-teardown.sh's `tmux kill-window -t "$T" 2>/dev/null || true`.
fm_backend_tmux_kill() {  # <target>
  if [ "${FM_BACKEND_STRICT_CLOSE:-0}" = 1 ]; then
    tmux kill-window -t "$1" 2>/dev/null
  else
    tmux kill-window -t "$1" 2>/dev/null || true
  fi
}

fm_backend_tmux_kill_owned() {  # <target> <session> <expected-label> <home-identity>
  local target=$1 session=$2 expected_label=$3 home_identity=$4 condition out
  condition="#{&&:#{==:#{window_id},$target},#{&&:#{==:#{session_name},$session},#{&&:#{==:#{window_name},$expected_label},#{==:#{@firstmate_home},$home_identity}}}}"
  out=$(tmux if-shell -F -t "$target" "$condition" \
    "kill-window -t $target" "display-message -p ownership-mismatch" 2>&1) || return 1
  [ -z "$out" ]
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_agent_alive: CONFIDENT liveness of a live harness-agent
# PROCESS in <target>'s pane, distinct from fm_backend_target_exists's
# pane-PRESENCE-only check (a pane that still exists but is sitting at a bare
# idle shell passes THAT check as "alive" - the secondmate-liveness gap
# AGENTS.md's session-start guarantee closes). See docs/tmux-backend.md
# "Agent liveness probe" for the empirical basis. Prints one of:
#   alive   - the foreground command is one of the verified harness binaries
#             (claude, codex, opencode, grok - each confirmed to run as its
#             own process name, never wrapped by a generic interpreter).
#   dead    - the foreground command is a bare shell: nothing is running in
#             the pane, so a prior agent process has exited.
#   unknown - anything else, INCLUDING a bare "node"/"python" interpreter
#             name (pi's own launcher execs into a generic "node" process
#             with no reliable way to attribute it back to pi from outside
#             the pane - docs/tmux-backend.md "Known gaps"), or an unreadable
#             pane. Callers must never treat unknown as a confirmed-dead
#             signal (bin/fm-bootstrap.sh's secondmate-liveness sweep gates a
#             respawn on `dead` only).
fm_backend_tmux_agent_alive() {  # <target>
  local target=$1 comm
  comm=$(fm_backend_tmux_current_command "$target") || { printf 'unknown'; return 0; }
  comm=${comm#-}
  case "$comm" in
    '') printf 'unknown' ;;
    *claude*|*codex*|*opencode*|*grok*) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
