#!/usr/bin/env bash
# Start a long-lived command detached from THIS caller's process tree, and print
# the detached process's pid on stdout.
#
# WHY: a harness that "stops" a background task does not merely signal that
# task's process group - it walks the task's DESCENDANT TREE and signals every
# process it finds. Measured on this platform on 2026-07-25; the evidence is
# recorded in docs/turnend-guard.md ("Detached supervision watcher"). A child in
# its own process group died, a child in its own SESSION died, and only a process
# that had been REPARENTED away from the launcher - no longer a descendant when
# the walk ran - survived.
#
# So detachment here is, in order:
#   1. A double fork. The intermediate subshell exits immediately, so the command
#      is reparented to init and a descendant-tree walk rooted at the launcher can
#      no longer find it. This is the part that matters on this platform, and it
#      needs no external tool.
#   2. A new session when perl is available, so a harness that signals a process
#      group instead of walking a tree also misses it. Best effort: skipping it
#      never costs the reparenting above.
#   3. stdin from /dev/null, stdout and stderr to <out-file>, so the command never
#      holds a pipe the dying launcher owned. A detached process still writing to
#      a closed harness pipe would take SIGPIPE and die, undoing all of the above.
#
# This is a launch primitive only. It deliberately knows nothing about watchers,
# locks, or beacons: whoever calls it owns confirming that what it started is the
# process they wanted. bin/fm-watch-arm.sh does exactly that.
#
# usage: fm-detach.sh <out-file> <command> [args...]
# Prints the detached pid on stdout. Exits non-zero if it could not launch.
set -u

[ "$#" -ge 2 ] || {
  echo "usage: $(basename "$0") <out-file> <command> [args...]" >&2
  exit 2
}

OUT=$1
shift

: > "$OUT" 2>/dev/null || {
  echo "fm-detach: cannot write output file: $OUT" >&2
  exit 1
}

USE_PERL=0
command -v perl >/dev/null 2>&1 && USE_PERL=1

# The subshell IS the intermediate fork: it launches the command, reports the
# pid, and exits at once, orphaning the command onto init.
(
  if [ "$USE_PERL" -eq 1 ]; then
    # POSIX::setsid() returning -1 (the caller is already a process-group leader)
    # is not fatal here: perl execs the command either way, so the double fork
    # still stands and only the extra session isolation is lost. perl execs in
    # place, so the pid reported below is the command's own pid.
    perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or exit 127' "$@" \
      >"$OUT" 2>&1 </dev/null &
  else
    "$@" >"$OUT" 2>&1 </dev/null &
  fi
  printf '%s\n' "$!"
) &
INTERMEDIATE=$!
wait "$INTERMEDIATE"
