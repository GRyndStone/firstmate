#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed regardless
#                          of what the status log says - an active
#                          run-step, busy pane, or progressing owned command
#                          outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge - and it holds even
#                          while the crew's own run-step is still active; a finished-green
#                          crew (done run-step) parked on positive anchor evidence -
#                          its declared pause or an armed per-task check - absorbs
#                          the same way (crew_absorb_class, fm-classify-lib.sh, owns
#                          that decision). Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A previously working stale whose
#                          positive run-step/pane/owned-command evidence disappears at the wedge
#                          threshold surfaces with an "escalation N" count; at
#                          FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on
#                          the SAME pane, the reason also carries a
#                          "demand-deep-inspection" marker. Current positive busy
#                          evidence always resets the timer and stays quiet, even
#                          when the pane hash is unchanged. Unless afk is active.
#                          A stale reason carrying
#                          "endpoint-gone" (the recorded endpoint no longer
#                          exists) or "agent-dead" (the endpoint exists but the
#                          agent process is confidently dead) means the crew
#                          DIED: it is immediately actionable, never absorbed
#                          into a declared pause, and surfaced once per death
#                          even while afk is active. docs/architecture.md
#                          ("Event-driven supervision") owns those rules.
#   check: <script>: <out> per-task check output, always actionable
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# Durable reconciled task/endpoint observations.  This is evaluated once for
# every recorded task at the start of every classification cycle, before sparse
# status/turn-end events are triaged, so an old status event can never mask a
# newer positive working -> stopped/parked/terminal transition.
# shellcheck source=bin/fm-reconcile-lib.sh
. "$SCRIPT_DIR/fm-reconcile-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
RECONCILE_TASK_TIMEOUT=${FM_RECONCILE_TASK_TIMEOUT:-35}
case "$RECONCILE_TASK_TIMEOUT" in ''|*[!0-9]*|0) RECONCILE_TASK_TIMEOUT=35 ;; esac
RECONCILE_BATCH_DIR=
RECONCILE_BATCH_PIDS=
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, a busy pane, or a progressing task-owned command, via
# crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a stale whose positive working evidence
# disappeared at its recheck threshold, or anything unknown) is written to the
# durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a stale hash revalidates positive working evidence
# A crew that DECLARED a pause (paused: <reason>, fm-classify-lib.sh) is idling on
# a known external wait, so its stale pane is absorbed rather than wedge-escalated;
# it re-surfaces once for a recheck every PAUSE_RESURFACE_SECS - far longer than the
# wedge threshold, but finite so a forgotten pause cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# bin/fm-teardown.sh touches state/<id>.tearing-down just before killing a
# task's endpoint and removes it with the task's other state files, so the
# kill-to-meta-removal gap of a normal teardown reads as teardown, not death.
# The absorb is age-bounded: past this many seconds the tombstone is stale (a
# crashed teardown) and the gone endpoint surfaces normally - fail-closed back
# to waking, never a permanent suppressor.
TEARDOWN_TOMBSTONE_SECS=${FM_TEARDOWN_TOMBSTONE_SECS:-120}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# State-file key for a window (or task) target: ':', '/', and '.' become '_'.
# The ONE derivation of the key every .stale-*/.paused-*/.hash-*/... suffix
# uses; keep every call site on this helper so the idiom cannot drift.
window_key() {  # <target>
  printf '%s' "$1" | tr ':/.' '___'
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3) after its positive working evidence has disappeared. A pane that
# keeps re-wedging on the SAME stale hash can otherwise repeat forever with no
# signal that this is no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll stale-timer bookkeeping for an already-classified hash absorbed as
# provably-working. It repairs a missing/corrupt timer, then revalidates current
# working evidence once STALE_ESCALATE_SECS has elapsed. Positive evidence resets
# the timer and remains quiet even when pane content is unchanged; only loss of
# that evidence can escalate. Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane/owned command outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason task
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        task=$(window_to_task "$win" "$STATE")
        if crew_is_provably_working "$task"; then
          date +%s > "$since_file"
          rm -f "$escalation_file"
          triage_log "absorbed $label after threshold (positive working evidence still current): $win"
        else
          n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
          echo "$n" > "$escalation_file"
          reason="stale: $win (idle ${age}s, positive working evidence disappeared, possible wedge, escalation $n)"
          if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
            reason="stale: $win (idle ${age}s, positive working evidence disappeared, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row)"
          fi
          fm_wake_append stale "$win" "$reason" || exit 1
          rm -f "$since_file"
          wake "$reason"
        fi
      fi
      ;;
  esac
}

# Absorb a stale pane whose crew is in an absorbable park - a DECLARED
# external-wait pause (paused:), or a finished green run behind park-anchor
# evidence (crew_absorb_class) - and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot
# invisibly. Called on any stale poll once the crew is known parked (first sight,
# after crew_absorb_class; and repeat sights, gated by the .paused-<key> flag), so
# it must be cheap: it NEVER re-reads the crew state. The re-surface age is anchored
# on the pause's own STATUS-FILE mtime, not a per-hash marker, so a churny idle pane
# (a ticking clock, a token counter) cannot keep resetting the cadence the way a
# hash-tied timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause or green-run merge park, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=$(window_key "$win")
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=$(window_key "$win")
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.agent-dead-$key"
}

# A recorded endpoint that no longer exists is DEATH, not quiet (the 2026-07-12
# gsd-ideal-state incident: a crew died in a declared pause, its gone pane made
# fm_backend_capture fail, and the old loop silently `continue`d past every
# classification - including the pause re-surface - for hours). Called when a
# crew capture fails, and per poll for non-paused secondmates (whose stale
# detection is skipped). Corroborates the failure with the read-only existence
# probe (fm_backend_target_exists, which never starts a server), so a transient
# capture hiccup on a live endpoint is not misread as death. A confirmed-gone
# endpoint surfaces ONCE per disappearance - the .endpoint-gone-<key> marker
# dedupes until the endpoint reads alive again - regardless of any declared
# pause and regardless of afk. docs/architecture.md ("Event-driven supervision")
# owns the classification rule.
handle_gone_endpoint() {  # <window>
  local w=$1 key marker reason meta tomb tomb_mtime tomb_age
  key=$(window_key "$w")
  marker="$STATE/.endpoint-gone-$key"
  if fm_backend_target_exists "$(window_backend "$w")" "$w" "$(window_label "$w")" 2>/dev/null; then
    rm -f "$marker"
    return 0
  fi
  # Teardown kills the endpoint moments before removing the task's meta
  # (bin/fm-teardown.sh); a window whose meta is already gone mid-cycle was
  # torn down, not lost.
  if ! meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null); then
    triage_log "absorbed endpoint-gone (no meta - torn down mid-cycle): $w"
    return 0
  fi
  # The other half of that race: the meta still exists, but teardown stamped
  # its state/<id>.tearing-down tombstone just before the kill. Absorb only
  # while the tombstone is fresh (TEARDOWN_TOMBSTONE_SECS); a stale or
  # unreadable stamp means a crashed teardown, and the death surfaces normally.
  tomb="${meta%.meta}.tearing-down"
  if [ -e "$tomb" ]; then
    tomb_mtime=$(stat_mtime "$tomb")
    case "$tomb_mtime" in ''|*[!0-9]*) tomb_mtime=0 ;; esac
    tomb_age=$(( $(date +%s) - tomb_mtime ))
    if [ "$tomb_mtime" -gt 0 ] && [ "$tomb_age" -lt "$TEARDOWN_TOMBSTONE_SECS" ]; then
      triage_log "absorbed endpoint-gone (teardown in progress, tombstone ${tomb_age}s old): $w"
      return 0
    fi
    triage_log "ignoring stale teardown tombstone (${tomb_age}s old, bound ${TEARDOWN_TOMBSTONE_SECS}s): $w"
  fi
  if [ -e "$marker" ]; then
    triage_log "absorbed endpoint-gone (already surfaced): $w"
    return 0
  fi
  reason="stale: $w endpoint-gone (recorded backend endpoint no longer exists - the crew is dead, not quiet, whatever its last status says; recover it instead of resuming routine supervision)"
  fm_wake_append stale "$w" "$reason" || exit 1
  : > "$marker"
  clear_pause_tracking "$w"
  wake "$reason"
}

# Bounded CONFIDENT-dead probe of a paused crew's agent process
# (fm_backend_agent_alive). dead -> 0. alive clears any stale .agent-dead-<key>
# surfaced marker so a respawned crew's NEXT death re-surfaces; ambiguous or
# errored reads (unknown) NEVER count as dead - the same fail-closed principle
# as the secondmate liveness sweep. Callers keep this off the per-poll path: it
# runs only on first sight of a paused stale hash and on the bounded
# paused-recheck cadence (pause_state_class), never every cheap poll.
paused_agent_is_dead() {  # <window>
  local w=$1 key verdict
  key=$(window_key "$w")
  verdict=$(fm_backend_agent_alive "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$verdict" in
    dead) return 0 ;;
    alive) rm -f "$STATE/.agent-dead-$key"; return 1 ;;
    *) return 1 ;;
  esac
}

# Surface a paused crew whose endpoint exists but whose agent process is
# confidently dead - once per death (.agent-dead-<key> dedupes; cleared only on
# positive liveness - a busy pane or an alive probe read - or when pause
# tracking clears, never on pane-hash churn alone, and surfaced regardless of
# afk so the away-mode daemon receives the death verdict rather than a plain
# stale). Keeps the pause bookkeeping (paused flag plus a fresh recheck stamp)
# so subsequent polls absorb through the normal bounded pause cadence instead of
# re-probing every poll. Enqueue precedes the suppressor writes, matching the
# enqueue-before-suppress ordering everywhere else.
handle_dead_agent() {  # <window> <hash>
  local win=$1 h=$2 key reason
  key=$(window_key "$win")
  if [ -e "$STATE/.agent-dead-$key" ]; then
    printf '%s' "$h" > "$STATE/.stale-$key"
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    triage_log "absorbed agent-dead (already surfaced): $win"
    return 0
  fi
  reason="stale: $win agent-dead (endpoint exists but the agent process is confidently dead - the crew died in its declared wait; recover it instead of resuming routine supervision)"
  fm_wake_append stale "$win" "$reason" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  date +%s > "$STATE/.paused-rechecked-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  : > "$STATE/.agent-dead-$key"
  wake "$reason"
}

pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key recheck_file class
  key=$(window_key "$win")
  recheck_file="$STATE/.paused-rechecked-$key"
  # Park-anchor gate, not just the paused: verb: a finished-green merge park may
  # be anchored by its armed check script alone (crew_absorb_class), and must
  # keep the same bounded recheck bookkeeping instead of being ejected to a
  # fresh full crew-state read (or a wedge timer) every poll.
  if ! task_has_park_anchor "$task"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    printf 'paused'
    return
  fi
  # Bounded deeper liveness probe, riding the same recheck cadence as the
  # authoritative crew-state read below (never every poll): a paused crew whose
  # endpoint exists but whose agent process is confidently dead is dead, not
  # waiting. Secondmate agent-process liveness stays owned by the session-start
  # sweep (docs/architecture.md "Event-driven supervision").
  if [ "$(window_kind "$win")" != secondmate ] && paused_agent_is_dead "$win"; then
    date +%s > "$recheck_file"
    printf 'dead'
    return
  fi
  class=$(crew_absorb_class "$task")
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key
  key=$(window_key "$win")
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

reconcile_terminate_descendants() {  # <pid>
  local pid=$1 children descendant
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  for descendant in $children; do
    reconcile_terminate_descendants "$descendant"
    kill -TERM "$descendant" 2>/dev/null || true
  done
}

reconcile_worker_signal_cleanup() {
  local active
  for active in ${child:-} $(jobs -pr 2>/dev/null); do
    reconcile_terminate_descendants "$active"
    kill -TERM "$active" 2>/dev/null || true
  done
  for active in ${child:-} $(jobs -pr 2>/dev/null); do
    wait "$active" 2>/dev/null || true
  done
}

reconcile_worker() {  # <id>
  local id=$1 child='' worker_rc
  trap 'reconcile_worker_signal_cleanup; exit 143' TERM INT HUP
  # shellcheck disable=SC2016
  fm_reconcile_bounded "$RECONCILE_TASK_TIMEOUT" bash -c '
    export FM_RECONCILE_CREW_STATE_BIN=$1
    export FM_EXTERNAL_WAIT_TIMEOUT=$2
    . "$3"
    fm_reconcile_observe "$4" "$5"
  ' _ "$FM_RECONCILE_CREW_STATE_BIN" "$FM_EXTERNAL_WAIT_TIMEOUT" \
    "$SCRIPT_DIR/fm-reconcile-lib.sh" "$STATE" "$id" &
  child=$!
  if wait "$child"; then worker_rc=0; else worker_rc=$?; fi
  child=
  trap - TERM INT HUP
  return "$worker_rc"
}

reconcile_batch_cleanup() {
  local pid file batch_dir=$RECONCILE_BATCH_DIR live_pids
  live_pids="$RECONCILE_BATCH_PIDS $(jobs -pr 2>/dev/null)"
  for pid in $live_pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $live_pids; do
    wait "$pid" 2>/dev/null || true
  done
  RECONCILE_BATCH_PIDS=
  case "$batch_dir" in
    "$STATE"/.reconcile-cycle.*)
      for file in "$batch_dir"/*.id "$batch_dir"/*.generation "$batch_dir"/*.out "$batch_dir"/*.err "$batch_dir"/*.rc; do
        [ -e "$file" ] && rm -f "$file"
      done
      rmdir "$batch_dir" 2>/dev/null || true
      ;;
  esac
  RECONCILE_BATCH_DIR=
}

watch_cleanup() {
  reconcile_batch_cleanup
  fm_lock_release "$WATCH_LOCK"
}

# Observe every task's deterministic current state in one bounded parallel batch
# and surface the first pending transition or external-wait action.
# fm-reconcile-lib.sh persists each state and pending token before returning.
# The watcher appends the wake and advances only the represented sparse event
# signatures; the daemon or queue drain acknowledges the token after durable
# consumer handoff.
reconcile_cycle() {
  local meta id target out tag token version evidence reason marker worker_rc failure_evidence err_tail expected_generation
  local batch_dir pids='' pid index=0 selected_id='' selected_token='' selected_version='' selected_evidence=''
  local pending pending_version notified notified_version record_repository record_generation current_generation kind queue_rc=0
  batch_dir=$(mktemp -d "$STATE/.reconcile-cycle.XXXXXX") || exit 1
  RECONCILE_BATCH_DIR=$batch_dir
  RECONCILE_BATCH_PIDS=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    index=$((index + 1))
    printf '%s\n' "$id" > "$batch_dir/$index.id" || exit 1
    expected_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
    printf '%s\n' "$expected_generation" > "$batch_dir/$index.generation" || exit 1
    reconcile_worker "$id" > "$batch_dir/$index.out" 2> "$batch_dir/$index.err" &
    pid=$!
    pids="${pids:+$pids }$pid"
    RECONCILE_BATCH_PIDS=$pids
  done
  index=1
  for pid in $pids; do
    if wait "$pid"; then worker_rc=0; else worker_rc=$?; fi
    printf '%s\n' "$worker_rc" > "$batch_dir/$index.rc" || exit 1
    index=$((index + 1))
  done
  RECONCILE_BATCH_PIDS=
  index=1
  while [ -f "$batch_dir/$index.id" ]; do
    id=$(cat "$batch_dir/$index.id")
    expected_generation=$(cat "$batch_dir/$index.generation" 2>/dev/null || true)
    out=$(cat "$batch_dir/$index.out" 2>/dev/null || true)
    worker_rc=$(cat "$batch_dir/$index.rc" 2>/dev/null || echo 125)
    if [ "$worker_rc" -ne 0 ]; then
      case "$worker_rc" in
        124) failure_evidence="task state observer timed out after ${RECONCILE_TASK_TIMEOUT}s" ;;
        125) failure_evidence='task state observer has no bounded runner' ;;
        *) failure_evidence="task state observer exited with status $worker_rc" ;;
      esac
      err_tail=$(tail -1 "$batch_dir/$index.err" 2>/dev/null || true)
      [ -z "$err_tail" ] || failure_evidence="$failure_evidence: $err_tail"
      if ! out=$(fm_reconcile_observer_failure "$STATE" "$id" "$failure_evidence" "$expected_generation"); then
        reconcile_batch_cleanup
        exit 1
      fi
    elif [ -n "$out" ]; then
      IFS=$(printf '\t') read -r tag token version evidence <<EOF
$out
EOF
      case "$version" in ''|*[!A-Za-z0-9._:-]*) tag=malformed ;; esac
      case "$out" in *$'\n'*) tag=malformed ;; esac
      if [ "$tag" != action ] || [ -z "$token" ]; then
        if ! out=$(fm_reconcile_observer_failure "$STATE" "$id" 'task state observer returned malformed output' "$expected_generation"); then
          reconcile_batch_cleanup
          exit 1
        fi
      fi
    fi
    index=$((index + 1))
    [ -n "$out" ] || continue
    IFS=$(printf '\t') read -r tag token version evidence <<EOF
$out
EOF
    [ "$tag" = action ] && [ -n "$token" ] || continue
    case "$version" in ''|*[!A-Za-z0-9._:-]*) continue ;; esac
    if [ -z "$selected_id" ]; then
      selected_id=$id
      selected_token=$token
      selected_version=$version
      selected_evidence=$evidence
    fi
  done
  reconcile_batch_cleanup
  [ -n "$selected_id" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_reconcile_lock_acquire "$STATE" "$selected_id"
  meta="$STATE/$selected_id.meta"
  if [ ! -f "$meta" ] || fm_reconcile_tombstone_active "$STATE" "$selected_id"; then
    fm_reconcile_lock_release "$STATE" "$selected_id"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  pending=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" pending_action_version)
  notified=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" notified_action_token)
  notified_version=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" notified_action_version)
  record_repository=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" repository_identity)
  record_generation=$(fm_reconcile_record_value "$STATE/$selected_id.reconciled" lifecycle_generation)
  current_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  kind=$(fm_reconcile_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$pending" != "$selected_token" ] || [ "$pending_version" != "$selected_version" ] \
    || { [ "$notified" = "$selected_token" ] && [ "$notified_version" = "$selected_version" ]; } \
    || [ -z "$record_generation" ] || [ "$record_generation" != "$current_generation" ] \
    || { [ "$kind" != secondmate ] && [ -z "$record_repository" ]; }; then
    fm_reconcile_lock_release "$STATE" "$selected_id"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="fm-$selected_id"
  marker=$(fm_reconcile_action_marker "$selected_id" "$selected_token" "$selected_version")
  reason="stale: $target $selected_evidence $marker"
  fm_wake_append_locked stale "$target" "$reason" || queue_rc=$?
  if [ "$queue_rc" -eq 0 ]; then
    fm_reconcile_advance_seen "$STATE" "$selected_id" || queue_rc=$?
  fi
  if [ "$queue_rc" -eq 0 ]; then
    mark_surfaced "$STATE/$selected_id.status"
  fi
  fm_reconcile_lock_release "$STATE" "$selected_id"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$queue_rc" -eq 0 ] || exit "$queue_rc"
  wake "$reason"
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(window_key "$1")"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crew waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# Accept ownership only from a wrapper that declares its live process identity.
# Arm ownership also carries the live process that tracks the wrapper across a
# turn yield; command-name ancestry is not ownership evidence.
watch_owner_from_env() {
  local current_identity current_tracker_identity
  WATCH_OWNER_KIND=${FM_WATCH_OWNER_KIND:-}
  WATCH_OWNER_PID=${FM_WATCH_OWNER_PID:-}
  WATCH_OWNER_IDENTITY=${FM_WATCH_OWNER_IDENTITY:-}
  WATCH_OWNER_MODE=${FM_WATCH_OWNER_MODE:-}
  WATCH_OWNER_TRACKER_PID=${FM_WATCH_OWNER_TRACKER_PID:-}
  WATCH_OWNER_TRACKER_IDENTITY=${FM_WATCH_OWNER_TRACKER_IDENTITY:-}
  case "$WATCH_OWNER_KIND" in arm|checkpoint|daemon) ;; *) return 1 ;; esac
  fm_pid_alive "$WATCH_OWNER_PID" || return 1
  case "$WATCH_OWNER_KIND" in
    arm|daemon) [ "$WATCH_OWNER_PID" = "${PPID:-}" ] || return 1 ;;
  esac
  [ -n "$WATCH_OWNER_IDENTITY" ] || return 1
  current_identity=$(fm_pid_identity "$WATCH_OWNER_PID") || return 1
  [ "$current_identity" = "$WATCH_OWNER_IDENTITY" ] || return 1
  if [ "$WATCH_OWNER_KIND" = arm ]; then
    [ "$WATCH_OWNER_TRACKER_PID" != 1 ] || return 1
    fm_pid_alive "$WATCH_OWNER_TRACKER_PID" || return 1
    [ -n "$WATCH_OWNER_TRACKER_IDENTITY" ] || return 1
    current_tracker_identity=$(fm_pid_identity "$WATCH_OWNER_TRACKER_PID") || return 1
    [ "$current_tracker_identity" = "$WATCH_OWNER_TRACKER_IDENTITY" ] || return 1
  fi
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

if ! fm_lock_try_acquire "$WATCH_LOCK" 1; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap watch_cleanup EXIT
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
if watch_owner_from_env; then
  printf '%s\n' "$WATCH_OWNER_KIND" > "$WATCH_LOCK/owner-kind" || true
  printf '%s\n' "$WATCH_OWNER_MODE" > "$WATCH_LOCK/owner-mode" || true
  printf '%s\n' "$WATCH_OWNER_PID" > "$WATCH_LOCK/owner-pid" || true
  printf '%s\n' "$WATCH_OWNER_IDENTITY" > "$WATCH_LOCK/owner-identity" || true
  if [ "$WATCH_OWNER_KIND" = arm ]; then
    printf '%s\n' "$WATCH_OWNER_TRACKER_PID" > "$WATCH_LOCK/owner-tracker-pid" || true
    printf '%s\n' "$WATCH_OWNER_TRACKER_IDENTITY" > "$WATCH_LOCK/owner-tracker-identity" || true
  fi
fi

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Authoritative durable task-state transition classification.  This precedes
  # check/status/stale cadence paths and therefore does not depend on a heartbeat,
  # pane hash becoming stale, or a fresh status append.
  reconcile_cycle

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    if ! task_has_park_anchor "$task" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      # A secondmate's idle pane is healthy and skips stale detection, but a
      # GONE endpoint is death, not idleness: the cheap read-only existence
      # probe keeps a vanished persistent supervisor from rotting invisibly
      # until the next session start.
      handle_gone_endpoint "$w"
      continue
    fi
    if ! tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null); then
      # An unreadable endpoint is either gone (death - immediately actionable,
      # never absorbed into a declared pause) or a transient backend hiccup;
      # handle_gone_endpoint corroborates with the existence probe and decides.
      handle_gone_endpoint "$w"
      continue
    fi
    rm -f "$STATE/.endpoint-gone-$key"
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's current stale is a declared pause
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" != secondmate ] && fm_reconcile_is_quiet_notified "$STATE" "$task" "$w"; then
          # Durable reconciliation already surfaced and acknowledged this exact
          # task/endpoint's current non-working state.  Pane staleness is
          # downstream evidence for the same transition, not a second wake.
          # A later positive working observation removes this exemption.
          printf '%s' "$h" > "$sf"
          rm -f "$ssf" "$ewf"
          triage_log "absorbed stale (reconciled transition already notified): $w"
        elif [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          # A paused crew's confidently-dead agent is the exception: the same
          # bounded probe cadence as normal mode (first sight of a paused
          # stale hash, then the paused-recheck window) surfaces the explicit
          # agent-dead verdict, deduped once per death, so the daemon receives
          # the death instead of a plain stale it may re-absorb as a declared
          # pause. Ambiguous or errored liveness reads stay fail-closed and
          # hand off only the plain stale.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if status_is_paused "$last"; then
              date +%s > "$STATE/.paused-rechecked-$key"
              if paused_agent_is_dead "$w"; then
                handle_dead_agent "$w" "$h"
                continue
              fi
            fi
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          elif status_is_paused "$last" && [ "$(age_of "$STATE/.paused-rechecked-$key")" -ge "$STALE_ESCALATE_SECS" ]; then
            date +%s > "$STATE/.paused-rechecked-$key"
            if paused_agent_is_dead "$w"; then
              handle_dead_agent "$w" "$h"
            fi
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane/owned command (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly run-step read runs only
          # on first sight, never every poll) via crew_absorb_class, which returns
          # BOTH absorb reasons from one fm-crew-state.sh read:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the bounded revalidation
          #     timer; unchanged positive evidence remains quiet at every recheck;
          #   - paused: the crew DECLARED an external wait (paused:), or its run
          #     finished green with park-anchor evidence (a declared pause or an
          #     armed check; crew_absorb_class), so absorb on the long
          #     PAUSE_RESURFACE_SECS recheck cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(crew_absorb_class "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                # First sight of a paused stale hash is the once-per-hash spot
                # for the deeper agent-process probe: a crew that DIED in its
                # declared wait surfaces instead of being absorbed for hours.
                if paused_agent_is_dead "$w"; then
                  handle_dead_agent "$w" "$h"
                else
                  handle_paused_stale "$w" "$task" "$h"
                fi
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                dead)    handle_dead_agent "$w" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       surface_nonterminal_stale "$w" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        # A surfaced agent-dead marker resets only on genuine positive
        # agent-liveness (an actually-busy pane) - never on the n<2
        # bookkeeping window alone, which a dead pane re-enters after any
        # cosmetic redraw and which would re-surface the same death once per
        # recheck window.
        rm -f "$ssf" "$ewf"
        if [ -e "$STATE/.agent-dead-$key" ] && window_is_busy "$w" "$tail40"; then
          rm -f "$STATE/.agent-dead-$key"
        fi
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! task_has_park_anchor "$task"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      # A changed hash alone does not clear .agent-dead-<key>: a dead pane can
      # still churn cosmetically, and clearing here would re-surface the same
      # death once per recheck window. The marker resets only on positive
      # liveness (busy pane, an alive probe read) or a pause-tracking clear.
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! task_has_park_anchor "$task" || window_is_busy "$w" "$tail40"; then
        [ -e "$pf" ] && clear_pause_tracking "$w"
      elif afk_present; then
        # Afk keeps the same bounded paused-recheck death probe on a churning
        # idle pane, and preserves the pause bookkeeping (including the
        # agent-dead marker) instead of wiping it, so one death cannot
        # re-surface per recheck window; pause re-surfacing itself stays
        # daemon-owned.
        if [ "$kind" != secondmate ] && [ "$(age_of "$STATE/.paused-rechecked-$key")" -ge "$STALE_ESCALATE_SECS" ]; then
          date +%s > "$STATE/.paused-rechecked-$key"
          if paused_agent_is_dead "$w"; then
            handle_dead_agent "$w" "$h"
          fi
        fi
      else
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          dead)   handle_dead_agent "$w" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
