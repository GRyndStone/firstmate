# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds] [watch-path] [home]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
#   FM_SUP_WATCHER_STATE  live|wedged|dead|absent from the durable lock, via
#                         fm_watcher_state in bin/fm-wake-lib.sh, or "unknown"
#                         when that library was not sourced by the caller
#   FM_SUP_WATCHER_PID    the pid that classification is about, when there is one
# The beacon fields answer "is supervision fresh"; the watcher-state fields answer
# "and if not, is that because it died, wedged, or was never armed" - a distinction
# only the lock can make, and the one that lets a dead watcher be named without
# waiting out the grace window.
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# watch-path defaults to the fm-watch.sh next to this library.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  local watch_path=${3:-$FM_SUP_LIB_DIR/fm-watch.sh} home=${4:-${FM_HOME:-}}
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false
  FM_SUP_WATCHER_STATE=unknown
  FM_SUP_WATCHER_PID=
  if command -v fm_watcher_state >/dev/null 2>&1; then
    fm_watcher_state "$state" "$watch_path" "$grace" "$home"
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_WATCHER_STATE=$FM_WATCHER_STATE
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_WATCHER_PID=$FM_WATCHER_STATE_PID
  fi

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
