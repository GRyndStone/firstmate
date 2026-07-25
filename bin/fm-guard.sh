#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and supervision is in
# a dangerous state, prints a loud, clearly delimited banner so the agent cannot
# skim past it in the tool output of whatever it was doing - the one channel
# every harness has. Always exits 0: the guard warns, it never blocks.
#
# Three dangerous states, all read from durable state with no dependence on a
# harness kill notification ever being delivered (fm_watcher_state in
# bin/fm-wake-lib.sh owns the classification):
#   DEAD    the watcher is provably gone: the lock names an exited or recycled
#           pid (SIGKILL or a crash, where no trap ran), or there is no lock but
#           the last holder recorded that it was SIGNALLED or failed rather than
#           exiting on a wake. Reported immediately in both shapes, because both
#           are proof rather than a timeout, where beacon age alone would stay
#           silent for the whole grace window. The signalled shape is the one
#           that matters most: the EXIT trap releases the lock there too, so
#           without the recorded cause a SIGTERMed watcher was indistinguishable
#           from one that deliberately exited to deliver a wake.
#   WEDGED  the lock names a live, identity-matched watcher whose beacon stopped
#           advancing. Named separately from DOWN because a pid liveness check
#           calls it healthy, and because only --restart can displace it.
#   DOWN    no watcher, and the beacon (state/.last-watcher-beat, touched every
#           poll cycle) is missing or older than FM_GUARD_GRACE seconds.
# Normal wake handling (watcher briefly down between a wake and the next
# supervision resume) leaves no lock behind, records that its exit WAS the wake,
# and stays inside the grace window, so it stays silent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute in-flight count, watcher-beacon freshness, and the durable-state
# watcher classification via the shared predicate (bin/fm-supervision-lib.sh).
# Only act with tasks in flight; count them so the banner can say how much is
# riding on an absent watcher.
fm_supervision_status "$STATE" "$GRACE" "$WATCH" "$FM_HOME"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
watcher_state=$FM_SUP_WATCHER_STATE
watcher_pid=$FM_SUP_WATCHER_PID
watcher_cause=$FM_SUP_WATCHER_CAUSE
[ "$in_flight" -eq 0 ] && exit 0

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# Pick the alarm from durable state, not from the beacon alone. A watcher the
# lock proves is gone, and a watcher that is alive but no longer beating, are
# both dangerous states the beacon-freshness test alone either misses for a whole
# grace window or reports as the wrong problem.
alarm_title=
alarm_detail=
alarm_extra=
case "$watcher_state" in
  dead)
    alarm_title='WATCHER DEAD - SUPERVISION IS OFF'
    if [ -n "$watcher_cause" ]; then
      alarm_detail=$(printf 'Watcher pid %s stopped without delivering a wake (recorded cause: %s), so it did not hand supervision on to anything. Durable state proves it, so no grace window applies and no kill notification was needed.' "$watcher_pid" "$watcher_cause")
    else
      alarm_detail=$(printf 'The recorded watcher (pid %s) is gone. Durable state proves it, so no grace window applies and no kill notification was needed.' "$watcher_pid")
    fi
    ;;
  wedged)
    alarm_title='WATCHER WEDGED - SUPERVISION IS OFF'
    alarm_detail=$(printf 'Watcher pid %s is alive but stopped advancing its beacon (last beat: %s, grace %ss); a liveness check on the pid alone would call this healthy.' "$watcher_pid" "$beacon_desc" "$GRACE")
    alarm_extra='A plain re-arm cannot displace a live lock holder; repair this one with bin/fm-watch-arm.sh --restart.'
    ;;
  *)
    if [ "$watcher_fresh" = false ]; then
      alarm_title='WATCHER DOWN - SUPERVISION IS OFF'
      alarm_detail=$(printf 'No watcher has a fresh beacon (last beat: %s, grace %ss).' "$beacon_desc" "$GRACE")
    fi
    ;;
esac

# A read-only session reports the lapse instead of repairing it, so it must not
# also be handed a repair command.
[ "$READ_ONLY" -eq 1 ] && alarm_extra=

# A dangerous watcher state with tasks in flight: emit a prominent, bordered
# banner FIRST so it reads as an alarm, not a buried stderr line.
if [ -n "$alarm_title" ]; then
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  queue_arg=0
  "$queue_pending" && queue_arg=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
    --read-only "$READ_ONLY" \
    --afk "$afk" \
    --x-mode "$x_mode" \
    --queue-pending "$queue_arg" \
    --repair-line 2>/dev/null || printf '%s\n' 'Resume supervision according to the session-start operating block.')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  %s\n' "$alarm_title"
    printf '●  %s task(s) in flight. %s\n' "$in_flight" "$alarm_detail"
    [ -n "$alarm_extra" ] && printf '●  %s\n' "$alarm_extra"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session should report the lapse, not repair it.\n'
    else
      printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
    fi
    printf '●  %s\n' "$CONTINUE_LINE"
    printf '●  %s\n' "$fix"
    printf '●%s\n' "$rule"
  } >&2
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
