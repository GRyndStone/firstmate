#!/usr/bin/env bash
# Durable task-state reconciliation primitives.
#
# This file is the single owner of the persisted reconciled-observation record:
#   state/<id>.reconciled
#
# state/<id>.status remains append-only event evidence.  It never decides whether
# a live task is still working.  On every watcher classification cycle,
# fm-watch.sh calls fm_reconcile_observe for every recorded task.  The function
# compares deterministic live evidence from fm-crew-state.sh with the last
# positively observed task/endpoint state and persists the result atomically.
# A positive working observation losing that source or changing to any
# non-working state leaves a pending actionable token until a durable consumer
# accepts it from the wake queue.
#
# The same record also owns external-wait observation state.  A registered
# state/<id>.wait file has schema fm-external-wait.v1 and one of these forms:
#
#   kind=predicate
#   description=<human-readable summary>
#   predicate=<absolute executable path>
#
#   kind=process
#   description=<human-readable summary>
#   pid=<decimal pid>
#   pid_identity=<LC_ALL=C ps lstart+command identity captured at registration>
#   role=working-command                 # optional; absent means external wait
#   progress_grace=<seconds>             # required for working-command
#   owner_worktree=<physical path>       # required for working-command
#   owner_tasktmp=<physical path>        # optional task-scoped alternate root
#
# Predicate exit 0 means complete, exit 1 means still pending, and every other
# exit or timeout means failed.  Process identity match means pending; exit or
# pid reuse means complete.  A working-command registration is also positive
# working evidence while its exact pid/descendant tree is observably advancing.
# It never matches process names or searches for commands outside the registered
# root tree.  fm-external-wait.sh is the validated writer.
# A legacy state/<id>.check.sh remains observable park-anchor evidence, but only
# an explicit .wait registration is evaluated on every classification cycle.
# Teardown removes both the reconciled record and wait registration with meta.
#
# Public functions:
#   fm_reconcile_observe <state-dir> <id>
#     Persist one observation.  Print nothing when quiet, or one TAB-separated
#     "action<TAB>token<TAB>version<TAB>reason" record while an action is unacknowledged.
#   fm_reconcile_ack <state-dir> <id> <token> <version>
#     Acknowledge only the exact version already persisted after consumer handoff.
#   fm_reconcile_observer_failure <state-dir> <id> <evidence>
#     Persist and emit one deduplicated observer-failure action.
#   fm_reconcile_teardown_begin <state-dir> <id>
#     Serialize and publish the teardown tombstone before destructive cleanup.
#   fm_reconcile_action_marker <id> <token> <version>
#     Print the durable wake marker that binds a queue payload to its action.
#   fm_reconcile_action_pending <state-dir> <reason>
#     True when a marked queue payload still needs consumer handoff.
#   fm_reconcile_consumer_ack_reason <state-dir> <reason>
#     Acknowledge a marked payload after durable consumer handoff.
#   fm_reconcile_advance_seen <state-dir> <id>
#     Advance watcher event suppressors only to the exact status/turn signatures
#     persisted by the observation, never to a newer event that raced delivery.
#   fm_reconcile_record_value <record> <key>
#     Read the last key value without sourcing the data file.
#   fm_reconcile_is_quiet_notified <state-dir> <id> [endpoint]
#     True when the current non-working task/endpoint state was already notified.
#   fm_reconcile_wait_registration <state-dir> <id>
#     Print a stable JSON object describing the registration without executing it.
#   fm_reconcile_owned_command_observe <state-dir> <id>
#     Succeed and print detail only while an identity-bound registered command
#     is live, task-scoped, and within its persisted progress grace.

_FM_RECONCILE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_RECONCILE_LIB_DIR="."
# shellcheck source=bin/fm-task-identity-lib.sh
. "$_FM_RECONCILE_LIB_DIR/fm-task-identity-lib.sh"
FM_RECONCILE_CREW_STATE_BIN="${FM_RECONCILE_CREW_STATE_BIN:-${FM_CREW_STATE_BIN:-$_FM_RECONCILE_LIB_DIR/fm-crew-state.sh}}"
FM_EXTERNAL_WAIT_TIMEOUT=${FM_EXTERNAL_WAIT_TIMEOUT:-5}
case "$FM_EXTERNAL_WAIT_TIMEOUT" in ''|*[!0-9]*|0) FM_EXTERNAL_WAIT_TIMEOUT=5 ;; esac
FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES=${FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES:-4096}
case "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES" in ''|*[!0-9]*|0) FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES=4096 ;; esac
FM_LEGACY_CHECK_INTERVAL=${FM_LEGACY_CHECK_INTERVAL:-${FM_CHECK_INTERVAL:-300}}
case "$FM_LEGACY_CHECK_INTERVAL" in ''|*[!0-9]*) FM_LEGACY_CHECK_INTERVAL=300 ;; esac
FM_LEGACY_CHECK_TIMEOUT=${FM_LEGACY_CHECK_TIMEOUT:-${FM_CHECK_TIMEOUT:-30}}
case "$FM_LEGACY_CHECK_TIMEOUT" in ''|*[!0-9]*|0) FM_LEGACY_CHECK_TIMEOUT=30 ;; esac
FM_TEARDOWN_TOMBSTONE_SECS=${FM_TEARDOWN_TOMBSTONE_SECS:-120}
case "$FM_TEARDOWN_TOMBSTONE_SECS" in ''|*[!0-9]*|0) FM_TEARDOWN_TOMBSTONE_SECS=120 ;; esac
FM_RECONCILE_META_UPDATED_GENERATION=
export FM_RECONCILE_META_UPDATED_GENERATION

fm_reconcile_record_value() {  # <record> <key>
  local record=$1 key=$2
  [ -f "$record" ] || return 0
  grep "^$key=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_reconcile_clean_value() {  # <value>
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

fm_reconcile_observation_key() {  # <component...>
  local value clean key=''
  for value in "$@"; do
    clean=$(fm_reconcile_clean_value "$value")
    key="${key}${#clean}:$clean"
  done
  printf '%s' "$key"
}

fm_reconcile_status_sequence() {  # <status-file>
  local file=$1
  [ -f "$file" ] || { printf '0'; return; }
  awk 'NF { n++ } END { print n + 0 }' "$file" 2>/dev/null || printf '0'
}

fm_reconcile_file_signature() {  # <file>
  local file=$1 out sum size
  [ -f "$file" ] || { printf 'absent'; return; }
  out=$(cksum "$file" 2>/dev/null) || { printf 'unreadable'; return; }
  sum=${out%% *}
  out=${out#* }
  size=${out%% *}
  case "$sum:$size" in *[!0-9:]*) printf 'unreadable' ;; *) printf '%s:%s' "$sum" "$size" ;; esac
}

fm_reconcile_signal_signature() {  # <file>; watcher-compatible size:mtime
  local file=$1
  [ -e "$file" ] || { printf 'absent'; return; }
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%Fm' "$file" 2>/dev/null || printf 'unreadable'
  else
    stat -c '%s:%Y' "$file" 2>/dev/null || printf 'unreadable'
  fi
}

fm_reconcile_last_status_event() {  # <status-file>
  local file=$1
  [ -f "$file" ] || return 0
  grep -v '^[[:space:]]*$' "$file" 2>/dev/null | tail -1
}

fm_reconcile_status_verb() {  # <status-line>
  local verb=${1%%:*}
  verb=${verb%%\[key=*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  printf '%s' "$verb"
}

fm_reconcile_meta_value() {  # <meta> <key>
  fm_reconcile_record_value "$1" "$2"
}

fm_reconcile_endpoint() {  # <meta>
  local meta=$1 backend terminal window
  backend=$(fm_reconcile_meta_value "$meta" backend)
  if [ "$backend" = orca ]; then
    terminal=$(fm_reconcile_meta_value "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return; }
  fi
  window=$(fm_reconcile_meta_value "$meta" window)
  printf '%s' "$window"
}

fm_reconcile_parse_state_line() {  # <line>; populates FM_RECONCILE_CURRENT_*
  local line=$1 sep=' · ' rest
  FM_RECONCILE_CURRENT_STATE=unknown
  FM_RECONCILE_CURRENT_SOURCE=none
  FM_RECONCILE_CURRENT_DETAIL=
  case "$line" in
    *$'\n'*) return 1 ;;
    state:\ *"$sep"source:\ *)
      rest=${line#state: }
      FM_RECONCILE_CURRENT_STATE=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*)
          FM_RECONCILE_CURRENT_SOURCE=${rest%%"$sep"*}
          FM_RECONCILE_CURRENT_DETAIL=${rest#*"$sep"}
          ;;
        *) FM_RECONCILE_CURRENT_SOURCE=$rest ;;
      esac
      ;;
    *) return 1 ;;
  esac
  case "$FM_RECONCILE_CURRENT_STATE" in working|idle|parked|done|blocked|paused|failed|unknown) ;; *) return 1 ;; esac
  case "$FM_RECONCILE_CURRENT_SOURCE" in run-step|owned-command|pane|status-log|none) ;; *) return 1 ;; esac
  return 0
}

fm_reconcile_bounded() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 1 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } my $stop = sub { my ($code) = @_; kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit $code }; local $SIG{ALRM} = sub { $stop->(124) }; local $SIG{TERM} = sub { $stop->(143) }; local $SIG{INT} = sub { $stop->(130) }; local $SIG{HUP} = sub { $stop->(129) }; alarm $t; waitpid $pid, 0; my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : ($s >> 8))' "$seconds" "$@"
  else
    return 125
  fi
}

fm_reconcile_pid_alive() {  # <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

fm_reconcile_process_identity() {  # <pid>
  local out
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  out=$(LC_ALL=C ps -p "$1" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_reconcile_process_cwd() {  # <pid>
  local pid=$1 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -e "/proc/$pid/cwd" ]; then
    out=$(readlink "/proc/$pid/cwd" 2>/dev/null) || return 1
  elif command -v lsof >/dev/null 2>&1; then
    out=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  (cd "$out" 2>/dev/null && pwd -P)
}

fm_reconcile_path_is_within() {  # <path> <root>
  local path=$1 root=$2
  [ -n "$path" ] && [ -n "$root" ] || return 1
  case "$path" in "$root"|"$root"/*) return 0 ;; esac
  return 1
}

# Print a stable signature for only the exact registered root pid and its
# descendants.  No command text participates in progress and no process is
# selected by name, repository, home, or ambient process-table membership.
fm_reconcile_process_tree_signature() {  # <root-pid>
  local root=$1 queue pid children child row seen=' ' snapshot='' out sum size
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  command -v pgrep >/dev/null 2>&1 || return 1
  queue=$root
  while [ -n "$queue" ]; do
    pid=${queue%% *}
    if [ "$queue" = "$pid" ]; then queue=''; else queue=${queue#* }; fi
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    row=$(LC_ALL=C ps -p "$pid" -o pid= -o ppid= -o time= -o lstart= 2>/dev/null) || continue
    [ -n "$row" ] || continue
    snapshot="$snapshot$row
"
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for child in $children; do
      case "$child" in ''|*[!0-9]*) continue ;; esac
      queue="${queue:+$queue }$child"
    done
  done
  [ -n "$snapshot" ] || return 1
  out=$(printf '%s' "$snapshot" | LC_ALL=C sort -n | cksum 2>/dev/null) || return 1
  sum=${out%% *}
  out=${out#* }
  size=${out%% *}
  case "$sum:$size" in *[!0-9:]*) return 1 ;; esac
  printf '%s:%s' "$sum" "$size"
}

fm_reconcile_wait_load() {  # <state-dir> <id>; populates FM_RECONCILE_WAIT_*
  local state=$1 id=$2 wait_file legacy
  wait_file="$state/$id.wait"
  legacy="$state/$id.check.sh"
  FM_RECONCILE_WAIT_FILE=$wait_file
  FM_RECONCILE_WAIT_PRESENT=0
  FM_RECONCILE_WAIT_KIND=none
  FM_RECONCILE_WAIT_DESCRIPTION=
  FM_RECONCILE_WAIT_TARGET=
  FM_RECONCILE_WAIT_SIGNATURE=absent
  FM_RECONCILE_WAIT_PID=
  FM_RECONCILE_WAIT_PID_IDENTITY=
  FM_RECONCILE_WAIT_ROLE=external-wait
  FM_RECONCILE_WAIT_PROGRESS_GRACE=0
  FM_RECONCILE_WAIT_OWNER_WORKTREE=
  FM_RECONCILE_WAIT_OWNER_TASKTMP=
  FM_RECONCILE_WAIT_REGISTRATION_ID=
  FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=
  FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION=$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)
  if [ -f "$wait_file" ]; then
    FM_RECONCILE_WAIT_PRESENT=1
    FM_RECONCILE_WAIT_KIND=$(fm_reconcile_record_value "$wait_file" kind)
    FM_RECONCILE_WAIT_DESCRIPTION=$(fm_reconcile_record_value "$wait_file" description)
    FM_RECONCILE_WAIT_SIGNATURE=$(fm_reconcile_file_signature "$wait_file")
    FM_RECONCILE_WAIT_REGISTRATION_ID=$(fm_reconcile_record_value "$wait_file" registration_id)
    FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=$(fm_reconcile_record_value "$wait_file" lifecycle_generation)
    case "$FM_RECONCILE_WAIT_KIND" in
      predicate) FM_RECONCILE_WAIT_TARGET=$(fm_reconcile_record_value "$wait_file" predicate) ;;
      legacy-check)
        FM_RECONCILE_WAIT_TARGET=$(fm_reconcile_record_value "$wait_file" check)
        if [ -n "$FM_RECONCILE_WAIT_REGISTRATION_ID" ] \
          && ! fm_reconcile_legacy_check_registration_valid "$state" "$id"; then
          FM_RECONCILE_WAIT_KIND=invalid-legacy-check
        fi
        ;;
      process)
        FM_RECONCILE_WAIT_PID=$(fm_reconcile_record_value "$wait_file" pid)
        FM_RECONCILE_WAIT_PID_IDENTITY=$(fm_reconcile_record_value "$wait_file" pid_identity)
        FM_RECONCILE_WAIT_ROLE=$(fm_reconcile_record_value "$wait_file" role)
        [ -n "$FM_RECONCILE_WAIT_ROLE" ] || FM_RECONCILE_WAIT_ROLE=external-wait
        FM_RECONCILE_WAIT_PROGRESS_GRACE=$(fm_reconcile_record_value "$wait_file" progress_grace)
        case "$FM_RECONCILE_WAIT_PROGRESS_GRACE" in ''|*[!0-9]*) FM_RECONCILE_WAIT_PROGRESS_GRACE=0 ;; esac
        FM_RECONCILE_WAIT_OWNER_WORKTREE=$(fm_reconcile_record_value "$wait_file" owner_worktree)
        FM_RECONCILE_WAIT_OWNER_TASKTMP=$(fm_reconcile_record_value "$wait_file" owner_tasktmp)
        FM_RECONCILE_WAIT_TARGET="pid:$FM_RECONCILE_WAIT_PID"
        ;;
    esac
  elif [ -f "$legacy" ] && ! fm_reconcile_legacy_check_is_managed "$state" "$id" "$legacy"; then
    FM_RECONCILE_WAIT_PRESENT=1
    FM_RECONCILE_WAIT_FILE=$legacy
    FM_RECONCILE_WAIT_KIND='legacy-check'
    FM_RECONCILE_WAIT_DESCRIPTION='legacy per-task check (cadenced)'
    FM_RECONCILE_WAIT_TARGET=$legacy
    FM_RECONCILE_WAIT_SIGNATURE="legacy:$(fm_reconcile_file_signature "$legacy")"
  fi
}

fm_reconcile_legacy_check_marker() {  # <check-file>
  sed -n 's/^# fm-wait-registration=\([A-Za-z0-9._:-][A-Za-z0-9._:-]*\)$/\1/p' "$1" 2>/dev/null | tail -1
}

fm_reconcile_legacy_check_is_managed() {  # <state-dir> <id> <check-file>
  local state=$1 id=$2 check=$3 wait_file marker
  marker=$(fm_reconcile_legacy_check_marker "$check")
  [ -n "$marker" ] && return 0
  wait_file="$state/$id.wait"
  [ "$(fm_reconcile_record_value "$wait_file" kind)" = legacy-check ] \
    && [ "$(fm_reconcile_record_value "$wait_file" check)" = "$check" ]
}

fm_reconcile_legacy_check_registration_valid() {  # <state-dir> <id>
  local state=$1 id=$2 wait_file check commit registration generation
  wait_file="$state/$id.wait"
  check="$state/$id.check.sh"
  commit="$state/$id.wait-commit"
  registration=$(fm_reconcile_record_value "$wait_file" registration_id)
  generation=$(fm_reconcile_record_value "$wait_file" lifecycle_generation)
  [ -n "$registration" ] \
    && [ "$(fm_reconcile_record_value "$wait_file" check)" = "$check" ] \
    && [ "$(fm_reconcile_legacy_check_marker "$check")" = "$registration" ] \
    && [ "$(fm_reconcile_record_value "$commit" schema)" = fm-external-wait-commit.v1 ] \
    && [ "$(fm_reconcile_record_value "$commit" registration_id)" = "$registration" ] \
    && [ "$(fm_reconcile_record_value "$commit" lifecycle_generation)" = "$generation" ] \
    && [ "$(fm_reconcile_record_value "$commit" check_signature)" = "$(fm_reconcile_file_signature "$check")" ] \
    && [ "$(fm_reconcile_record_value "$commit" wait_signature)" = "$(fm_reconcile_file_signature "$wait_file")" ]
}

fm_reconcile_wait_evaluate() {  # [record] [now]; uses WAIT_*; populates RESULT/EVIDENCE/progress
  local record=${1:-} now=${2:-} out='' rc=0 current_identity current_cwd current_progress rc_file
  local old_registration old_progress old_progress_at progress_age old_checked old_state old_evidence check_age
  [ -n "$now" ] || now=$(date +%s)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  old_registration=$(fm_reconcile_record_value "$record" wait_signature)
  old_progress=$(fm_reconcile_record_value "$record" wait_progress_signature)
  old_progress_at=$(fm_reconcile_record_value "$record" wait_progress_at)
  old_checked=$(fm_reconcile_record_value "$record" wait_checked_at)
  old_state=$(fm_reconcile_record_value "$record" wait_state)
  old_evidence=$(fm_reconcile_record_value "$record" wait_evidence)
  case "$old_progress_at" in ''|*[!0-9]*) old_progress_at=0 ;; esac
  case "$old_checked" in ''|*[!0-9]*) old_checked=0 ;; esac
  if [ "$old_registration" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    || [ "$FM_RECONCILE_WAIT_ROLE" != working-command ]; then
    old_progress=
    old_progress_at=0
  fi
  FM_RECONCILE_WAIT_RESULT=none
  FM_RECONCILE_WAIT_EVIDENCE=
  FM_RECONCILE_WAIT_WORKING=0
  FM_RECONCILE_WAIT_PROGRESS_SIGNATURE=$old_progress
  FM_RECONCILE_WAIT_PROGRESS_AT=$old_progress_at
  FM_RECONCILE_WAIT_CHECKED_AT=$now
  if [ "$FM_RECONCILE_WAIT_PRESENT" -eq 1 ]; then
    if [ -n "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" ] \
      && [ "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" != "$FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION" ]; then
      FM_RECONCILE_WAIT_RESULT=failed
      FM_RECONCILE_WAIT_EVIDENCE='external-wait registration belongs to a different task lifecycle'
      return
    fi
    case "$FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION" in
      legacy:*) ;;
      *)
        if [ -z "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" ]; then
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE='external-wait registration has no task lifecycle generation'
          return
        fi
        ;;
    esac
  fi
  case "$FM_RECONCILE_WAIT_KIND" in
    predicate)
      if [ -z "$FM_RECONCILE_WAIT_TARGET" ] || [ ! -f "$FM_RECONCILE_WAIT_TARGET" ] || [ ! -x "$FM_RECONCILE_WAIT_TARGET" ]; then
        FM_RECONCILE_WAIT_RESULT=failed
        FM_RECONCILE_WAIT_EVIDENCE="predicate missing or not executable: ${FM_RECONCILE_WAIT_TARGET:-<empty>}"
        return
      fi
      rc_file="$FM_RECONCILE_WAIT_FILE.predicate-rc.${BASHPID:-$$}"
      out=$(
        fm_reconcile_bounded "$FM_EXTERNAL_WAIT_TIMEOUT" "$FM_RECONCILE_WAIT_TARGET" 2>&1 | {
          head -c "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES"
          cat >/dev/null
        }
        printf '%s\n' "${PIPESTATUS[0]}" > "$rc_file"
      )
      rc=$(cat "$rc_file" 2>/dev/null || printf '125')
      rm -f "$rc_file"
      case "$rc" in ''|*[!0-9]*) rc=125 ;; esac
      out=$(fm_reconcile_clean_value "$out")
      case "$rc" in
        0) FM_RECONCILE_WAIT_RESULT=complete ;;
        1) FM_RECONCILE_WAIT_RESULT=pending ;;
        124|125) FM_RECONCILE_WAIT_RESULT=failed; out="predicate timeout or no bounded runner${out:+: $out}" ;;
        *) FM_RECONCILE_WAIT_RESULT=failed; out="predicate exited $rc${out:+: $out}" ;;
      esac
      FM_RECONCILE_WAIT_EVIDENCE=${out:-"predicate $FM_RECONCILE_WAIT_RESULT"}
      ;;
    process)
      case "$FM_RECONCILE_WAIT_ROLE" in
        external-wait|working-command) : ;;
        *)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE="unsupported registered process role: ${FM_RECONCILE_WAIT_ROLE:-<empty>}"
          return
          ;;
      esac
      case "$FM_RECONCILE_WAIT_PID" in
        ''|*[!0-9]*)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE='registered process pid is invalid'
          ;;
        *)
          if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
            FM_RECONCILE_WAIT_RESULT=complete
            FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
          elif ! current_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID"); then
            if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
              FM_RECONCILE_WAIT_RESULT=complete
              FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
            else
              FM_RECONCILE_WAIT_RESULT=failed
              FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID identity is unreadable"
            fi
          elif [ -z "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
            FM_RECONCILE_WAIT_RESULT=failed
            FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID has no recorded identity"
          elif [ "$current_identity" = "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
            FM_RECONCILE_WAIT_RESULT=pending
            FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID is still running"
            if [ "$FM_RECONCILE_WAIT_ROLE" = working-command ]; then
              case "$FM_RECONCILE_WAIT_PROGRESS_GRACE" in
                ''|*[!0-9]*|0)
                  FM_RECONCILE_WAIT_RESULT=failed
                  FM_RECONCILE_WAIT_EVIDENCE='registered command progress grace is invalid'
                  ;;
                *)
                  current_cwd=$(fm_reconcile_process_cwd "$FM_RECONCILE_WAIT_PID" || true)
                  if ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_WORKTREE" \
                    && ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_TASKTMP"; then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID left its task-scoped roots (cwd ${current_cwd:-unreadable})"
                  elif ! current_progress=$(fm_reconcile_process_tree_signature "$FM_RECONCILE_WAIT_PID"); then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID progress is not observable"
                  else
                    FM_RECONCILE_WAIT_PROGRESS_SIGNATURE=$current_progress
                    if [ -z "$old_progress" ] || [ "$current_progress" != "$old_progress" ]; then
                      FM_RECONCILE_WAIT_PROGRESS_AT=$now
                    fi
                    progress_age=$((now - FM_RECONCILE_WAIT_PROGRESS_AT))
                    [ "$progress_age" -ge 0 ] || progress_age=0
                    if [ "$FM_RECONCILE_WAIT_PROGRESS_AT" -gt 0 ] \
                      && [ "$progress_age" -le "$FM_RECONCILE_WAIT_PROGRESS_GRACE" ]; then
                      FM_RECONCILE_WAIT_WORKING=1
                      FM_RECONCILE_WAIT_EVIDENCE="registered task command $FM_RECONCILE_WAIT_PID is live; descendant progress observed ${progress_age}s ago"
                    else
                      FM_RECONCILE_WAIT_EVIDENCE="registered task command $FM_RECONCILE_WAIT_PID is live but has not progressed for ${progress_age}s"
                    fi
                  fi
                  ;;
              esac
            fi
          elif [ -z "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
            FM_RECONCILE_WAIT_RESULT=failed
            FM_RECONCILE_WAIT_EVIDENCE='registered process identity is missing'
          else
            FM_RECONCILE_WAIT_RESULT=complete
            FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID identity changed or exited"
          fi
          ;;
      esac
      ;;
    legacy-check)
      if [ ! -f "$FM_RECONCILE_WAIT_TARGET" ]; then
        FM_RECONCILE_WAIT_RESULT=failed
        FM_RECONCILE_WAIT_EVIDENCE="legacy check is missing: ${FM_RECONCILE_WAIT_TARGET:-<empty>}"
        return
      fi
      if [ "$old_registration" = "$FM_RECONCILE_WAIT_SIGNATURE" ] && [ "$old_state" = complete ]; then
        FM_RECONCILE_WAIT_RESULT=$old_state
        FM_RECONCILE_WAIT_EVIDENCE=$old_evidence
        FM_RECONCILE_WAIT_CHECKED_AT=$old_checked
        return
      fi
      check_age=$((now - old_checked))
      [ "$check_age" -ge 0 ] || check_age=0
      if [ "$old_registration" = "$FM_RECONCILE_WAIT_SIGNATURE" ] \
        && [ "$old_checked" -gt 0 ] && [ "$check_age" -lt "$FM_LEGACY_CHECK_INTERVAL" ]; then
        FM_RECONCILE_WAIT_RESULT=${old_state:-pending}
        FM_RECONCILE_WAIT_EVIDENCE=${old_evidence:-legacy check pending}
        FM_RECONCILE_WAIT_CHECKED_AT=$old_checked
        return
      fi
      rc_file="$FM_RECONCILE_WAIT_FILE.check-rc.${BASHPID:-$$}"
      out=$(
        fm_reconcile_bounded "$FM_LEGACY_CHECK_TIMEOUT" bash "$FM_RECONCILE_WAIT_TARGET" 2>&1 | {
          head -c "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES"
          cat >/dev/null
        }
        printf '%s\n' "${PIPESTATUS[0]}" > "$rc_file"
      )
      rc=$(cat "$rc_file" 2>/dev/null || printf '125')
      rm -f "$rc_file"
      case "$rc" in ''|*[!0-9]*) rc=125 ;; esac
      out=$(fm_reconcile_clean_value "$out")
      case "$rc" in
        0)
          if [ -n "$out" ]; then
            FM_RECONCILE_WAIT_RESULT=complete
            FM_RECONCILE_WAIT_EVIDENCE=$out
          else
            FM_RECONCILE_WAIT_RESULT=pending
            FM_RECONCILE_WAIT_EVIDENCE='legacy check pending'
          fi
          ;;
        1)
          FM_RECONCILE_WAIT_RESULT=pending
          FM_RECONCILE_WAIT_EVIDENCE=${out:-legacy check pending}
          ;;
        124|125)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE=${out:-legacy check timeout or no bounded runner}
          ;;
        *)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE="legacy check exited $rc${out:+: $out}"
          ;;
      esac
      ;;
    none) : ;;
    *)
      FM_RECONCILE_WAIT_RESULT=failed
      FM_RECONCILE_WAIT_EVIDENCE="unsupported external-wait kind: ${FM_RECONCILE_WAIT_KIND:-<empty>}"
      ;;
  esac
}

fm_reconcile_owned_command_observe() {  # <state-dir> <id>
  local state=$1 id=$2 record now
  record="$state/$id.reconciled"
  now=$(date +%s)
  fm_reconcile_wait_load "$state" "$id"
  [ "$FM_RECONCILE_WAIT_KIND" = process ] || return 1
  [ "$FM_RECONCILE_WAIT_ROLE" = working-command ] || return 1
  fm_reconcile_wait_evaluate "$record" "$now"
  [ "$FM_RECONCILE_WAIT_RESULT" = pending ] || return 1
  [ "$FM_RECONCILE_WAIT_WORKING" -eq 1 ] || return 1
  printf '%s' "$FM_RECONCILE_WAIT_EVIDENCE"
}

fm_reconcile_write_record() {  # uses FM_RECONCILE_WRITE_* globals
  local record=$1 tmp
  tmp="$record.tmp.${BASHPID:-$$}"
  {
    printf 'schema=fm-reconciled.v1\n'
    printf 'task=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_ID")"
    printf 'lifecycle_generation=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_LIFECYCLE_GENERATION")"
    printf 'repository_identity=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_REPOSITORY_IDENTITY")"
    printf 'endpoint=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_ENDPOINT")"
    printf 'state=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_STATE")"
    printf 'source=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_SOURCE")"
    printf 'evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_EVIDENCE")"
    printf 'detail=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_DETAIL")"
    printf 'observed_at=%s\n' "$FM_RECONCILE_WRITE_OBSERVED_AT"
    printf 'observation_key=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_OBSERVATION_KEY")"
    printf 'status_sequence=%s\n' "$FM_RECONCILE_WRITE_STATUS_SEQUENCE"
    printf 'status_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_STATUS_SIGNATURE")"
    printf 'status_signal_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_STATUS_SIGNAL_SIGNATURE")"
    printf 'turn_signal_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_TURN_SIGNAL_SIGNATURE")"
    printf 'last_status_event=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_LAST_STATUS")"
    printf 'prior_endpoint=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PRIOR_ENDPOINT")"
    printf 'prior_state=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PRIOR_STATE")"
    printf 'prior_source=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PRIOR_SOURCE")"
    printf 'prior_evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PRIOR_EVIDENCE")"
    printf 'prior_observed_at=%s\n' "$FM_RECONCILE_WRITE_PRIOR_OBSERVED_AT"
    printf 'transition_sequence=%s\n' "$FM_RECONCILE_WRITE_TRANSITION_SEQUENCE"
    printf 'wait_kind=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_KIND")"
    printf 'wait_description=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_DESCRIPTION")"
    printf 'wait_target=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_TARGET")"
    printf 'wait_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_SIGNATURE")"
    printf 'wait_state=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_STATE")"
    printf 'wait_evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_EVIDENCE")"
    printf 'wait_checked_at=%s\n' "$FM_RECONCILE_WRITE_WAIT_CHECKED_AT"
    printf 'wait_sequence=%s\n' "$FM_RECONCILE_WRITE_WAIT_SEQUENCE"
    printf 'wait_progress_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_PROGRESS_SIGNATURE")"
    printf 'wait_progress_at=%s\n' "$FM_RECONCILE_WRITE_WAIT_PROGRESS_AT"
    printf 'wait_lifecycle_generation=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_WAIT_LIFECYCLE_GENERATION")"
    printf 'pending_action_token=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PENDING_TOKEN")"
    printf 'pending_action_version=%s\n' "$FM_RECONCILE_WRITE_PENDING_VERSION"
    printf 'pending_action_reason=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PENDING_REASON")"
    printf 'pending_action_observation_key=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_PENDING_OBSERVATION_KEY")"
    printf 'notified_action_token=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_NOTIFIED_TOKEN")"
    printf 'notified_action_version=%s\n' "$FM_RECONCILE_WRITE_NOTIFIED_VERSION"
    printf 'notified_action_observation_key=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_NOTIFIED_OBSERVATION_KEY")"
    printf 'observer_state=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_OBSERVER_STATE")"
    printf 'observer_evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_OBSERVER_EVIDENCE")"
    printf 'observer_sequence=%s\n' "$FM_RECONCILE_WRITE_OBSERVER_SEQUENCE"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record"
}

fm_reconcile_lock_path() {  # <state-dir> <id>
  printf '%s/.reconcile-%s.lock\n' "$1" "$2"
}

fm_reconcile_lock_acquire() {  # <state-dir> <id>
  fm_lock_acquire_wait "$(fm_reconcile_lock_path "$1" "$2")"
}

fm_reconcile_lock_release() {  # <state-dir> <id>
  fm_lock_release "$(fm_reconcile_lock_path "$1" "$2")"
}

fm_reconcile_meta_generation() {  # <meta>
  local meta=$1 generation identity
  [ -f "$meta" ] || return 1
  generation=$(fm_reconcile_meta_value "$meta" generation)
  if [ -n "$generation" ]; then
    case "$generation" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
    printf '%s\n' "$generation"
    return 0
  fi
  if [ "$(uname)" = Darwin ]; then
    identity=$(stat -f '%d:%i' "$meta" 2>/dev/null) || return 1
  else
    identity=$(stat -c '%d:%i' "$meta" 2>/dev/null) || return 1
  fi
  case "$identity" in ''|*[!0-9:]*) return 1 ;; esac
  printf 'legacy:%s\n' "$identity"
}

fm_reconcile_tombstone_active() {  # <state-dir> <id>
  local tombstone="$1/$2.tearing-down" owner_pid owner_identity current_identity
  [ -e "$tombstone" ] || return 1
  owner_pid=$(fm_reconcile_record_value "$tombstone" owner_pid)
  owner_identity=$(fm_reconcile_record_value "$tombstone" owner_identity)
  current_identity=$(fm_reconcile_process_identity "$owner_pid" 2>/dev/null || true)
  if fm_reconcile_pid_alive "$owner_pid" \
    && [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
    return 0
  fi
  [ "$(fm_path_age "$tombstone")" -lt "$FM_TEARDOWN_TOMBSTONE_SECS" ]
}

fm_reconcile_teardown_matches_locked() {  # <state-dir> <id> <generation>
  local state=$1 id=$2 generation=$3 tombstone="$1/$2.tearing-down"
  [ "$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)" = "$generation" ] \
    && [ "$(fm_reconcile_record_value "$tombstone" lifecycle_generation)" = "$generation" ]
}

fm_reconcile_meta_matches() {  # <state-dir> <id> <signature> <generation>
  local state=$1 id=$2 expected=$3 expected_generation=$4 meta
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  ! fm_reconcile_tombstone_active "$state" "$id" || return 1
  [ "$(fm_reconcile_file_signature "$meta")" = "$expected" ] || return 1
  [ "$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)" = "$expected_generation" ]
}

fm_reconcile_task_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_reconcile_generation_valid() {
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
}

fm_reconcile_meta_update() {  # <state-dir> <id> <expected-generation> [--set <key> <value>|--remove <key>]...
  local state=$1 id=$2 expected_generation=$3 meta instructions tmp signature current_generation key value attempt=0 update_rc
  local upgraded_generation=
  FM_RECONCILE_META_UPDATED_GENERATION=
  shift 3
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$expected_generation" && [ -d "$state" ] || return 2
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  instructions="$state/.$id.meta-update.${BASHPID:-$$}"
  : > "$instructions" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --set)
        [ "$#" -ge 3 ] || { rm -f "$instructions"; return 2; }
        key=$2
        value=$3
        case "$key" in ''|generation|*[!A-Za-z0-9_]*) rm -f "$instructions"; return 2 ;; esac
        case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) rm -f "$instructions"; return 2 ;; esac
        printf 'set\t%s\t%s\n' "$key" "$value" >> "$instructions" || { rm -f "$instructions"; return 1; }
        shift 3
        ;;
      --remove)
        [ "$#" -ge 2 ] || { rm -f "$instructions"; return 2; }
        key=$2
        case "$key" in ''|generation|*[!A-Za-z0-9_]*) rm -f "$instructions"; return 2 ;; esac
        printf 'remove\t%s\n' "$key" >> "$instructions" || { rm -f "$instructions"; return 1; }
        shift 2
        ;;
      *) rm -f "$instructions"; return 2 ;;
    esac
  done
  case "$expected_generation" in
    legacy:*)
      upgraded_generation=$(fm_task_identity_new_token) || { rm -f "$instructions"; return 1; }
      printf 'set\tgeneration\t%s\n' "$upgraded_generation" >> "$instructions" || { rm -f "$instructions"; return 1; }
      ;;
  esac
  while [ "$attempt" -lt 8 ]; do
    [ -f "$meta" ] || { rm -f "$instructions"; return 1; }
    current_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
    [ "$current_generation" = "$expected_generation" ] || { rm -f "$instructions"; return 3; }
    signature=$(fm_reconcile_file_signature "$meta")
    tmp="$state/.$id.meta-update.${BASHPID:-$$}.$attempt"
    if ! awk -F '\t' '
      NR == FNR {
        if ($1 == "set") { mode[$2] = "set"; value[$2] = substr($0, length($1) + length($2) + 3) }
        else if ($1 == "remove") mode[$2] = "remove"
        next
      }
      {
        split($0, parts, "=")
        key = parts[1]
        if (key in mode) {
          if (!written[key] && mode[key] == "set") print key "=" value[key]
          written[key] = 1
          next
        }
        print
      }
      END {
        for (key in mode) {
          if (!written[key] && mode[key] == "set") print key "=" value[key]
        }
      }
    ' "$instructions" "$meta" > "$tmp"; then
      rm -f "$tmp" "$instructions"
      return 1
    fi
    fm_reconcile_lock_acquire "$state" "$id"
    update_rc=0
    if ! fm_reconcile_meta_matches "$state" "$id" "$signature" "$expected_generation"; then
      update_rc=4
    elif ! mv -f "$tmp" "$meta"; then
      update_rc=1
    fi
    fm_reconcile_lock_release "$state" "$id"
    if [ "$update_rc" -eq 0 ]; then
      rm -f "$instructions"
      FM_RECONCILE_META_UPDATED_GENERATION=${upgraded_generation:-$expected_generation}
      return 0
    fi
    rm -f "$tmp"
    [ "$update_rc" -eq 4 ] || { rm -f "$instructions"; return "$update_rc"; }
    current_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
    [ "$current_generation" = "$expected_generation" ] || { rm -f "$instructions"; return 3; }
    attempt=$((attempt + 1))
  done
  rm -f "$instructions"
  return 4
}

fm_reconcile_legacy_check_register() {  # <state-dir> <id> <expected-generation> <check-temp> <description>
  local state=$1 id=$2 expected_generation=$3 check_tmp=$4 description=$5 wait_file wait_tmp check_file check_publish_tmp
  local commit_file commit_tmp registration_id check_signature wait_signature register_rc=0
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$expected_generation" && [ -d "$state" ] || return 2
  wait_file="$state/$id.wait"
  check_file="$state/$id.check.sh"
  commit_file="$state/$id.wait-commit"
  [ -f "$check_tmp" ] || return 1
  registration_id=$(fm_task_identity_new_token) || return 1
  wait_tmp="$wait_file.tmp.${BASHPID:-$$}"
  check_publish_tmp="$check_file.tmp.${BASHPID:-$$}"
  commit_tmp="$commit_file.tmp.${BASHPID:-$$}"
  {
    cat "$check_tmp"
    printf '\n# fm-wait-registration=%s\n' "$registration_id"
  } > "$check_publish_tmp" || { rm -f "$check_publish_tmp"; return 1; }
  {
    printf 'schema=fm-external-wait.v1\n'
    printf 'kind=legacy-check\n'
    printf 'description=%s\n' "$(fm_reconcile_clean_value "$description")"
    printf 'registration_id=%s\n' "$registration_id"
    printf 'lifecycle_generation=%s\n' "$expected_generation"
    printf 'check=%s\n' "$check_file"
    printf 'registered_at=%s\n' "$(date +%s)"
  } > "$wait_tmp" || { rm -f "$check_publish_tmp" "$wait_tmp"; return 1; }
  check_signature=$(fm_reconcile_file_signature "$check_publish_tmp")
  wait_signature=$(fm_reconcile_file_signature "$wait_tmp")
  {
    printf 'schema=fm-external-wait-commit.v1\n'
    printf 'registration_id=%s\n' "$registration_id"
    printf 'lifecycle_generation=%s\n' "$expected_generation"
    printf 'check_signature=%s\n' "$check_signature"
    printf 'wait_signature=%s\n' "$wait_signature"
  } > "$commit_tmp" || { rm -f "$check_publish_tmp" "$wait_tmp" "$commit_tmp"; return 1; }
  fm_reconcile_lock_acquire "$state" "$id"
  if [ "$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)" != "$expected_generation" ] \
    || fm_reconcile_tombstone_active "$state" "$id"; then
    register_rc=3
  elif ! mv -f "$check_publish_tmp" "$check_file"; then
    register_rc=1
  elif ! mv -f "$wait_tmp" "$wait_file"; then
    rm -f "$check_file" "$commit_file"
    register_rc=1
  elif ! mv -f "$commit_tmp" "$commit_file"; then
    rm -f "$check_file" "$wait_file" "$commit_file"
    register_rc=1
  fi
  fm_reconcile_lock_release "$state" "$id"
  rm -f "$check_tmp" "$check_publish_tmp" "$wait_tmp" "$commit_tmp"
  return "$register_rc"
}

fm_reconcile_spawn_claim() {  # <state-dir> <id> <generation>
  local state=$1 id=$2 generation=$3 claim tmp owner_pid owner_identity existing_pid existing_identity current_identity
  local expected_signature expected_generation rescue_pending claim_rc=0
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$generation" && [ -d "$state" ] || return 2
  claim="$state/$id.spawn-claim"
  owner_pid=${BASHPID:-$$}
  owner_identity=$(fm_reconcile_process_identity "$owner_pid") || return 1
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_tombstone_active "$state" "$id"; then
    claim_rc=3
  elif [ -f "$claim" ]; then
    rescue_pending=$(fm_reconcile_record_value "$claim" rescue_pending)
    existing_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    existing_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    current_identity=$(fm_reconcile_process_identity "$existing_pid" 2>/dev/null || true)
    if [ "$rescue_pending" = 1 ]; then
      claim_rc=5
    elif fm_reconcile_pid_alive "$existing_pid" \
      && { [ -z "$current_identity" ] || { [ -n "$existing_identity" ] && [ "$current_identity" = "$existing_identity" ]; }; }; then
      claim_rc=4
    else
      rm -f "$claim" || claim_rc=1
    fi
  fi
  if [ "$claim_rc" -eq 0 ]; then
    expected_signature=$(fm_reconcile_file_signature "$state/$id.meta")
    expected_generation=$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)
    tmp="$claim.tmp.$owner_pid"
    {
      printf 'schema=fm-spawn-claim.v1\n'
      printf 'generation=%s\n' "$generation"
      printf 'owner_pid=%s\n' "$owner_pid"
      printf 'owner_identity=%s\n' "$(fm_reconcile_clean_value "$owner_identity")"
      printf 'expected_meta_signature=%s\n' "$expected_signature"
      printf 'expected_meta_generation=%s\n' "$expected_generation"
    } > "$tmp" || claim_rc=1
    if [ "$claim_rc" -eq 0 ] && ! mv -f "$tmp" "$claim"; then claim_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$claim_rc"
}

fm_reconcile_spawn_claim_mark_rescue_pending() {  # <state-dir> <id> <generation> <rescue-path>
  local state=$1 id=$2 generation=$3 rescue_path=$4 claim tmp mark_rc=0
  local owner_pid owner_identity expected_signature expected_generation
  claim="$state/$id.spawn-claim"
  fm_reconcile_lock_acquire "$state" "$id"
  if ! fm_reconcile_spawn_claim_matches_locked "$state" "$id" "$generation"; then
    mark_rc=3
  else
    owner_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    owner_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    expected_signature=$(fm_reconcile_record_value "$claim" expected_meta_signature)
    expected_generation=$(fm_reconcile_record_value "$claim" expected_meta_generation)
    tmp="$claim.tmp.${BASHPID:-$$}"
    {
      printf 'schema=fm-spawn-claim.v1\n'
      printf 'generation=%s\n' "$generation"
      printf 'owner_pid=%s\n' "$owner_pid"
      printf 'owner_identity=%s\n' "$owner_identity"
      printf 'expected_meta_signature=%s\n' "$expected_signature"
      printf 'expected_meta_generation=%s\n' "$expected_generation"
      printf 'rescue_pending=1\n'
      printf 'rescue_path=%s\n' "$(fm_reconcile_clean_value "$rescue_path")"
    } > "$tmp" || mark_rc=1
    if [ "$mark_rc" -eq 0 ] && ! mv -f "$tmp" "$claim"; then mark_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$mark_rc"
}

fm_reconcile_spawn_claim_matches_locked() {  # <state-dir> <id> <generation>
  local state=$1 id=$2 generation=$3 claim owner_pid owner_identity current_identity expected_signature expected_generation current_generation
  claim="$state/$id.spawn-claim"
  [ -f "$claim" ] || return 1
  [ "$(fm_reconcile_record_value "$claim" generation)" = "$generation" ] || return 1
  owner_pid=$(fm_reconcile_record_value "$claim" owner_pid)
  owner_identity=$(fm_reconcile_record_value "$claim" owner_identity)
  [ "$owner_pid" = "${BASHPID:-$$}" ] || return 1
  current_identity=$(fm_reconcile_process_identity "$owner_pid" 2>/dev/null || true)
  [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ] || return 1
  ! fm_reconcile_tombstone_active "$state" "$id" || return 1
  expected_signature=$(fm_reconcile_record_value "$claim" expected_meta_signature)
  expected_generation=$(fm_reconcile_record_value "$claim" expected_meta_generation)
  [ "$(fm_reconcile_file_signature "$state/$id.meta")" = "$expected_signature" ] || return 1
  current_generation=$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)
  [ "$current_generation" = "$expected_generation" ]
}

fm_reconcile_spawn_publish() {  # <state-dir> <id> <generation> <meta-temp>
  local state=$1 id=$2 generation=$3 meta_tmp=$4 publish_rc=0
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$generation" && [ -d "$state" ] || return 2
  [ -f "$meta_tmp" ] || return 1
  fm_reconcile_lock_acquire "$state" "$id"
  if ! fm_reconcile_spawn_claim_matches_locked "$state" "$id" "$generation"; then
    publish_rc=3
  elif ! mv -f "$meta_tmp" "$state/$id.meta"; then
    publish_rc=1
  else
    rm -f "$state/$id.spawn-claim" 2>/dev/null || true
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$publish_rc"
}

fm_reconcile_spawn_claim_release() {  # <state-dir> <id> <generation>
  local state=$1 id=$2 generation=$3 claim release_rc=0
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$generation" && [ -d "$state" ] || return 2
  claim="$state/$id.spawn-claim"
  fm_reconcile_lock_acquire "$state" "$id"
  if [ -f "$claim" ] \
    && [ "$(fm_reconcile_record_value "$claim" generation)" = "$generation" ] \
    && [ "$(fm_reconcile_record_value "$claim" owner_pid)" = "${BASHPID:-$$}" ]; then
    rm -f "$claim" || release_rc=$?
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$release_rc"
}

fm_reconcile_observe_locked() {  # <state-dir> <id> <meta-signature> <lifecycle-generation> <live-state>
  local state=$1 id=$2 meta_signature=$3 lifecycle_generation=$4 raw=$5 meta record status_file project kind repository_identity identity_error endpoint now
  local old_repository_identity old_endpoint old_state old_source old_evidence old_observed old_transition_seq
  local old_prior_endpoint old_prior_state old_prior_source old_prior_evidence old_prior_observed
  local old_wait_kind old_wait_sig old_wait_state old_wait_seq old_pending old_reason old_notified
  local old_pending_version old_notified_version old_pending_observation old_notified_observation
  local old_status_signal old_turn_signal old_observer_seq
  local current_state current_source current_detail status_seq status_sig status_signal_before status_signal_sig turn_signal_sig last_status
  local prior_endpoint prior_state prior_source prior_evidence prior_observed transition_seq
  local wait_seq pending pending_version reason observation_key pending_observation candidate_token='' candidate_reason='' event_note=''
  local pending_unacked=0 positive_working=0 current_positive_working=0
  local endpoint_changed=0 state_changed=0 source_changed=0 same_repository=0

  meta="$state/$id.meta"
  fm_reconcile_meta_matches "$state" "$id" "$meta_signature" "$lifecycle_generation" || return 0
  record="$state/$id.reconciled"
  status_file="$state/$id.status"
  project=$(fm_reconcile_meta_value "$meta" project)
  kind=$(fm_reconcile_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  repository_identity=
  if [ "$kind" != secondmate ]; then
    if ! repository_identity=$(fm_task_identity_resolve "$state" "$id" "$project" 2>&1); then
      identity_error=$(fm_reconcile_clean_value "$repository_identity")
      fm_reconcile_observer_failure_locked "$state" "$id" \
        "repository identity cannot be resolved for ${project:-<empty>}${identity_error:+: $identity_error}" \
        "$lifecycle_generation"
      return
    fi
  fi
  endpoint=$(fm_reconcile_endpoint "$meta")
  fm_reconcile_parse_state_line "$raw" || return 65
  current_state=$FM_RECONCILE_CURRENT_STATE
  current_source=$FM_RECONCILE_CURRENT_SOURCE
  current_detail=$FM_RECONCILE_CURRENT_DETAIL
  now=$(date +%s)
  status_signal_before=$(fm_reconcile_signal_signature "$status_file")
  status_seq=$(fm_reconcile_status_sequence "$status_file")
  status_sig=$(fm_reconcile_file_signature "$status_file")
  last_status=$(fm_reconcile_last_status_event "$status_file" || true)
  status_signal_sig=$(fm_reconcile_signal_signature "$status_file")
  if [ "$status_signal_before" != "$status_signal_sig" ]; then
    # Never suppress a status version that changed while its sequence/evidence
    # was being read.  The current transition can still surface, and the sparse
    # signal path remains armed for the raced append on the next cycle.
    status_signal_sig=unstable
  fi
  turn_signal_sig=$(fm_reconcile_signal_signature "$state/$id.turn-ended")

  old_repository_identity=$(fm_reconcile_record_value "$record" repository_identity)
  old_endpoint=$(fm_reconcile_record_value "$record" endpoint)
  old_state=$(fm_reconcile_record_value "$record" state)
  old_source=$(fm_reconcile_record_value "$record" source)
  old_evidence=$(fm_reconcile_record_value "$record" evidence)
  old_observed=$(fm_reconcile_record_value "$record" observed_at)
  old_transition_seq=$(fm_reconcile_record_value "$record" transition_sequence)
  old_prior_endpoint=$(fm_reconcile_record_value "$record" prior_endpoint)
  old_prior_state=$(fm_reconcile_record_value "$record" prior_state)
  old_prior_source=$(fm_reconcile_record_value "$record" prior_source)
  old_prior_evidence=$(fm_reconcile_record_value "$record" prior_evidence)
  old_prior_observed=$(fm_reconcile_record_value "$record" prior_observed_at)
  old_wait_kind=$(fm_reconcile_record_value "$record" wait_kind)
  old_wait_sig=$(fm_reconcile_record_value "$record" wait_signature)
  old_wait_state=$(fm_reconcile_record_value "$record" wait_state)
  old_wait_seq=$(fm_reconcile_record_value "$record" wait_sequence)
  old_pending=$(fm_reconcile_record_value "$record" pending_action_token)
  old_pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  old_reason=$(fm_reconcile_record_value "$record" pending_action_reason)
  old_notified=$(fm_reconcile_record_value "$record" notified_action_token)
  old_notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  old_pending_observation=$(fm_reconcile_record_value "$record" pending_action_observation_key)
  old_notified_observation=$(fm_reconcile_record_value "$record" notified_action_observation_key)
  old_status_signal=$(fm_reconcile_record_value "$record" status_signal_signature)
  old_turn_signal=$(fm_reconcile_record_value "$record" turn_signal_signature)
  old_observer_seq=$(fm_reconcile_record_value "$record" observer_sequence)
  case "$old_transition_seq" in ''|*[!0-9]*) old_transition_seq=0 ;; esac
  case "$old_wait_seq" in ''|*[!0-9]*) old_wait_seq=0 ;; esac
  case "$old_observer_seq" in ''|*[!0-9]*) old_observer_seq=0 ;; esac
  case "$old_pending_version" in *[!A-Za-z0-9._:-]*) old_pending_version= ;; esac
  case "$old_notified_version" in *[!A-Za-z0-9._:-]*) old_notified_version= ;; esac

  prior_endpoint=$old_prior_endpoint
  prior_state=$old_prior_state
  prior_source=$old_prior_source
  prior_evidence=$old_prior_evidence
  prior_observed=$old_prior_observed
  transition_seq=$old_transition_seq
  pending=$old_pending
  pending_version=$old_pending_version
  reason=$old_reason
  pending_observation=$old_pending_observation
  if [ -n "$old_pending" ] \
    && { [ "$old_pending" != "$old_notified" ] || [ "$old_pending_version" != "$old_notified_version" ]; }; then
    pending_unacked=1
  fi

  fm_reconcile_wait_load "$state" "$id"
  fm_reconcile_wait_evaluate "$record" "$now"
  wait_seq=$old_wait_seq
  if [ "$old_wait_kind" != "$FM_RECONCILE_WAIT_KIND" ] \
    || [ "$old_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    || [ "$old_wait_state" != "$FM_RECONCILE_WAIT_RESULT" ]; then
    wait_seq=$((old_wait_seq + 1))
  fi
  if [ "$FM_RECONCILE_WAIT_RESULT" = pending ] && [ "$FM_RECONCILE_WAIT_WORKING" -eq 1 ] \
    && { [ "$current_state" = working ] || [ "$current_state" = idle ] || [ "$current_state" = unknown ]; }; then
    current_state=working
    current_source=owned-command
    current_detail=$FM_RECONCILE_WAIT_EVIDENCE
    raw="state: working · source: owned-command · $current_detail"
  fi

  if [ -n "$old_state" ]; then
    [ "$old_endpoint" = "$endpoint" ] || endpoint_changed=1
    [ "$old_state" = "$current_state" ] || state_changed=1
    [ "$old_source" = "$current_source" ] || source_changed=1
    if [ -n "$old_repository_identity" ] && [ "$old_repository_identity" = "$repository_identity" ]; then
      same_repository=1
    fi
    if [ "$endpoint_changed" -eq 1 ] || [ "$state_changed" -eq 1 ] || [ "$source_changed" -eq 1 ]; then
      prior_endpoint=$old_endpoint
      prior_state=$old_state
      prior_source=$old_source
      prior_evidence=$old_evidence
      prior_observed=$old_observed
      transition_seq=$((old_transition_seq + 1))
    fi
    if { [ "$old_endpoint" = "$endpoint" ] || [ "$same_repository" -eq 1 ]; } && [ "$old_state" = working ]; then
      case "$old_source" in run-step|pane|owned-command) positive_working=1 ;; esac
    fi
  fi
  if [ "$current_state" = working ]; then
    case "$current_source" in run-step|pane|owned-command) current_positive_working=1 ;; esac
  fi

  case "$current_state" in
    paused|blocked)
      if [ "$FM_RECONCILE_WAIT_PRESENT" -eq 0 ]; then
        if [ "$old_wait_state" != unobservable ] || [ "$(fm_reconcile_record_value "$record" status_signature)" != "$status_sig" ]; then
          wait_seq=$((old_wait_seq + 1))
          candidate_token="wait:$wait_seq:unobservable"
          candidate_reason="external-wait-unobservable ($current_state task has no state/$id.wait predicate/process registration or legacy check; blocked work requires immediate intervention unless an observable external wait is registered; last status event sequence $status_seq: ${last_status:-none})"
        fi
        FM_RECONCILE_WAIT_RESULT=unobservable
        FM_RECONCILE_WAIT_EVIDENCE='no completion predicate or process signal registered'
      elif [ "$positive_working" -eq 1 ]; then
        candidate_token="transition:$transition_seq"
        candidate_reason="reconciled-transition ($old_state -> $current_state from positive $old_source evidence; source now $current_source; status event sequence $status_seq, last event: ${last_status:-none}; ${current_detail:-no detail})"
      fi
      ;;
    *)
      if [ "$positive_working" -eq 1 ] \
        && { [ "$current_state" != working ] || [ "$current_positive_working" -eq 0 ]; }; then
        candidate_token="transition:$transition_seq"
        candidate_reason="reconciled-transition ($old_state -> $current_state from positive $old_source evidence; source now $current_source; status event sequence $status_seq, last event: ${last_status:-none}; ${current_detail:-no detail})"
      fi
      ;;
  esac

  case "$FM_RECONCILE_WAIT_RESULT" in
    complete)
      if [ "$old_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] || [ "$old_wait_state" != complete ]; then
        candidate_token="wait:$wait_seq:complete"
        candidate_reason="external-wait-complete ($FM_RECONCILE_WAIT_DESCRIPTION; $FM_RECONCILE_WAIT_EVIDENCE; last status event sequence $status_seq: ${last_status:-none})"
      fi
      ;;
    failed)
      if [ "$old_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] || [ "$old_wait_state" != failed ]; then
        candidate_token="wait:$wait_seq:failed"
        candidate_reason="external-wait-failed ($FM_RECONCILE_WAIT_DESCRIPTION; $FM_RECONCILE_WAIT_EVIDENCE; last status event sequence $status_seq: ${last_status:-none})"
      fi
      ;;
  esac

  if [ "$old_status_signal" != "$status_signal_sig" ]; then
    event_note="status event sequence $status_seq, last event: ${last_status:-none}"
  fi
  if [ "$old_turn_signal" != "$turn_signal_sig" ]; then
    event_note="${event_note:+$event_note; }turn-end signal changed"
  fi

  observation_key=$(fm_reconcile_observation_key \
    "$lifecycle_generation" "$repository_identity" "$endpoint" "$current_state" "$current_source" "$transition_seq" \
    "$FM_RECONCILE_WAIT_SIGNATURE" "$FM_RECONCILE_WAIT_RESULT" "$wait_seq" \
    "$status_signal_sig" "$turn_signal_sig" "$status_seq" ok "$old_observer_seq")

  # Never replace an unacknowledged action with a newer observation.  The
  # watcher persists the action before enqueueing it, so replacement during a
  # crash/restart window could lose the original working transition.  Keep its
  # token, fold any newer actionable condition into the same wake, and continue
  # persisting the latest current state separately above.
  if [ "$pending_unacked" -eq 1 ]; then
    if [ -n "$candidate_token" ] && [ "$candidate_token" != "$old_pending" ]; then
      reason="$old_reason; newer observation before delivery: $candidate_reason"
      pending_version=$(fm_task_identity_new_token) || return 1
      pending_observation=$observation_key
    elif [ "$state_changed" -eq 1 ]; then
      reason="$old_reason; current observation before delivery: $current_state from $current_source (${current_detail:-no detail})${event_note:+; $event_note}"
      pending_version=$(fm_task_identity_new_token) || return 1
      pending_observation=$observation_key
    elif [ -n "$event_note" ]; then
      reason="$old_reason; newer sparse event before delivery: $event_note"
      pending_version=$(fm_task_identity_new_token) || return 1
      pending_observation=$observation_key
    elif [ -z "$pending_version" ]; then
      pending_version=$(fm_task_identity_new_token) || return 1
      pending_observation=$observation_key
    fi
  elif [ -n "$candidate_token" ]; then
    pending=$candidate_token
    pending_version=$(fm_task_identity_new_token) || return 1
    reason=$candidate_reason
    pending_observation=$observation_key
  fi

  FM_RECONCILE_WRITE_ID=$id
  FM_RECONCILE_WRITE_LIFECYCLE_GENERATION=$lifecycle_generation
  FM_RECONCILE_WRITE_REPOSITORY_IDENTITY=$repository_identity
  FM_RECONCILE_WRITE_ENDPOINT=$endpoint
  FM_RECONCILE_WRITE_STATE=$current_state
  FM_RECONCILE_WRITE_SOURCE=$current_source
  FM_RECONCILE_WRITE_EVIDENCE=$raw
  FM_RECONCILE_WRITE_DETAIL=$current_detail
  FM_RECONCILE_WRITE_OBSERVED_AT=$now
  FM_RECONCILE_WRITE_OBSERVATION_KEY=$observation_key
  FM_RECONCILE_WRITE_STATUS_SEQUENCE=$status_seq
  FM_RECONCILE_WRITE_STATUS_SIGNATURE=$status_sig
  FM_RECONCILE_WRITE_STATUS_SIGNAL_SIGNATURE=$status_signal_sig
  FM_RECONCILE_WRITE_TURN_SIGNAL_SIGNATURE=$turn_signal_sig
  FM_RECONCILE_WRITE_LAST_STATUS=$last_status
  FM_RECONCILE_WRITE_PRIOR_ENDPOINT=$prior_endpoint
  FM_RECONCILE_WRITE_PRIOR_STATE=$prior_state
  FM_RECONCILE_WRITE_PRIOR_SOURCE=$prior_source
  FM_RECONCILE_WRITE_PRIOR_EVIDENCE=$prior_evidence
  FM_RECONCILE_WRITE_PRIOR_OBSERVED_AT=${prior_observed:-0}
  FM_RECONCILE_WRITE_TRANSITION_SEQUENCE=$transition_seq
  FM_RECONCILE_WRITE_WAIT_KIND=$FM_RECONCILE_WAIT_KIND
  FM_RECONCILE_WRITE_WAIT_DESCRIPTION=$FM_RECONCILE_WAIT_DESCRIPTION
  FM_RECONCILE_WRITE_WAIT_TARGET=$FM_RECONCILE_WAIT_TARGET
  FM_RECONCILE_WRITE_WAIT_SIGNATURE=$FM_RECONCILE_WAIT_SIGNATURE
  FM_RECONCILE_WRITE_WAIT_STATE=$FM_RECONCILE_WAIT_RESULT
  FM_RECONCILE_WRITE_WAIT_EVIDENCE=$FM_RECONCILE_WAIT_EVIDENCE
  FM_RECONCILE_WRITE_WAIT_CHECKED_AT=$FM_RECONCILE_WAIT_CHECKED_AT
  FM_RECONCILE_WRITE_WAIT_SEQUENCE=$wait_seq
  FM_RECONCILE_WRITE_WAIT_PROGRESS_SIGNATURE=$FM_RECONCILE_WAIT_PROGRESS_SIGNATURE
  FM_RECONCILE_WRITE_WAIT_PROGRESS_AT=$FM_RECONCILE_WAIT_PROGRESS_AT
  FM_RECONCILE_WRITE_WAIT_LIFECYCLE_GENERATION=$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION
  FM_RECONCILE_WRITE_PENDING_TOKEN=$pending
  FM_RECONCILE_WRITE_PENDING_VERSION=$pending_version
  FM_RECONCILE_WRITE_PENDING_REASON=$reason
  FM_RECONCILE_WRITE_PENDING_OBSERVATION_KEY=$pending_observation
  FM_RECONCILE_WRITE_NOTIFIED_TOKEN=$old_notified
  FM_RECONCILE_WRITE_NOTIFIED_VERSION=$old_notified_version
  FM_RECONCILE_WRITE_NOTIFIED_OBSERVATION_KEY=$old_notified_observation
  FM_RECONCILE_WRITE_OBSERVER_STATE=ok
  FM_RECONCILE_WRITE_OBSERVER_EVIDENCE=
  FM_RECONCILE_WRITE_OBSERVER_SEQUENCE=$old_observer_seq
  fm_reconcile_meta_matches "$state" "$id" "$meta_signature" "$lifecycle_generation" || return 0
  fm_reconcile_write_record "$record" || return 1

  if [ -n "$pending" ] \
    && { [ "$pending" != "$old_notified" ] || [ "$pending_version" != "$old_notified_version" ]; }; then
    printf 'action\t%s\t%s\t%s\n' "$pending" "$pending_version" "$reason"
  fi
}

fm_reconcile_observe() {  # <state-dir> <id>
  local state=$1 id=$2 meta meta_signature lifecycle_generation raw observe_rc
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  ! fm_reconcile_tombstone_active "$state" "$id" || return 0
  meta_signature=$(fm_reconcile_file_signature "$meta")
  lifecycle_generation=$(fm_reconcile_meta_generation "$meta") || return 65
  raw=$(
    FM_CREW_STATE_LIVE_ONLY=1 FM_STATE_OVERRIDE="$state" "$FM_RECONCILE_CREW_STATE_BIN" "$id" 2>/dev/null
  ) || return $?
  if ! fm_reconcile_parse_state_line "$raw"; then
    printf 'malformed live-state output for task %s\n' "$id" >&2
    return 65
  fi
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_observe_locked "$state" "$id" "$meta_signature" "$lifecycle_generation" "$raw"; then
    observe_rc=0
  else
    observe_rc=$?
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$observe_rc"
}

fm_reconcile_observer_failure_locked() {  # <state-dir> <id> <evidence> [expected-lifecycle-generation]
  local state=$1 id=$2 evidence=$3 expected_generation=${4:-} meta meta_signature lifecycle_generation record input tmp project kind repository_identity resolved_identity endpoint now
  local old_state old_evidence old_sequence old_pending old_reason old_notified old_pending_version old_notified_version pending pending_version reason token
  local old_pending_observation observation_key pending_observation
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  ! fm_reconcile_tombstone_active "$state" "$id" || return 0
  meta_signature=$(fm_reconcile_file_signature "$meta")
  lifecycle_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  [ -n "$lifecycle_generation" ] || return 0
  [ -z "$expected_generation" ] || [ "$expected_generation" = "$lifecycle_generation" ] || return 0
  record="$state/$id.reconciled"
  project=$(fm_reconcile_meta_value "$meta" project)
  kind=$(fm_reconcile_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  repository_identity=$(fm_reconcile_record_value "$record" repository_identity)
  if [ -z "$repository_identity" ]; then
    repository_identity=$(fm_task_identity_meta_value "$state/$id.identity" repository_identity)
  fi
  if [ "$kind" != secondmate ]; then
    resolved_identity=$(fm_task_identity_resolve "$state" "$id" "$project" 2>/dev/null || true)
    [ -z "$resolved_identity" ] || repository_identity=$resolved_identity
  fi
  endpoint=$(fm_reconcile_endpoint "$meta")
  old_state=$(fm_reconcile_record_value "$record" observer_state)
  old_evidence=$(fm_reconcile_record_value "$record" observer_evidence)
  old_sequence=$(fm_reconcile_record_value "$record" observer_sequence)
  old_pending=$(fm_reconcile_record_value "$record" pending_action_token)
  old_pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  old_reason=$(fm_reconcile_record_value "$record" pending_action_reason)
  old_notified=$(fm_reconcile_record_value "$record" notified_action_token)
  old_notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  old_pending_observation=$(fm_reconcile_record_value "$record" pending_action_observation_key)
  case "$old_sequence" in ''|*[!0-9]*) old_sequence=0 ;; esac
  case "$old_pending_version" in *[!A-Za-z0-9._:-]*) old_pending_version= ;; esac
  case "$old_notified_version" in *[!A-Za-z0-9._:-]*) old_notified_version= ;; esac
  evidence=$(fm_reconcile_clean_value "$evidence")
  pending=$old_pending
  pending_version=$old_pending_version
  reason=$old_reason
  pending_observation=$old_pending_observation
  if [ "$old_state" != failed ] || [ "$old_evidence" != "$evidence" ]; then
    old_sequence=$((old_sequence + 1))
    token="observer:$old_sequence:failed"
    observation_key=$(fm_reconcile_observation_key \
      "$lifecycle_generation" "$repository_identity" "$endpoint" \
      "$(fm_reconcile_record_value "$record" state)" \
      "$(fm_reconcile_record_value "$record" source)" \
      "$(fm_reconcile_record_value "$record" transition_sequence)" \
      "$(fm_reconcile_record_value "$record" wait_signature)" \
      "$(fm_reconcile_record_value "$record" wait_state)" \
      "$(fm_reconcile_record_value "$record" wait_sequence)" failed "$old_sequence")
    if [ -n "$old_pending" ] \
      && { [ "$old_pending" != "$old_notified" ] || [ "$old_pending_version" != "$old_notified_version" ]; }; then
      reason="$old_reason; newer observation before delivery: observer-failure ($evidence)"
      pending_version=$(fm_task_identity_new_token) || return 1
      pending_observation=$observation_key
    else
      pending=$token
      pending_version=$(fm_task_identity_new_token) || return 1
      reason="observer-failure ($evidence)"
      pending_observation=$observation_key
    fi
  fi
  if [ -z "${observation_key:-}" ]; then
    observation_key=$(fm_reconcile_observation_key \
      "$lifecycle_generation" "$repository_identity" "$endpoint" \
      "$(fm_reconcile_record_value "$record" state)" \
      "$(fm_reconcile_record_value "$record" source)" \
      "$(fm_reconcile_record_value "$record" transition_sequence)" \
      "$(fm_reconcile_record_value "$record" wait_signature)" \
      "$(fm_reconcile_record_value "$record" wait_state)" \
      "$(fm_reconcile_record_value "$record" wait_sequence)" failed "$old_sequence")
  fi
  if [ -n "$pending" ] \
    && { [ "$pending" != "$old_notified" ] || [ "$pending_version" != "$old_notified_version" ]; } \
    && [ -z "$pending_version" ]; then
    pending_version=$(fm_task_identity_new_token) || return 1
    pending_observation=$observation_key
  fi
  now=$(date +%s)
  tmp="$record.observer.${BASHPID:-$$}"
  input=$record
  [ -f "$input" ] || input=/dev/null
  awk \
    -v task="$id" \
    -v lifecycle_generation="$lifecycle_generation" \
    -v repository_identity="$repository_identity" \
    -v endpoint="$endpoint" \
    -v now="$now" \
    -v observer_evidence="$evidence" \
    -v observer_sequence="$old_sequence" \
    -v observation_key="$observation_key" \
    -v pending="$pending" \
    -v pending_version="$pending_version" \
    -v reason="$reason" \
    -v pending_observation="$pending_observation" '
    BEGIN {
      defaults["schema"] = "fm-reconciled.v1"
      defaults["task"] = task
      defaults["lifecycle_generation"] = lifecycle_generation
      defaults["repository_identity"] = repository_identity
      defaults["endpoint"] = endpoint
      defaults["state"] = "unknown"
      defaults["source"] = "none"
      defaults["evidence"] = "observer failure"
      defaults["observed_at"] = now
      defaults["notified_action_token"] = ""
      defaults["notified_action_version"] = "0"
      defaults["notified_action_observation_key"] = ""
      updates["lifecycle_generation"] = lifecycle_generation
      updates["repository_identity"] = repository_identity
      updates["endpoint"] = endpoint
      updates["observation_key"] = observation_key
      updates["pending_action_token"] = pending
      updates["pending_action_version"] = pending_version
      updates["pending_action_reason"] = reason
      updates["pending_action_observation_key"] = pending_observation
      updates["observer_state"] = "failed"
      updates["observer_evidence"] = observer_evidence
      updates["observer_sequence"] = observer_sequence
    }
    {
      split($0, parts, "=")
      key = parts[1]
      if (key in updates) {
        print key "=" updates[key]
      } else {
        print
      }
      seen[key] = 1
    }
    END {
      order[1] = "schema"
      order[2] = "task"
      order[3] = "lifecycle_generation"
      order[4] = "repository_identity"
      order[5] = "endpoint"
      order[6] = "state"
      order[7] = "source"
      order[8] = "evidence"
      order[9] = "observed_at"
      order[10] = "observation_key"
      order[11] = "pending_action_token"
      order[12] = "pending_action_version"
      order[13] = "pending_action_reason"
      order[14] = "pending_action_observation_key"
      order[15] = "notified_action_token"
      order[16] = "notified_action_version"
      order[17] = "notified_action_observation_key"
      order[18] = "observer_state"
      order[19] = "observer_evidence"
      order[20] = "observer_sequence"
      for (i = 1; i <= 20; i++) {
        key = order[i]
        if (!(key in seen)) {
          if (key in updates) print key "=" updates[key]
          else print key "=" defaults[key]
        }
      }
    }
  ' "$input" > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_reconcile_meta_matches "$state" "$id" "$meta_signature" "$lifecycle_generation" || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$record" || return 1
  if [ -n "$pending" ] \
    && { [ "$pending" != "$old_notified" ] || [ "$pending_version" != "$old_notified_version" ]; }; then
    printf 'action\t%s\t%s\t%s\n' "$pending" "$pending_version" "$reason"
  fi
}

fm_reconcile_observer_failure() {  # <state-dir> <id> <evidence> [expected-lifecycle-generation]
  local state=$1 id=$2 evidence=$3 expected_generation=${4:-} failure_rc
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_observer_failure_locked "$state" "$id" "$evidence" "$expected_generation"; then
    failure_rc=0
  else
    failure_rc=$?
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$failure_rc"
}

fm_reconcile_ack_locked() {  # <state-dir> <id> <token> <version>
  local state=$1 id=$2 token=$3 version=$4 record pending pending_version pending_observation tmp
  record="$state/$id.reconciled"
  [ -f "$record" ] || return 1
  pending=$(fm_reconcile_record_value "$record" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  [ -n "$token" ] && [ "$pending" = "$token" ] && [ "$pending_version" = "$version" ] || return 1
  pending_observation=$(fm_reconcile_record_value "$record" pending_action_observation_key)
  tmp="$record.ack.${BASHPID:-$$}"
  awk -v token="$token" -v version="$version" -v observation="$pending_observation" '
    BEGIN { wrote_token = 0; wrote_version = 0; wrote_observation = 0 }
    /^notified_action_token=/ { print "notified_action_token=" token; wrote_token = 1; next }
    /^notified_action_version=/ { print "notified_action_version=" version; wrote_version = 1; next }
    /^notified_action_observation_key=/ { print "notified_action_observation_key=" observation; wrote_observation = 1; next }
    { print }
    END {
      if (!wrote_token) print "notified_action_token=" token
      if (!wrote_version) print "notified_action_version=" version
      if (!wrote_observation) print "notified_action_observation_key=" observation
    }
  ' "$record" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record"
}

fm_reconcile_ack() {  # <state-dir> <id> <token> <version>
  local state=$1 id=$2 token=$3 version=$4 ack_rc
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_ack_locked "$state" "$id" "$token" "$version"; then
    ack_rc=0
  else
    ack_rc=$?
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$ack_rc"
}

fm_reconcile_teardown_begin() {  # <state-dir> <id> [expected-generation]
  local state=$1 id=$2 expected_generation=${3:-} mark_rc=0 tombstone tmp owner_pid owner_identity current_generation
  local claim claim_pid claim_identity current_identity rescue_pending
  tombstone="$state/$id.tearing-down"
  owner_pid=${BASHPID:-$$}
  owner_identity=$(fm_reconcile_process_identity "$owner_pid") || return 1
  fm_reconcile_lock_acquire "$state" "$id"
  current_generation=$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)
  [ -n "$expected_generation" ] || expected_generation=$current_generation
  claim="$state/$id.spawn-claim"
  if [ -z "$expected_generation" ] || [ "$current_generation" != "$expected_generation" ] \
    || fm_reconcile_tombstone_active "$state" "$id"; then
    mark_rc=3
  elif [ -f "$claim" ]; then
    rescue_pending=$(fm_reconcile_record_value "$claim" rescue_pending)
    claim_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    claim_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    current_identity=$(fm_reconcile_process_identity "$claim_pid" 2>/dev/null || true)
    if [ "$rescue_pending" = 1 ]; then
      mark_rc=4
    elif fm_reconcile_pid_alive "$claim_pid" \
      && { [ -z "$current_identity" ] || { [ -n "$claim_identity" ] && [ "$current_identity" = "$claim_identity" ]; }; }; then
      mark_rc=4
    elif ! rm -f "$claim"; then
      mark_rc=1
    fi
  fi
  if [ "$mark_rc" -eq 0 ]; then
    tmp="$tombstone.tmp.$owner_pid"
    {
      printf 'schema=fm-teardown-tombstone.v1\n'
      printf 'lifecycle_generation=%s\n' "$expected_generation"
      printf 'owner_pid=%s\n' "$owner_pid"
      printf 'owner_identity=%s\n' "$(fm_reconcile_clean_value "$owner_identity")"
      printf 'started_at=%s\n' "$(date +%s)"
    } > "$tmp" || mark_rc=1
    if [ "$mark_rc" -eq 0 ] && ! mv -f "$tmp" "$tombstone"; then mark_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$mark_rc"
}

fm_reconcile_action_marker() {  # <id> <token> <version>
  printf '[fm-reconcile=%s,%s,%s]' "$(fm_reconcile_clean_value "$1")" "$(fm_reconcile_clean_value "$2")" "$3"
}

fm_reconcile_action_parse() {  # <reason>; populates FM_RECONCILE_ACTION_ID/TOKEN/VERSION
  local reason=$1 marker rest
  FM_RECONCILE_ACTION_ID=
  FM_RECONCILE_ACTION_TOKEN=
  FM_RECONCILE_ACTION_VERSION=
  case "$reason" in *'[fm-reconcile='*']'*) ;; *) return 1 ;; esac
  marker=${reason##*'[fm-reconcile='}
  marker=${marker%%']'*}
  case "$marker" in *,*,*) ;; *) return 1 ;; esac
  FM_RECONCILE_ACTION_ID=${marker%%,*}
  rest=${marker#*,}
  FM_RECONCILE_ACTION_TOKEN=${rest%%,*}
  FM_RECONCILE_ACTION_VERSION=${rest#*,}
  case "$FM_RECONCILE_ACTION_ID" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$FM_RECONCILE_ACTION_TOKEN" in ''|*[!A-Za-z0-9:._-]*) return 1 ;; esac
  case "$FM_RECONCILE_ACTION_VERSION" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
}

fm_reconcile_action_pending() {  # <state-dir> <reason>
  local state=$1 reason=$2 record pending pending_version notified notified_version
  fm_reconcile_action_parse "$reason" || return 1
  record="$state/$FM_RECONCILE_ACTION_ID.reconciled"
  [ -f "$record" ] || return 1
  pending=$(fm_reconcile_record_value "$record" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  notified=$(fm_reconcile_record_value "$record" notified_action_token)
  notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  [ "$pending" = "$FM_RECONCILE_ACTION_TOKEN" ] \
    && [ "$pending_version" = "$FM_RECONCILE_ACTION_VERSION" ] \
    && { [ "$notified" != "$FM_RECONCILE_ACTION_TOKEN" ] || [ "$notified_version" != "$FM_RECONCILE_ACTION_VERSION" ]; }
}

fm_reconcile_consumer_ack_reason() {  # <state-dir> <reason>
  local state=$1 reason=$2 record pending pending_version notified notified_version
  fm_reconcile_action_parse "$reason" || return 0
  record="$state/$FM_RECONCILE_ACTION_ID.reconciled"
  [ -f "$record" ] || return 0
  pending=$(fm_reconcile_record_value "$record" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  notified=$(fm_reconcile_record_value "$record" notified_action_token)
  notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  if [ "$notified" = "$FM_RECONCILE_ACTION_TOKEN" ] \
    && [ "$notified_version" = "$FM_RECONCILE_ACTION_VERSION" ]; then
    return 0
  fi
  [ "$pending" = "$FM_RECONCILE_ACTION_TOKEN" ] || return 0
  [ "$pending_version" = "$FM_RECONCILE_ACTION_VERSION" ] || return 0
  fm_reconcile_ack "$state" "$FM_RECONCILE_ACTION_ID" "$FM_RECONCILE_ACTION_TOKEN" "$FM_RECONCILE_ACTION_VERSION"
}

fm_reconcile_advance_seen() {  # <state-dir> <id>
  local state=$1 id=$2 record field suffix observed seen
  record="$state/$id.reconciled"
  [ -f "$record" ] || return 1
  for field in status_signal_signature turn_signal_signature; do
    observed=$(fm_reconcile_record_value "$record" "$field")
    case "$observed" in ''|absent|unreadable|unstable) continue ;; esac
    case "$field" in
      status_signal_signature) suffix=status ;;
      turn_signal_signature) suffix=turn-ended ;;
    esac
    seen="$state/.seen-$(printf '%s' "$id.$suffix" | tr '.' '_')"
    printf '%s' "$observed" > "$seen" || return 1
  done
}

fm_reconcile_is_quiet_notified() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} record current recorded pending pending_version notified notified_version observation notified_observation
  record="$state/$id.reconciled"
  [ -f "$record" ] || return 1
  current=$(fm_reconcile_record_value "$record" state)
  recorded=$(fm_reconcile_record_value "$record" endpoint)
  pending=$(fm_reconcile_record_value "$record" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  notified=$(fm_reconcile_record_value "$record" notified_action_token)
  notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  observation=$(fm_reconcile_record_value "$record" observation_key)
  notified_observation=$(fm_reconcile_record_value "$record" notified_action_observation_key)
  [ -z "$endpoint" ] || [ "$recorded" = "$endpoint" ] || return 1
  [ -n "$current" ] && [ "$current" != working ] || return 1
  [ -n "$pending" ] && [ "$pending" = "$notified" ] && [ "$pending_version" = "$notified_version" ] \
    && [ -n "$observation" ] && [ "$observation" = "$notified_observation" ]
}

fm_reconcile_wait_registration() {  # <state-dir> <id> -> JSON
  local state=$1 id=$2
  fm_reconcile_wait_load "$state" "$id"
  command -v jq >/dev/null 2>&1 || return 1
  jq -n \
    --argjson registered "$FM_RECONCILE_WAIT_PRESENT" \
    --arg path "$FM_RECONCILE_WAIT_FILE" \
    --arg kind "$FM_RECONCILE_WAIT_KIND" \
    --arg role "$FM_RECONCILE_WAIT_ROLE" \
    --arg description "$FM_RECONCILE_WAIT_DESCRIPTION" \
    --arg target "$FM_RECONCILE_WAIT_TARGET" \
    --arg signature "$FM_RECONCILE_WAIT_SIGNATURE" \
    --arg registration_id "$FM_RECONCILE_WAIT_REGISTRATION_ID" \
    --arg lifecycle_generation "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" \
    --arg owner_worktree "$FM_RECONCILE_WAIT_OWNER_WORKTREE" \
    --arg owner_tasktmp "$FM_RECONCILE_WAIT_OWNER_TASKTMP" \
    --argjson progress_grace "${FM_RECONCILE_WAIT_PROGRESS_GRACE:-0}" \
    '{registered:($registered == 1),path:$path,kind:$kind,role:$role,description:$description,target:$target,signature:$signature,registration_id:($registration_id | if . == "" then null else . end),lifecycle_generation:($lifecycle_generation | if . == "" then null else . end),owner_worktree:($owner_worktree | if . == "" then null else . end),owner_tasktmp:($owner_tasktmp | if . == "" then null else . end),progress_grace_seconds:($progress_grace | if . == 0 then null else . end)}'
}
