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
#   role=background-probe
#   predicate=<absolute executable path>
#   probe_initial_evidence=<pending predicate evidence at registration>
#
# Predicate exit 0 plus non-empty stdout means complete; exit 0 with empty stdout
# or exit 1 means still pending; every other exit or timeout means failed.  Stderr
# is diagnostic only and never completion evidence.  Process identity match means
# pending; exit or pid reuse means complete.  A working-command registration is
# also positive working evidence while its exact pid/descendant tree is
# observably advancing.
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
#   fm_reconcile_background_probe_can_absorb <state-dir> <id> [endpoint]
#     Succeed only while an exact one-shot pulse still matches its armed paused
#     baseline and has a post-arm working edge, then consume that pulse durably.

_FM_RECONCILE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_RECONCILE_LIB_DIR="."
# shellcheck source=bin/fm-task-identity-lib.sh
. "$_FM_RECONCILE_LIB_DIR/fm-task-identity-lib.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$_FM_RECONCILE_LIB_DIR/fm-transition-lib.sh"
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
FM_SPAWN_CLAIM_RECOVERY_SECS=${FM_SPAWN_CLAIM_RECOVERY_SECS:-30}
case "$FM_SPAWN_CLAIM_RECOVERY_SECS" in ''|*[!0-9]*|0) FM_SPAWN_CLAIM_RECOVERY_SECS=30 ;; esac
FM_SPAWN_CLAIM_PROBE_TIMEOUT=${FM_SPAWN_CLAIM_PROBE_TIMEOUT:-5}
case "$FM_SPAWN_CLAIM_PROBE_TIMEOUT" in ''|*[!0-9]*|0) FM_SPAWN_CLAIM_PROBE_TIMEOUT=5 ;; esac
FM_BACKGROUND_PROBE_PULSE_TTL=${FM_BACKGROUND_PROBE_PULSE_TTL:-120}
case "$FM_BACKGROUND_PROBE_PULSE_TTL" in ''|*[!0-9]*|0) FM_BACKGROUND_PROBE_PULSE_TTL=120 ;; esac
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

fm_reconcile_capture_stream() {
  local file=$1
  {
    head -c "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES"
    cat >/dev/null
  } > "$file"
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

fm_reconcile_process_parent_pid() {  # <pid>
  local out
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  out=$(LC_ALL=C ps -p "$1" -o ppid= 2>/dev/null) || return 1
  out=${out#"${out%%[![:space:]]*}"}
  out=${out%"${out##*[![:space:]]}"}
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
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
  FM_RECONCILE_WAIT_PREDICATE=
  FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE=
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
        FM_RECONCILE_WAIT_PREDICATE=$(fm_reconcile_record_value "$wait_file" predicate)
        FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE=$(fm_reconcile_record_value "$wait_file" probe_initial_evidence)
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
    FM_RECONCILE_WAIT_LIFECYCLE_GENERATION=$FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION
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

fm_reconcile_predicate_evaluate() {  # <executable>; populates WAIT_RESULT/EVIDENCE
  local predicate=$1 out='' stderr='' diagnostic='' rc=0 rc_file stderr_file
  if [ -z "$predicate" ] || [ ! -f "$predicate" ] || [ ! -x "$predicate" ]; then
    FM_RECONCILE_WAIT_RESULT=failed
    FM_RECONCILE_WAIT_EVIDENCE="predicate missing or not executable: ${predicate:-<empty>}"
    return
  fi
  rc_file="$FM_RECONCILE_WAIT_FILE.predicate-rc.${BASHPID:-$$}"
  stderr_file="$FM_RECONCILE_WAIT_FILE.predicate-stderr.${BASHPID:-$$}"
  out=$(
    fm_reconcile_bounded "$FM_EXTERNAL_WAIT_TIMEOUT" "$predicate" \
      2> >(fm_reconcile_capture_stream "$stderr_file") | {
      head -c "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES"
      cat >/dev/null
    }
    printf '%s\n' "${PIPESTATUS[0]}" > "$rc_file"
    wait || true
  )
  rc=$(cat "$rc_file" 2>/dev/null || printf '125')
  stderr=$(cat "$stderr_file" 2>/dev/null || true)
  rm -f "$rc_file" "$stderr_file"
  case "$rc" in ''|*[!0-9]*) rc=125 ;; esac
  out=$(fm_reconcile_clean_value "$out")
  stderr=$(fm_reconcile_clean_value "$stderr")
  diagnostic=$out
  [ -z "$stderr" ] || diagnostic="${diagnostic:+$diagnostic; }$stderr"
  case "$rc" in
    0)
      if [ -n "$out" ]; then
        FM_RECONCILE_WAIT_RESULT=complete
        FM_RECONCILE_WAIT_EVIDENCE=$out
      else
        FM_RECONCILE_WAIT_RESULT=pending
        FM_RECONCILE_WAIT_EVIDENCE="predicate pending${stderr:+; stderr: $stderr}"
      fi
      ;;
    1)
      FM_RECONCILE_WAIT_RESULT=pending
      FM_RECONCILE_WAIT_EVIDENCE=${diagnostic:-predicate pending}
      ;;
    124|125)
      FM_RECONCILE_WAIT_RESULT=failed
      FM_RECONCILE_WAIT_EVIDENCE="predicate timeout or no bounded runner${diagnostic:+: $diagnostic}"
      ;;
    *)
      FM_RECONCILE_WAIT_RESULT=failed
      FM_RECONCILE_WAIT_EVIDENCE="predicate exited $rc${diagnostic:+: $diagnostic}"
      ;;
  esac
}

fm_reconcile_wait_evaluate() {  # [record] [now]; uses WAIT_*; populates RESULT/EVIDENCE/progress
  local record=${1:-} now=${2:-} out='' stderr='' diagnostic='' rc=0 current_identity post_identity current_cwd current_progress rc_file stderr_file
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
      fm_reconcile_predicate_evaluate "$FM_RECONCILE_WAIT_TARGET"
      ;;
    process)
      case "$FM_RECONCILE_WAIT_ROLE" in
        external-wait|working-command|background-probe) : ;;
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
            if [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ]; then
              FM_RECONCILE_WAIT_RESULT=failed
              FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID exited while its predicate was pending"
            else
              FM_RECONCILE_WAIT_RESULT=complete
              FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
            fi
          elif ! current_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID"); then
            if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
              if [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ]; then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID exited while its predicate was pending"
              else
                FM_RECONCILE_WAIT_RESULT=complete
                FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
              fi
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
            if [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ]; then
              if [ -z "$FM_RECONCILE_WAIT_PREDICATE" ] || [ -z "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" ]; then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE='background-probe registration is missing its predicate baseline'
              elif ! current_cwd=$(fm_reconcile_process_cwd "$FM_RECONCILE_WAIT_PID"); then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID cwd is unreadable"
              elif ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_WORKTREE" \
                && ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_TASKTMP"; then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID left its task-scoped roots (cwd ${current_cwd:-unreadable})"
              elif ! post_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID"); then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID post-observation identity is unreadable"
              elif [ "$post_identity" != "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
                FM_RECONCILE_WAIT_RESULT=failed
                FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID identity changed"
              else
                fm_reconcile_predicate_evaluate "$FM_RECONCILE_WAIT_PREDICATE"
                if [ "$FM_RECONCILE_WAIT_RESULT" = pending ]; then
                  if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID exited while its predicate was pending"
                  elif ! post_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID"); then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID post-predicate identity is unreadable"
                  elif [ "$post_identity" != "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID identity changed"
                  fi
                fi
              fi
            elif [ "$FM_RECONCILE_WAIT_ROLE" = working-command ]; then
              case "$FM_RECONCILE_WAIT_PROGRESS_GRACE" in
                ''|*[!0-9]*|0)
                  FM_RECONCILE_WAIT_RESULT=failed
                  FM_RECONCILE_WAIT_EVIDENCE='registered command progress grace is invalid'
                  ;;
                *)
                  if ! current_cwd=$(fm_reconcile_process_cwd "$FM_RECONCILE_WAIT_PID"); then
                    if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
                      FM_RECONCILE_WAIT_RESULT=complete
                      FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
                    else
                      FM_RECONCILE_WAIT_RESULT=failed
                      FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID cwd is unreadable"
                    fi
                  elif ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_WORKTREE" \
                    && ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_TASKTMP"; then
                    FM_RECONCILE_WAIT_RESULT=failed
                    FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID left its task-scoped roots (cwd ${current_cwd:-unreadable})"
                  elif ! current_progress=$(fm_reconcile_process_tree_signature "$FM_RECONCILE_WAIT_PID"); then
                    if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
                      FM_RECONCILE_WAIT_RESULT=complete
                      FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
                    else
                      FM_RECONCILE_WAIT_RESULT=failed
                      FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID progress is not observable"
                    fi
                  elif ! post_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID"); then
                    if ! fm_reconcile_pid_alive "$FM_RECONCILE_WAIT_PID"; then
                      FM_RECONCILE_WAIT_RESULT=complete
                      FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID exited"
                    else
                      FM_RECONCILE_WAIT_RESULT=failed
                      FM_RECONCILE_WAIT_EVIDENCE="registered command $FM_RECONCILE_WAIT_PID post-observation identity is unreadable"
                    fi
                  elif [ "$post_identity" != "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
                    FM_RECONCILE_WAIT_RESULT=complete
                    FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID identity changed or exited"
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
            if [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ]; then
              FM_RECONCILE_WAIT_RESULT=failed
              FM_RECONCILE_WAIT_EVIDENCE="registered background-probe child $FM_RECONCILE_WAIT_PID identity changed"
            else
              FM_RECONCILE_WAIT_RESULT=complete
              FM_RECONCILE_WAIT_EVIDENCE="registered process $FM_RECONCILE_WAIT_PID identity changed or exited"
            fi
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
      stderr_file="$FM_RECONCILE_WAIT_FILE.check-stderr.${BASHPID:-$$}"
      out=$(
        fm_reconcile_bounded "$FM_LEGACY_CHECK_TIMEOUT" bash "$FM_RECONCILE_WAIT_TARGET" \
          2> >(fm_reconcile_capture_stream "$stderr_file") | {
          head -c "$FM_EXTERNAL_WAIT_OUTPUT_MAX_BYTES"
          cat >/dev/null
        }
        printf '%s\n' "${PIPESTATUS[0]}" > "$rc_file"
        wait || true
      )
      rc=$(cat "$rc_file" 2>/dev/null || printf '125')
      stderr=$(cat "$stderr_file" 2>/dev/null || true)
      rm -f "$rc_file" "$stderr_file"
      case "$rc" in ''|*[!0-9]*) rc=125 ;; esac
      out=$(fm_reconcile_clean_value "$out")
      stderr=$(fm_reconcile_clean_value "$stderr")
      diagnostic=$out
      [ -z "$stderr" ] || diagnostic="${diagnostic:+$diagnostic; }$stderr"
      case "$rc" in
        0)
          if [ -n "$out" ]; then
            FM_RECONCILE_WAIT_RESULT=complete
            FM_RECONCILE_WAIT_EVIDENCE=$out
          else
            FM_RECONCILE_WAIT_RESULT=pending
            FM_RECONCILE_WAIT_EVIDENCE="legacy check pending${stderr:+; stderr: $stderr}"
          fi
          ;;
        1)
          FM_RECONCILE_WAIT_RESULT=pending
          FM_RECONCILE_WAIT_EVIDENCE=${diagnostic:-legacy check pending}
          ;;
        124|125)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE="legacy check timeout or no bounded runner${diagnostic:+: $diagnostic}"
          ;;
        *)
          FM_RECONCILE_WAIT_RESULT=failed
          FM_RECONCILE_WAIT_EVIDENCE="legacy check exited $rc${diagnostic:+: $diagnostic}"
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

fm_reconcile_background_probe_pulse_load() {  # <state-dir> <id>
  local state=$1 id=$2 pulse
  pulse="$state/$id.probe-pulse"
  FM_RECONCILE_PROBE_PULSE_FILE=$pulse
  FM_RECONCILE_PROBE_PULSE_SIGNATURE=$(fm_reconcile_file_signature "$pulse")
  FM_RECONCILE_PROBE_PULSE_STATE=$(fm_reconcile_record_value "$pulse" state)
  FM_RECONCILE_PROBE_PULSE_ID=$(fm_reconcile_record_value "$pulse" pulse_id)
  FM_RECONCILE_PROBE_PULSE_TASK=$(fm_reconcile_record_value "$pulse" task)
  FM_RECONCILE_PROBE_PULSE_LIFECYCLE=$(fm_reconcile_record_value "$pulse" lifecycle_generation)
  FM_RECONCILE_PROBE_PULSE_REGISTRATION=$(fm_reconcile_record_value "$pulse" registration_id)
  FM_RECONCILE_PROBE_PULSE_WAIT_SIGNATURE=$(fm_reconcile_record_value "$pulse" wait_signature)
  FM_RECONCILE_PROBE_PULSE_ENDPOINT=$(fm_reconcile_record_value "$pulse" endpoint)
  FM_RECONCILE_PROBE_PULSE_PID=$(fm_reconcile_record_value "$pulse" pid)
  FM_RECONCILE_PROBE_PULSE_PID_IDENTITY=$(fm_reconcile_record_value "$pulse" pid_identity)
  FM_RECONCILE_PROBE_PULSE_STATUS_SEQUENCE=$(fm_reconcile_record_value "$pulse" status_sequence)
  FM_RECONCILE_PROBE_PULSE_STATUS_SIGNATURE=$(fm_reconcile_record_value "$pulse" status_signature)
  FM_RECONCILE_PROBE_PULSE_STATUS_SIGNAL=$(fm_reconcile_record_value "$pulse" status_signal_signature)
  FM_RECONCILE_PROBE_PULSE_WAIT_EVIDENCE=$(fm_reconcile_record_value "$pulse" wait_evidence)
  FM_RECONCILE_PROBE_PULSE_WORKING_MARKER=$(fm_reconcile_record_value "$pulse" working_marker_signature)
  FM_RECONCILE_PROBE_PULSE_BLOCKED_MARKER=$(fm_reconcile_record_value "$pulse" blocked_marker_signature)
  FM_RECONCILE_PROBE_PULSE_COMPOSER_MARKER=$(fm_reconcile_record_value "$pulse" composer_marker_signature)
  FM_RECONCILE_PROBE_PULSE_ISSUED_AT=$(fm_reconcile_record_value "$pulse" issued_at)
  FM_RECONCILE_PROBE_PULSE_EXPIRES_AT=$(fm_reconcile_record_value "$pulse" expires_at)
  : "$FM_RECONCILE_PROBE_PULSE_SIGNATURE" "$FM_RECONCILE_PROBE_PULSE_ID"
}

fm_reconcile_background_probe_active() {  # <state-dir> <id>
  local state=$1 id=$2 record
  record="$state/$id.reconciled"
  if [ -f "$record" ]; then
    [ "$(fm_reconcile_record_value "$record" background_probe_armed)" = 1 ]
    return
  fi
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]
}

fm_reconcile_background_probe_pulse_owned() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} meta record generation pulse_signature current_identity current_cwd now
  local meta_signature record_signature wait_signature
  FM_RECONCILE_BACKGROUND_PROBE_REJECTION=
  meta="$state/$id.meta"
  record="$state/$id.reconciled"
  [ -f "$meta" ] && [ -f "$record" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='reconciled task or metadata is absent'; return 1; }
  meta_signature=$(fm_reconcile_file_signature "$meta")
  record_signature=$(fm_reconcile_file_signature "$record")
  generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  [ -n "$generation" ] \
    && [ "$(fm_reconcile_record_value "$record" lifecycle_generation)" = "$generation" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='task lifecycle changed'; return 1; }
  [ -n "$endpoint" ] || endpoint=$(fm_reconcile_endpoint "$meta")
  fm_reconcile_wait_load "$state" "$id"
  wait_signature=$FM_RECONCILE_WAIT_SIGNATURE
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  pulse_signature=$FM_RECONCILE_PROBE_PULSE_SIGNATURE
  [ "$(fm_reconcile_record_value "$FM_RECONCILE_PROBE_PULSE_FILE" schema)" = fm-background-probe-pulse.v1 ] \
    && [ -n "$FM_RECONCILE_PROBE_PULSE_ID" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_TASK" = "$id" ] \
    && [ "$FM_RECONCILE_WAIT_KIND" = process ] \
    && [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ] \
    && [ "$FM_RECONCILE_WAIT_LIFECYCLE_GENERATION" = "$generation" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_LIFECYCLE" = "$generation" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_REGISTRATION" = "$FM_RECONCILE_WAIT_REGISTRATION_ID" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_WAIT_SIGNATURE" = "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_ENDPOINT" = "$endpoint" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_PID" = "$FM_RECONCILE_WAIT_PID" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_PID_IDENTITY" = "$FM_RECONCILE_WAIT_PID_IDENTITY" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SEQUENCE" = "$(fm_reconcile_record_value "$record" background_probe_status_sequence)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SIGNATURE" = "$(fm_reconcile_record_value "$record" background_probe_status_signature)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SIGNAL" = "$(fm_reconcile_record_value "$record" background_probe_status_signal_signature)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_WAIT_EVIDENCE" = "$(fm_reconcile_record_value "$record" background_probe_wait_evidence)" ] \
    && [ -n "$FM_RECONCILE_PROBE_PULSE_WORKING_MARKER" ] \
    && [ -n "$FM_RECONCILE_PROBE_PULSE_BLOCKED_MARKER" ] \
    && [ -n "$FM_RECONCILE_PROBE_PULSE_COMPOSER_MARKER" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse ownership does not match its lifecycle, registration, endpoint, child, or paused baseline'; return 1; }
  case "$FM_RECONCILE_PROBE_PULSE_STATE" in
    armed|consumed|invalidated) ;;
    *) FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse state is invalid'; return 1 ;;
  esac
  current_identity=$(fm_reconcile_process_identity "$FM_RECONCILE_WAIT_PID" 2>/dev/null || true)
  [ -n "$current_identity" ] && [ "$current_identity" = "$FM_RECONCILE_WAIT_PID_IDENTITY" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='registered background-probe child identity is not current'; return 1; }
  current_cwd=$(fm_reconcile_process_cwd "$FM_RECONCILE_WAIT_PID" 2>/dev/null || true)
  if ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_WORKTREE" \
    && ! fm_reconcile_path_is_within "$current_cwd" "$FM_RECONCILE_WAIT_OWNER_TASKTMP"; then
    FM_RECONCILE_BACKGROUND_PROBE_REJECTION='registered background-probe child is outside its task-scoped roots'
    return 1
  fi
  if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
    [ "$(fm_reconcile_record_value "$record" background_probe_armed)" = 1 ] \
      || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='armed pulse has no current reconciled baseline'; return 1; }
  fi
  now=$(date +%s)
  case "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT:$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" in
    *[!0-9:]*) FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse freshness is invalid'; return 1 ;;
  esac
  [ "$now" -ge "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT" ] \
    && [ "$now" -le "$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse expired'; return 1; }
  [ "$(fm_reconcile_file_signature "$meta")" = "$meta_signature" ] \
    && [ "$(fm_reconcile_file_signature "$record")" = "$record_signature" ] \
    && [ "$(fm_reconcile_file_signature "$FM_RECONCILE_WAIT_FILE")" = "$wait_signature" ] \
    && [ "$(fm_reconcile_file_signature "$FM_RECONCILE_PROBE_PULSE_FILE")" = "$pulse_signature" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse changed during validation'; return 1; }
}

fm_reconcile_background_probe_baseline_valid() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} record meta generation status_file status_before status_after
  local pending pending_version notified notified_version observed now age record_signature fresh_secs
  FM_RECONCILE_BACKGROUND_PROBE_REJECTION=
  record="$state/$id.reconciled"
  meta="$state/$id.meta"
  status_file="$state/$id.status"
  [ -f "$record" ] && [ -f "$meta" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='reconciled task or metadata is absent'; return 1; }
  record_signature=$(fm_reconcile_file_signature "$record")
  case "$record_signature" in
    absent|unreadable) FM_RECONCILE_BACKGROUND_PROBE_REJECTION='reconciled record is unreadable'; return 1 ;;
  esac
  generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  [ -n "$generation" ] \
    && [ "$(fm_reconcile_record_value "$record" lifecycle_generation)" = "$generation" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='task lifecycle changed'; return 1; }
  [ "$(fm_reconcile_record_value "$record" background_probe_armed)" = 1 ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='background probe is not armed'; return 1; }
  [ -n "$endpoint" ] || endpoint=$(fm_reconcile_endpoint "$meta")
  [ "$(fm_reconcile_endpoint "$meta")" = "$endpoint" ] \
    && [ "$(fm_reconcile_record_value "$record" background_probe_endpoint)" = "$endpoint" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='registered endpoint changed'; return 1; }
  observed=$(fm_reconcile_record_value "$record" observed_at)
  case "$observed" in ''|*[!0-9]*) observed=0 ;; esac
  now=$(date +%s)
  age=$((now - observed))
  [ "$age" -ge 0 ] || age=0
  fresh_secs=${FM_RECONCILE_FRESH_SECS:-60}
  case "$fresh_secs" in ''|*[!0-9]*|0) fresh_secs=60 ;; esac
  [ "$observed" -gt 0 ] && [ "$age" -le "$fresh_secs" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='reconciled baseline is stale'; return 1; }
  pending=$(fm_reconcile_record_value "$record" pending_action_token)
  pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  notified=$(fm_reconcile_record_value "$record" notified_action_token)
  notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  if [ -n "$pending" ] \
    && { [ "$pending" != "$notified" ] || [ "$pending_version" != "$notified_version" ]; }; then
    FM_RECONCILE_BACKGROUND_PROBE_REJECTION='an actionable transition is pending delivery'
    return 1
  fi
  status_before=$(fm_reconcile_signal_signature "$status_file")
  if [ "$(fm_reconcile_status_sequence "$status_file")" != "$(fm_reconcile_record_value "$record" background_probe_status_sequence)" ] \
    || [ "$(fm_reconcile_file_signature "$status_file")" != "$(fm_reconcile_record_value "$record" background_probe_status_signature)" ] \
    || [ "$(fm_reconcile_status_verb "$(fm_reconcile_last_status_event "$status_file" || true)")" != paused ]; then
    FM_RECONCILE_BACKGROUND_PROBE_REJECTION='paused status baseline changed'
    return 1
  fi
  status_after=$(fm_reconcile_signal_signature "$status_file")
  [ "$status_before" = "$status_after" ] \
    && [ "$status_after" = "$(fm_reconcile_record_value "$record" background_probe_status_signal_signature)" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='paused status freshness changed'; return 1; }
  fm_reconcile_wait_load "$state" "$id"
  [ "$FM_RECONCILE_WAIT_KIND" = process ] \
    && [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ] \
    && [ "$FM_RECONCILE_WAIT_SIGNATURE" = "$(fm_reconcile_record_value "$record" background_probe_wait_signature)" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='background-probe registration changed'; return 1; }
  fm_reconcile_wait_evaluate "$record" "$now"
  [ "$FM_RECONCILE_WAIT_RESULT" = pending ] \
    && [ "$FM_RECONCILE_WAIT_EVIDENCE" = "$(fm_reconcile_record_value "$record" background_probe_wait_evidence)" ] \
    && [ "$FM_RECONCILE_WAIT_EVIDENCE" = "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" ] \
    && [ "$(fm_reconcile_file_signature "$FM_RECONCILE_WAIT_FILE")" = "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    && [ "$(fm_reconcile_file_signature "$record")" = "$record_signature" ] \
    && [ "$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)" = "$generation" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION="registered child or predicate changed: ${FM_RECONCILE_WAIT_EVIDENCE:-unreadable evidence}"; return 1; }
}

fm_reconcile_background_probe_pulse_valid() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} now marker marker_signature composer_marker composer_signature composer_state
  fm_reconcile_background_probe_baseline_valid "$state" "$id" "$endpoint" || return 1
  [ -n "$endpoint" ] || endpoint=$(fm_reconcile_endpoint "$state/$id.meta")
  fm_reconcile_background_probe_pulse_owned "$state" "$id" "$endpoint" || return 1
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='no one-shot probe pulse is armed'; return 1; }
  now=$(date +%s)
  case "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT:$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" in
    *[!0-9:]*) FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse freshness is invalid'; return 1 ;;
  esac
  [ "$now" -ge "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT" ] \
    && [ "$now" -le "$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse expired'; return 1; }
  [ "$FM_RECONCILE_PROBE_PULSE_LIFECYCLE" = "$FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_REGISTRATION" = "$FM_RECONCILE_WAIT_REGISTRATION_ID" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_WAIT_SIGNATURE" = "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_ENDPOINT" = "$endpoint" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_PID" = "$FM_RECONCILE_WAIT_PID" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_PID_IDENTITY" = "$FM_RECONCILE_WAIT_PID_IDENTITY" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SEQUENCE" = "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_sequence)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SIGNATURE" = "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_signature)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_STATUS_SIGNAL" = "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_signal_signature)" ] \
    && [ "$FM_RECONCILE_PROBE_PULSE_WAIT_EVIDENCE" = "$FM_RECONCILE_WAIT_EVIDENCE" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse ownership no longer matches its child, check, endpoint, or paused baseline'; return 1; }
  marker=$(fm_transition_working_marker_path "$state" "$endpoint")
  marker_signature=$(fm_reconcile_file_signature "$marker")
  case "$marker_signature" in
    absent|unreadable) FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse has no correlated working edge'; return 1 ;;
  esac
  [ "$marker_signature" != "$FM_RECONCILE_PROBE_PULSE_WORKING_MARKER" ] \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse did not observe a post-arm working edge'; return 1; }
  composer_marker=$(fm_transition_composer_marker_path "$state" "$endpoint")
  composer_signature=$(fm_reconcile_file_signature "$composer_marker")
  if [ "$composer_signature" != "$FM_RECONCILE_PROBE_PULSE_COMPOSER_MARKER" ]; then
    composer_state=$(fm_reconcile_record_value "$composer_marker" state)
    FM_RECONCILE_BACKGROUND_PROBE_REJECTION="composer state changed while pulse was armed: ${composer_state:-unknown}"
    return 1
  fi
}

fm_reconcile_background_probe_pulse_set_state() {  # <pulse-file> <state> [reason]
  local pulse=$1 state=$2 reason=${3:-} tmp
  tmp="$pulse.state.${BASHPID:-$$}"
  awk -v state="$state" -v reason="$(fm_reconcile_clean_value "$reason")" -v now="$(date +%s)" '
    BEGIN { wrote_state = 0; wrote_reason = 0; wrote_at = 0 }
    /^state=/ { print "state=" state; wrote_state = 1; next }
    /^state_reason=/ { print "state_reason=" reason; wrote_reason = 1; next }
    /^state_changed_at=/ { print "state_changed_at=" now; wrote_at = 1; next }
    { print }
    END {
      if (!wrote_state) print "state=" state
      if (!wrote_reason) print "state_reason=" reason
      if (!wrote_at) print "state_changed_at=" now
    }
  ' "$pulse" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$pulse"
}

fm_reconcile_background_probe_arm_pulse() {  # <state-dir> <id> <child-pid>
  local state=$1 id=$2 child_pid=$3 endpoint pulse pulse_id now expires marker marker_signature blocked_marker blocked_marker_signature
  local composer_marker composer_marker_signature
  local invoker_pid invoker_identity tmp arm_rc=0
  case "$child_pid" in ''|*[!0-9]*) return 2 ;; esac
  invoker_pid=$(fm_reconcile_process_parent_pid "${BASHPID:-$$}" 2>/dev/null || true)
  invoker_identity=$(fm_reconcile_process_identity "$invoker_pid" 2>/dev/null || true)
  pulse="$state/$id.probe-pulse"
  fm_reconcile_lock_acquire "$state" "$id"
  endpoint=$(fm_reconcile_endpoint "$state/$id.meta")
  if ! fm_reconcile_background_probe_baseline_valid "$state" "$id" "$endpoint"; then
    arm_rc=1
  elif [ "$child_pid" != "$FM_RECONCILE_WAIT_PID" ] \
    || [ "$invoker_pid" != "$FM_RECONCILE_WAIT_PID" ] \
    || [ -z "$invoker_identity" ] \
    || [ "$invoker_identity" != "$FM_RECONCILE_WAIT_PID_IDENTITY" ]; then
    FM_RECONCILE_BACKGROUND_PROBE_REJECTION='pulse invocation is not owned by the registered background-probe child identity'
    arm_rc=1
  else
    fm_reconcile_background_probe_pulse_load "$state" "$id"
    if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
      FM_RECONCILE_BACKGROUND_PROBE_REJECTION='a one-shot background-probe pulse is already armed'
      arm_rc=1
    fi
  fi
  if [ "$arm_rc" -eq 0 ]; then
    pulse_id=$(fm_task_identity_new_token) || arm_rc=1
    now=$(date +%s)
    expires=$((now + FM_BACKGROUND_PROBE_PULSE_TTL))
    marker=$(fm_transition_working_marker_path "$state" "$endpoint")
    marker_signature=$(fm_reconcile_file_signature "$marker")
    blocked_marker=$(fm_transition_blocked_marker_path "$state" "$endpoint")
    blocked_marker_signature=$(fm_reconcile_file_signature "$blocked_marker")
    composer_marker=$(fm_transition_composer_marker_path "$state" "$endpoint")
    composer_marker_signature=$(fm_reconcile_file_signature "$composer_marker")
    tmp="$pulse.tmp.${BASHPID:-$$}"
    if [ "$arm_rc" -eq 0 ]; then
      {
        printf 'schema=fm-background-probe-pulse.v1\n'
        printf 'state=armed\n'
        printf 'pulse_id=%s\n' "$pulse_id"
        printf 'task=%s\n' "$id"
        printf 'lifecycle_generation=%s\n' "$FM_RECONCILE_WAIT_CURRENT_LIFECYCLE_GENERATION"
        printf 'registration_id=%s\n' "$FM_RECONCILE_WAIT_REGISTRATION_ID"
        printf 'wait_signature=%s\n' "$FM_RECONCILE_WAIT_SIGNATURE"
        printf 'endpoint=%s\n' "$(fm_reconcile_clean_value "$endpoint")"
        printf 'pid=%s\n' "$FM_RECONCILE_WAIT_PID"
        printf 'pid_identity=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WAIT_PID_IDENTITY")"
        printf 'status_sequence=%s\n' "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_sequence)"
        printf 'status_signature=%s\n' "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_signature)"
        printf 'status_signal_signature=%s\n' "$(fm_reconcile_record_value "$state/$id.reconciled" background_probe_status_signal_signature)"
        printf 'wait_evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WAIT_EVIDENCE")"
        printf 'working_marker_signature=%s\n' "$marker_signature"
        printf 'blocked_marker_signature=%s\n' "$blocked_marker_signature"
        printf 'composer_marker_signature=%s\n' "$composer_marker_signature"
        printf 'issued_at=%s\n' "$now"
        printf 'expires_at=%s\n' "$expires"
      } > "$tmp" || arm_rc=1
      if [ "$arm_rc" -eq 0 ] && ! mv -f "$tmp" "$pulse"; then arm_rc=1; fi
      rm -f "$tmp"
    fi
  fi
  fm_reconcile_lock_release "$state" "$id"
  [ "$arm_rc" -eq 0 ] || return "$arm_rc"
  printf '%s' "$pulse_id"
}

fm_reconcile_background_probe_consume_locked() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} pane_id record
  [ -n "$endpoint" ] || endpoint=$(fm_reconcile_endpoint "$state/$id.meta")
  fm_reconcile_background_probe_pulse_valid "$state" "$id" "$endpoint" || return 1
  pane_id=${endpoint#*:}
  record=$(fm_transition_record "$pane_id" "" "" blocked "")
  fm_transition_record_blocked "$state" "$endpoint" "$record" \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='correlated blocked-edge acknowledgement could not be persisted'; return 1; }
  fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" consumed \
    || { FM_RECONCILE_BACKGROUND_PROBE_REJECTION='probe pulse consumption could not be persisted'; return 1; }
}

fm_reconcile_background_probe_can_absorb() {  # <state-dir> <id> [endpoint]
  local state=$1 id=$2 endpoint=${3:-} absorb_rc=0
  fm_reconcile_lock_acquire "$state" "$id"
  if ! fm_reconcile_background_probe_consume_locked "$state" "$id" "$endpoint"; then
    absorb_rc=1
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$absorb_rc"
}

fm_reconcile_background_probe_observe_composer() {  # <state-dir> <id> <endpoint> <empty|pending|unknown>
  local state=$1 id=$2 endpoint=$3 composer=$4 out observe_rc=0 marker marker_signature marker_state
  case "$composer" in empty|pending|unknown) ;; *) composer=unknown ;; esac
  fm_reconcile_lock_acquire "$state" "$id"
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  if [ "$FM_RECONCILE_PROBE_PULSE_STATE" != armed ] \
    || ! fm_reconcile_background_probe_active "$state" "$id"; then
    observe_rc=2
  else
    marker=$(fm_transition_composer_marker_path "$state" "$endpoint")
    marker_signature=$(fm_reconcile_file_signature "$marker")
    if [ "$marker_signature" != "$FM_RECONCILE_PROBE_PULSE_COMPOSER_MARKER" ]; then
      marker_state=$(fm_reconcile_record_value "$marker" state)
      composer=${marker_state:-unknown}
    fi
  fi
  if [ "$observe_rc" -ne 0 ]; then
    :
  elif [ "$composer" != empty ]; then
    if out=$(fm_reconcile_background_probe_invalidate_locked "$state" "$id" "composer state changed while pulse was armed: $composer"); then
      [ -z "$out" ] || printf '%s\n' "$out"
    else
      observe_rc=$?
    fi
  else
    if [ "$FM_RECONCILE_PROBE_PULSE_STATE" != armed ]; then
      observe_rc=2
    fi
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$observe_rc"
}

fm_reconcile_background_probe_recover_pulse_locked() {  # <state-dir> <id>
  local state=$1 id=$2 record endpoint working_marker blocked_marker composer_marker
  local working_signature blocked_signature composer_signature composer_state reason
  record="$state/$id.reconciled"
  [ -f "$record" ] || return 0
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ] || return 0
  if [ "$(fm_reconcile_record_value "$record" background_probe_armed)" != 1 ]; then
    reason=$(fm_reconcile_record_value "$record" background_probe_invalidation_reason)
    [ -n "$reason" ] || reason=$(fm_reconcile_record_value "$record" pending_action_reason)
    [ -n "$reason" ] || reason='reconciled probe invalidation recovery'
    fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" invalidated "$reason"
    return
  fi
  case "$(fm_reconcile_record_value "$record" state)" in paused|idle) ;; *) return 0 ;; esac
  endpoint=$(fm_reconcile_record_value "$record" endpoint)
  working_marker=$(fm_transition_working_marker_path "$state" "$endpoint")
  blocked_marker=$(fm_transition_blocked_marker_path "$state" "$endpoint")
  composer_marker=$(fm_transition_composer_marker_path "$state" "$endpoint")
  working_signature=$(fm_reconcile_file_signature "$working_marker")
  blocked_signature=$(fm_reconcile_file_signature "$blocked_marker")
  composer_signature=$(fm_reconcile_file_signature "$composer_marker")
  if [ "$composer_signature" != "$FM_RECONCILE_PROBE_PULSE_COMPOSER_MARKER" ]; then
    composer_state=$(fm_reconcile_record_value "$composer_marker" state)
    fm_reconcile_background_probe_invalidate_locked "$state" "$id" \
      "composer state changed while pulse was armed: ${composer_state:-unknown}" >/dev/null
    return
  fi
  case "$working_signature:$blocked_signature" in *unreadable*) return 1 ;; esac
  if [ "$working_signature" != "$FM_RECONCILE_PROBE_PULSE_WORKING_MARKER" ] \
    && [ "$blocked_signature" != "$FM_RECONCILE_PROBE_PULSE_BLOCKED_MARKER" ]; then
    fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" consumed 'recovered committed identical-pause return'
  fi
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
    printf 'background_probe_armed=%s\n' "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_ARMED"
    printf 'background_probe_wait_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_WAIT_SIGNATURE")"
    printf 'background_probe_endpoint=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_ENDPOINT")"
    printf 'background_probe_status_sequence=%s\n' "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SEQUENCE"
    printf 'background_probe_status_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SIGNATURE")"
    printf 'background_probe_status_signal_signature=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SIGNAL_SIGNATURE")"
    printf 'background_probe_wait_evidence=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_WAIT_EVIDENCE")"
    printf 'background_probe_observed_at=%s\n' "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_OBSERVED_AT"
    printf 'background_probe_invalidation_sequence=%s\n' "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATION_SEQUENCE"
    printf 'background_probe_invalidation_reason=%s\n' "$(fm_reconcile_clean_value "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATION_REASON")"
    printf 'background_probe_invalidated_at=%s\n' "$FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATED_AT"
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
  if fm_reconcile_pid_alive "$owner_pid"; then
    [ -n "$owner_identity" ] || return 0
    current_identity=$(fm_reconcile_process_identity "$owner_pid" 2>/dev/null) || return 0
    [ "$current_identity" = "$owner_identity" ] && return 0
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

fm_reconcile_reset_stale_lifecycle_locked() {  # <state-dir> <id> <lifecycle-generation>
  local state=$1 id=$2 generation=$3 record wait pulse wait_generation registration kind marker
  record="$state/$id.reconciled"
  wait="$state/$id.wait"
  pulse="$state/$id.probe-pulse"
  if [ -f "$record" ] \
    && [ "$(fm_reconcile_record_value "$record" lifecycle_generation)" != "$generation" ]; then
    rm -f "$record" || return 1
  fi
  if [ -f "$pulse" ] \
    && [ "$(fm_reconcile_record_value "$pulse" lifecycle_generation)" != "$generation" ]; then
    rm -f "$pulse" || return 1
  fi
  [ -f "$wait" ] || return 0
  wait_generation=$(fm_reconcile_record_value "$wait" lifecycle_generation)
  [ "$wait_generation" = "$generation" ] && return 0
  case "$generation:$wait_generation" in legacy:*:) return 0 ;; esac
  kind=$(fm_reconcile_record_value "$wait" kind)
  registration=$(fm_reconcile_record_value "$wait" registration_id)
  marker=$(fm_reconcile_legacy_check_marker "$state/$id.check.sh")
  if [ "$kind" = legacy-check ] && [ -n "$registration" ] && [ "$marker" = "$registration" ]; then
    rm -f "$state/$id.check.sh" || return 1
  fi
  rm -f "$wait" "$state/$id.wait-commit" "$pulse"
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
  check_publish_tmp="$check_file.publish.tmp.${BASHPID:-$$}"
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
  local expected_signature expected_generation rescue_pending creation_phase claim_rc=0
  fm_reconcile_task_id_valid "$id" && fm_reconcile_generation_valid "$generation" && [ -d "$state" ] || return 2
  claim="$state/$id.spawn-claim"
  owner_pid=${BASHPID:-$$}
  owner_identity=$(fm_reconcile_process_identity "$owner_pid") || return 1
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_tombstone_active "$state" "$id"; then
    claim_rc=3
  elif [ -f "$claim" ]; then
    rescue_pending=$(fm_reconcile_record_value "$claim" rescue_pending)
    creation_phase=$(fm_reconcile_record_value "$claim" creation_phase)
    existing_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    existing_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    current_identity=$(fm_reconcile_process_identity "$existing_pid" 2>/dev/null || true)
    if [ "$rescue_pending" = 1 ] || [ -n "$creation_phase" ]; then
      if fm_reconcile_spawn_claim_recover_locked "$state" "$id" "$claim"; then
        claim_rc=0
      else
        claim_rc=5
      fi
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
      printf 'started_at=%s\n' "$(date +%s)"
    } > "$tmp" || claim_rc=1
    if [ "$claim_rc" -eq 0 ] && ! mv -f "$tmp" "$claim"; then claim_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$claim_rc"
}

fm_reconcile_spawn_claim_mark_creation_started() {  # <state-dir> <id> <generation> <backend> <backend-label> [scope] [home] [treehouse-project] [treehouse-holder]
  local state=$1 id=$2 generation=$3 backend=$4 backend_label=$5 backend_scope=${6:-} backend_home=${7:-} treehouse_project=${8:-} treehouse_holder=${9:-} claim tmp mark_rc=0
  local owner_pid owner_identity expected_signature expected_generation started_at
  claim="$state/$id.spawn-claim"
  fm_reconcile_lock_acquire "$state" "$id"
  if ! fm_reconcile_spawn_claim_matches_locked "$state" "$id" "$generation"; then
    mark_rc=3
  else
    owner_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    owner_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    expected_signature=$(fm_reconcile_record_value "$claim" expected_meta_signature)
    expected_generation=$(fm_reconcile_record_value "$claim" expected_meta_generation)
    started_at=$(fm_reconcile_record_value "$claim" started_at)
    tmp="$claim.tmp.${BASHPID:-$$}"
    {
      printf 'schema=fm-spawn-claim.v1\n'
      printf 'generation=%s\n' "$generation"
      printf 'owner_pid=%s\n' "$owner_pid"
      printf 'owner_identity=%s\n' "$owner_identity"
      printf 'expected_meta_signature=%s\n' "$expected_signature"
      printf 'expected_meta_generation=%s\n' "$expected_generation"
      printf 'started_at=%s\n' "$started_at"
      printf 'creation_started_at=%s\n' "$(date +%s)"
      printf 'creation_phase=backend-creation\n'
      printf 'backend=%s\n' "$(fm_reconcile_clean_value "$backend")"
      printf 'backend_label=%s\n' "$(fm_reconcile_clean_value "$backend_label")"
      [ -z "$backend_scope" ] || printf 'backend_scope=%s\n' "$(fm_reconcile_clean_value "$backend_scope")"
      [ -z "$backend_home" ] || printf 'backend_home=%s\n' "$(fm_reconcile_clean_value "$backend_home")"
      [ -z "$treehouse_project" ] || printf 'treehouse_project=%s\n' "$(fm_reconcile_clean_value "$treehouse_project")"
      [ -z "$treehouse_holder" ] || printf 'treehouse_holder=%s\n' "$(fm_reconcile_clean_value "$treehouse_holder")"
    } > "$tmp" || mark_rc=1
    if [ "$mark_rc" -eq 0 ] && ! mv -f "$tmp" "$claim"; then mark_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$mark_rc"
}

fm_reconcile_spawn_claim_mark_rescue_pending() {  # <state-dir> <id> <generation> <rescue-path>
  local state=$1 id=$2 generation=$3 rescue_path=$4 claim tmp mark_rc=0
  local owner_pid owner_identity expected_signature expected_generation creation_phase backend backend_label backend_scope backend_home treehouse_project treehouse_holder started_at creation_started_at
  claim="$state/$id.spawn-claim"
  fm_reconcile_lock_acquire "$state" "$id"
  if ! fm_reconcile_spawn_claim_matches_locked "$state" "$id" "$generation"; then
    mark_rc=3
  else
    owner_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    owner_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    expected_signature=$(fm_reconcile_record_value "$claim" expected_meta_signature)
    expected_generation=$(fm_reconcile_record_value "$claim" expected_meta_generation)
    creation_phase=$(fm_reconcile_record_value "$claim" creation_phase)
    backend=$(fm_reconcile_record_value "$claim" backend)
    backend_label=$(fm_reconcile_record_value "$claim" backend_label)
    backend_scope=$(fm_reconcile_record_value "$claim" backend_scope)
    backend_home=$(fm_reconcile_record_value "$claim" backend_home)
    treehouse_project=$(fm_reconcile_record_value "$claim" treehouse_project)
    treehouse_holder=$(fm_reconcile_record_value "$claim" treehouse_holder)
    started_at=$(fm_reconcile_record_value "$claim" started_at)
    creation_started_at=$(fm_reconcile_record_value "$claim" creation_started_at)
    tmp="$claim.tmp.${BASHPID:-$$}"
    {
      printf 'schema=fm-spawn-claim.v1\n'
      printf 'generation=%s\n' "$generation"
      printf 'owner_pid=%s\n' "$owner_pid"
      printf 'owner_identity=%s\n' "$owner_identity"
      printf 'expected_meta_signature=%s\n' "$expected_signature"
      printf 'expected_meta_generation=%s\n' "$expected_generation"
      [ -z "$started_at" ] || printf 'started_at=%s\n' "$started_at"
      [ -z "$creation_started_at" ] || printf 'creation_started_at=%s\n' "$creation_started_at"
      [ -z "$creation_phase" ] || printf 'creation_phase=%s\n' "$creation_phase"
      [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
      [ -z "$backend_label" ] || printf 'backend_label=%s\n' "$backend_label"
      [ -z "$backend_scope" ] || printf 'backend_scope=%s\n' "$backend_scope"
      [ -z "$backend_home" ] || printf 'backend_home=%s\n' "$backend_home"
      [ -z "$treehouse_project" ] || printf 'treehouse_project=%s\n' "$treehouse_project"
      [ -z "$treehouse_holder" ] || printf 'treehouse_holder=%s\n' "$treehouse_holder"
      printf 'rescue_pending=1\n'
      printf 'rescue_path=%s\n' "$(fm_reconcile_clean_value "$rescue_path")"
    } > "$tmp" || mark_rc=1
    if [ "$mark_rc" -eq 0 ] && ! mv -f "$tmp" "$claim"; then mark_rc=1; fi
    rm -f "$tmp"
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$mark_rc"
}

fm_reconcile_spawn_claim_recover_locked() {  # <state-dir> <id> <claim>
  local state=$1 id=$2 claim=$3 started age expected_signature expected_generation
  local backend backend_label backend_scope backend_home treehouse_project treehouse_holder rescue_path probe_root probe_rc owner_pid owner_identity current_identity
  owner_pid=$(fm_reconcile_record_value "$claim" owner_pid)
  owner_identity=$(fm_reconcile_record_value "$claim" owner_identity)
  current_identity=$(fm_reconcile_process_identity "$owner_pid" 2>/dev/null || true)
  if fm_reconcile_pid_alive "$owner_pid" \
    && { [ -z "$current_identity" ] || { [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; }; }; then
    return 1
  fi
  started=$(fm_reconcile_record_value "$claim" creation_started_at)
  case "$started" in
    ''|*[!0-9]*) age=$(fm_path_age "$claim") ;;
    *) age=$(( $(date +%s) - started )) ;;
  esac
  [ "$age" -ge "$FM_SPAWN_CLAIM_RECOVERY_SECS" ] || return 1
  expected_signature=$(fm_reconcile_record_value "$claim" expected_meta_signature)
  expected_generation=$(fm_reconcile_record_value "$claim" expected_meta_generation)
  [ "$(fm_reconcile_file_signature "$state/$id.meta")" = "$expected_signature" ] || return 1
  [ "$(fm_reconcile_meta_generation "$state/$id.meta" 2>/dev/null || true)" = "$expected_generation" ] || return 1
  backend=$(fm_reconcile_record_value "$claim" backend)
  backend_label=$(fm_reconcile_record_value "$claim" backend_label)
  backend_scope=$(fm_reconcile_record_value "$claim" backend_scope)
  backend_home=$(fm_reconcile_record_value "$claim" backend_home)
  treehouse_project=$(fm_reconcile_record_value "$claim" treehouse_project)
  treehouse_holder=$(fm_reconcile_record_value "$claim" treehouse_holder)
  rescue_path=$(fm_reconcile_record_value "$claim" rescue_path)
  [ -n "$backend" ] && [ -n "$backend_label" ] || return 1
  [ -n "$backend_home" ] || backend_home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$_FM_RECONCILE_LIB_DIR/.." && pwd)}}
  probe_root=${FM_ROOT:-$(cd "$_FM_RECONCILE_LIB_DIR/.." && pwd)}
  if fm_reconcile_bounded "$FM_SPAWN_CLAIM_PROBE_TIMEOUT" env \
    FM_HOME="$backend_home" FM_ROOT="$probe_root" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    bash -c '. "$1/fm-backend.sh"; fm_backend_spawn_claim_absent "$2" "$3" "$4" "$5" "$6" "$7"' \
    fm-spawn-claim-probe "$_FM_RECONCILE_LIB_DIR" "$backend" "$backend_label" "$backend_scope" "$rescue_path" "$treehouse_project" "$treehouse_holder"; then
    probe_rc=0
  else
    probe_rc=$?
  fi
  [ "$probe_rc" -eq 0 ] || return 1
  rm -f "$claim"
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
  local old_wait_kind old_wait_sig old_wait_state old_wait_evidence old_wait_seq old_pending old_reason old_notified
  local old_pending_version old_notified_version old_pending_observation old_notified_observation
  local old_status_signal old_turn_signal old_observer_seq
  local old_probe_armed old_probe_wait_sig old_probe_endpoint old_probe_status_seq old_probe_status_sig old_probe_status_signal
  local old_probe_wait_evidence old_probe_observed probe_armed probe_wait_sig probe_endpoint probe_status_seq probe_status_sig
  local old_probe_invalidation_seq old_probe_invalidation_reason old_probe_invalidated_at
  local probe_status_signal probe_wait_evidence probe_observed probe_invalidation_seq probe_invalidation_reason probe_invalidated_at
  local background_probe_return=0 pending_evidence_changed=0 pulse_now=0 probe_consume_after_write=0
  local current_state current_source current_detail status_seq status_sig status_signal_before status_signal_sig turn_signal_sig last_status
  local prior_endpoint prior_state prior_source prior_evidence prior_observed transition_seq
  local wait_seq pending pending_version reason observation_key pending_observation candidate_token='' candidate_reason='' event_note=''
  local pending_unacked=0 positive_working=0 current_positive_working=0
  local endpoint_changed=0 state_changed=0 source_changed=0 same_repository=0

  meta="$state/$id.meta"
  fm_reconcile_meta_matches "$state" "$id" "$meta_signature" "$lifecycle_generation" || return 0
  fm_reconcile_reset_stale_lifecycle_locked "$state" "$id" "$lifecycle_generation" || return 1
  fm_reconcile_background_probe_recover_pulse_locked "$state" "$id" || return 1
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
  old_wait_evidence=$(fm_reconcile_record_value "$record" wait_evidence)
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
  old_probe_armed=$(fm_reconcile_record_value "$record" background_probe_armed)
  old_probe_wait_sig=$(fm_reconcile_record_value "$record" background_probe_wait_signature)
  old_probe_endpoint=$(fm_reconcile_record_value "$record" background_probe_endpoint)
  old_probe_status_seq=$(fm_reconcile_record_value "$record" background_probe_status_sequence)
  old_probe_status_sig=$(fm_reconcile_record_value "$record" background_probe_status_signature)
  old_probe_status_signal=$(fm_reconcile_record_value "$record" background_probe_status_signal_signature)
  old_probe_wait_evidence=$(fm_reconcile_record_value "$record" background_probe_wait_evidence)
  old_probe_observed=$(fm_reconcile_record_value "$record" background_probe_observed_at)
  old_probe_invalidation_seq=$(fm_reconcile_record_value "$record" background_probe_invalidation_sequence)
  old_probe_invalidation_reason=$(fm_reconcile_record_value "$record" background_probe_invalidation_reason)
  old_probe_invalidated_at=$(fm_reconcile_record_value "$record" background_probe_invalidated_at)
  case "$old_transition_seq" in ''|*[!0-9]*) old_transition_seq=0 ;; esac
  case "$old_wait_seq" in ''|*[!0-9]*) old_wait_seq=0 ;; esac
  case "$old_observer_seq" in ''|*[!0-9]*) old_observer_seq=0 ;; esac
  case "$old_probe_armed" in 1) ;; *) old_probe_armed=0 ;; esac
  case "$old_probe_status_seq" in ''|*[!0-9]*) old_probe_status_seq=0 ;; esac
  case "$old_probe_observed" in ''|*[!0-9]*) old_probe_observed=0 ;; esac
  case "$old_probe_invalidation_seq" in ''|*[!0-9]*) old_probe_invalidation_seq=0 ;; esac
  case "$old_probe_invalidated_at" in ''|*[!0-9]*) old_probe_invalidated_at=0 ;; esac
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
  probe_armed=$old_probe_armed
  probe_wait_sig=$old_probe_wait_sig
  probe_endpoint=$old_probe_endpoint
  probe_status_seq=$old_probe_status_seq
  probe_status_sig=$old_probe_status_sig
  probe_status_signal=$old_probe_status_signal
  probe_wait_evidence=$old_probe_wait_evidence
  probe_observed=$old_probe_observed
  probe_invalidation_seq=$old_probe_invalidation_seq
  probe_invalidation_reason=
  probe_invalidated_at=$old_probe_invalidated_at
  if [ -n "$old_pending" ] \
    && { [ "$old_pending" != "$old_notified" ] || [ "$old_pending_version" != "$old_notified_version" ]; }; then
    pending_unacked=1
  fi

  fm_reconcile_wait_load "$state" "$id"
  fm_reconcile_wait_evaluate "$record" "$now"
  case "$current_state:$FM_RECONCILE_WAIT_PRESENT" in
    paused:0|blocked:0|parked:0)
      FM_RECONCILE_WAIT_RESULT=unobservable
      FM_RECONCILE_WAIT_EVIDENCE='no completion predicate or process signal registered'
      ;;
  esac
  wait_seq=$old_wait_seq
  if [ "$old_wait_kind" != "$FM_RECONCILE_WAIT_KIND" ] \
    || [ "$old_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    || [ "$old_wait_state" != "$FM_RECONCILE_WAIT_RESULT" ]; then
    wait_seq=$((old_wait_seq + 1))
  elif [ "$FM_RECONCILE_WAIT_RESULT" = pending ] \
    && [ "$old_wait_evidence" != "$FM_RECONCILE_WAIT_EVIDENCE" ] \
    && { [ "$FM_RECONCILE_WAIT_KIND" = predicate ] \
      || [ "$FM_RECONCILE_WAIT_KIND" = legacy-check ] \
      || [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ]; }; then
    wait_seq=$((old_wait_seq + 1))
    pending_evidence_changed=1
  fi
  if [ "$FM_RECONCILE_WAIT_RESULT" = pending ] && [ "$FM_RECONCILE_WAIT_WORKING" -eq 1 ] \
    && { [ "$current_state" = working ] || [ "$current_state" = idle ] || [ "$current_state" = unknown ] \
      || { [ "$current_source" = status-log ] \
        && { [ "$current_state" = paused ] || [ "$current_state" = blocked ] || [ "$current_state" = parked ]; }; }; }; then
    current_state=working
    current_source=owned-command
    current_detail=$FM_RECONCILE_WAIT_EVIDENCE
    raw="state: working · source: owned-command · $current_detail"
  fi

  if [ "$old_probe_armed" -eq 1 ]; then
    if [ "$FM_RECONCILE_WAIT_ROLE" != background-probe ]; then
      probe_invalidation_reason='registration role changed while armed'
    elif [ "$FM_RECONCILE_WAIT_RESULT" != pending ]; then
      probe_invalidation_reason="predicate or child became $FM_RECONCILE_WAIT_RESULT while armed: $FM_RECONCILE_WAIT_EVIDENCE"
    elif [ "$FM_RECONCILE_WAIT_EVIDENCE" != "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" ] \
      || [ "$probe_wait_evidence" != "$FM_RECONCILE_WAIT_EVIDENCE" ]; then
      probe_invalidation_reason="predicate evidence changed while armed: $FM_RECONCILE_WAIT_EVIDENCE"
    elif [ "$probe_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ]; then
      probe_invalidation_reason='background-probe registration changed while armed'
    elif [ "$probe_endpoint" != "$endpoint" ]; then
      probe_invalidation_reason="endpoint changed while armed from ${probe_endpoint:-none} to ${endpoint:-none}"
    elif [ "$probe_status_seq" -ne "$status_seq" ] \
      || [ "$probe_status_sig" != "$status_sig" ] \
      || [ "$probe_status_signal" != "$status_signal_sig" ]; then
      probe_invalidation_reason="paused status baseline or freshness changed while armed (sequence $probe_status_seq to $status_seq)"
    elif [ "$current_state" = working ]; then
      fm_reconcile_background_probe_pulse_load "$state" "$id"
      pulse_now=$now
      case "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT:$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" in
        *[!0-9:]*) probe_invalidation_reason='working activity had no valid one-shot probe freshness' ;;
      esac
      if [ -z "$probe_invalidation_reason" ] \
        && { [ "$FM_RECONCILE_PROBE_PULSE_STATE" != armed ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_LIFECYCLE" != "$lifecycle_generation" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_REGISTRATION" != "$FM_RECONCILE_WAIT_REGISTRATION_ID" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_WAIT_SIGNATURE" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_ENDPOINT" != "$endpoint" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_PID" != "$FM_RECONCILE_WAIT_PID" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_PID_IDENTITY" != "$FM_RECONCILE_WAIT_PID_IDENTITY" ] \
          || [ "$FM_RECONCILE_PROBE_PULSE_WAIT_EVIDENCE" != "$FM_RECONCILE_WAIT_EVIDENCE" ] \
          || [ "$pulse_now" -lt "$FM_RECONCILE_PROBE_PULSE_ISSUED_AT" ] \
          || [ "$pulse_now" -gt "$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" ]; }; then
        probe_invalidation_reason='working activity was not owned by the registered child/check and an active one-shot pulse'
      fi
    elif [ "$current_state" != paused ] && [ "$current_state" != idle ]; then
      probe_invalidation_reason="disallowed task state $current_state from $current_source while armed"
    else
      fm_reconcile_background_probe_pulse_load "$state" "$id"
      if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
        case "$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" in
          ''|*[!0-9]*) probe_invalidation_reason='one-shot probe freshness became invalid while armed' ;;
          *) [ "$now" -le "$FM_RECONCILE_PROBE_PULSE_EXPIRES_AT" ] \
            || probe_invalidation_reason='one-shot probe expired before a correlated return' ;;
        esac
      fi
    fi
  fi
  if [ -n "$probe_invalidation_reason" ] && [ "$old_probe_armed" -eq 1 ]; then
    probe_armed=0
    probe_invalidation_seq=$((old_probe_invalidation_seq + 1))
    probe_invalidated_at=$now
  fi
  if [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ] \
    && [ "$FM_RECONCILE_WAIT_RESULT" = pending ] \
    && [ "$FM_RECONCILE_WAIT_EVIDENCE" = "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" ] \
    && [ "$probe_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    && [ "$pending_unacked" -eq 0 ] \
    && [ -z "$probe_invalidation_reason" ] \
    && { [ "$current_state" = paused ] || [ "$current_state" = idle ]; } \
    && [ "$(fm_reconcile_status_verb "$last_status")" = paused ] \
    && [ "$status_sig" != unreadable ] \
    && [ "$status_signal_sig" != unreadable ] \
    && [ "$status_signal_sig" != unstable ]; then
    probe_armed=1
    probe_wait_sig=$FM_RECONCILE_WAIT_SIGNATURE
    probe_endpoint=$endpoint
    probe_status_seq=$status_seq
    probe_status_sig=$status_sig
    probe_status_signal=$status_signal_sig
    probe_wait_evidence=$FM_RECONCILE_WAIT_EVIDENCE
    probe_observed=$now
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
  if [ "$positive_working" -eq 1 ] \
    && [ "$old_source" = pane ] \
    && { [ "$current_state" = paused ] || [ "$current_state" = idle ]; } \
    && [ "$probe_armed" -eq 1 ] \
    && [ "$probe_wait_sig" = "$FM_RECONCILE_WAIT_SIGNATURE" ] \
    && [ "$probe_endpoint" = "$endpoint" ] \
    && [ "$probe_status_seq" -eq "$status_seq" ] \
    && [ "$probe_status_sig" = "$status_sig" ] \
    && [ "$probe_status_signal" = "$status_signal_sig" ] \
    && [ "$probe_wait_evidence" = "$FM_RECONCILE_WAIT_EVIDENCE" ]; then
    if fm_reconcile_background_probe_pulse_valid "$state" "$id" "$endpoint"; then
      background_probe_return=1
      probe_consume_after_write=1
    else
      [ -n "$FM_RECONCILE_BACKGROUND_PROBE_REJECTION" ] \
        || FM_RECONCILE_BACKGROUND_PROBE_REJECTION='one-shot pulse consumption failed'
      probe_invalidation_reason="busy return was not correlated to its one-shot probe: $FM_RECONCILE_BACKGROUND_PROBE_REJECTION"
      probe_armed=0
      probe_invalidation_seq=$((old_probe_invalidation_seq + 1))
      probe_invalidated_at=$now
    fi
  fi

  case "$current_state" in
    paused|blocked|parked)
      if [ "$FM_RECONCILE_WAIT_PRESENT" -eq 0 ]; then
        if [ "$positive_working" -eq 1 ]; then
          candidate_token="transition:$transition_seq"
          candidate_reason="reconciled-transition ($old_state -> $current_state from positive $old_source evidence; source now $current_source; status event sequence $status_seq, last event: ${last_status:-none}; ${current_detail:-no detail}; external-wait-unobservable: $current_state task has no completion observer)"
        elif [ "$wait_seq" -ne "$old_wait_seq" ]; then
          candidate_token="wait:$wait_seq:unobservable"
          candidate_reason="external-wait-unobservable ($current_state task has no state/$id.wait predicate/process registration or legacy check; non-working waits require immediate intervention unless an observable external wait is registered; last status event sequence $status_seq: ${last_status:-none})"
        fi
      elif [ "$positive_working" -eq 1 ] && [ "$background_probe_return" -ne 1 ]; then
        candidate_token="transition:$transition_seq"
        candidate_reason="reconciled-transition ($old_state -> $current_state from positive $old_source evidence; source now $current_source; status event sequence $status_seq, last event: ${last_status:-none}; ${current_detail:-no detail})"
      fi
      ;;
    *)
      if [ "$positive_working" -eq 1 ] && [ "$background_probe_return" -ne 1 ] \
        && { [ "$current_state" != working ] || [ "$current_positive_working" -eq 0 ]; }; then
        candidate_token="transition:$transition_seq"
        candidate_reason="reconciled-transition ($old_state -> $current_state from positive $old_source evidence; source now $current_source; status event sequence $status_seq, last event: ${last_status:-none}; ${current_detail:-no detail})"
      fi
      ;;
  esac

  case "$FM_RECONCILE_WAIT_RESULT" in
    pending)
      if [ "$pending_evidence_changed" -eq 1 ] \
        || { [ "$FM_RECONCILE_WAIT_ROLE" = background-probe ] \
          && [ "$old_wait_sig" != "$FM_RECONCILE_WAIT_SIGNATURE" ] \
          && [ "$FM_RECONCILE_WAIT_EVIDENCE" != "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" ]; }; then
        candidate_token="wait:$wait_seq:changed"
        candidate_reason="external-wait-changed ($FM_RECONCILE_WAIT_DESCRIPTION; pending evidence changed from ${old_wait_evidence:-$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE} to $FM_RECONCILE_WAIT_EVIDENCE; last status event sequence $status_seq: ${last_status:-none})"
      fi
      ;;
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

  if [ -n "$probe_invalidation_reason" ] && [ "$probe_invalidation_seq" -gt "$old_probe_invalidation_seq" ]; then
    candidate_token="probe:$probe_invalidation_seq:invalidated"
    candidate_reason="background-probe-invalidated ($probe_invalidation_reason; last status event sequence $status_seq: ${last_status:-none})"
  fi

  if [ "$old_status_signal" != "$status_signal_sig" ]; then
    event_note="status event sequence $status_seq, last event: ${last_status:-none}"
  fi
  if [ "$old_turn_signal" != "$turn_signal_sig" ]; then
    event_note="${event_note:+$event_note; }turn-end signal changed"
  fi

  observation_key=$(fm_reconcile_observation_key \
    "$lifecycle_generation" "$repository_identity" "$endpoint" "$current_state" "$current_source" "$transition_seq" \
    "$FM_RECONCILE_WAIT_SIGNATURE" "$FM_RECONCILE_WAIT_RESULT" "$wait_seq" \
    "$status_signal_sig" "$turn_signal_sig" "$status_seq" ok "$old_observer_seq" \
    "$probe_invalidation_seq" "$probe_invalidation_reason")

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
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_ARMED=$probe_armed
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_WAIT_SIGNATURE=$probe_wait_sig
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_ENDPOINT=$probe_endpoint
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SEQUENCE=$probe_status_seq
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SIGNATURE=$probe_status_sig
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_STATUS_SIGNAL_SIGNATURE=$probe_status_signal
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_WAIT_EVIDENCE=$probe_wait_evidence
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_OBSERVED_AT=$probe_observed
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATION_SEQUENCE=$probe_invalidation_seq
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATION_REASON=${probe_invalidation_reason:-$old_probe_invalidation_reason}
  FM_RECONCILE_WRITE_BACKGROUND_PROBE_INVALIDATED_AT=$probe_invalidated_at
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
  if [ "$probe_consume_after_write" -eq 1 ]; then
    fm_reconcile_background_probe_consume_locked "$state" "$id" "$endpoint" || return 1
  elif [ -n "$probe_invalidation_reason" ] && [ "$probe_invalidation_seq" -gt "$old_probe_invalidation_seq" ]; then
    fm_reconcile_background_probe_pulse_load "$state" "$id"
    if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
      fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" invalidated "$probe_invalidation_reason" || return 1
    fi
  fi

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
  local old_probe_armed old_probe_invalidation_sequence probe_invalidation_sequence probe_invalidation_reason probe_invalidated_at=0
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  ! fm_reconcile_tombstone_active "$state" "$id" || return 0
  meta_signature=$(fm_reconcile_file_signature "$meta")
  lifecycle_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  [ -n "$lifecycle_generation" ] || return 0
  [ -z "$expected_generation" ] || [ "$expected_generation" = "$lifecycle_generation" ] || return 0
  fm_reconcile_reset_stale_lifecycle_locked "$state" "$id" "$lifecycle_generation" || return 1
  fm_reconcile_background_probe_recover_pulse_locked "$state" "$id" || return 1
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
  old_probe_armed=$(fm_reconcile_record_value "$record" background_probe_armed)
  old_probe_invalidation_sequence=$(fm_reconcile_record_value "$record" background_probe_invalidation_sequence)
  case "$old_sequence" in ''|*[!0-9]*) old_sequence=0 ;; esac
  case "$old_pending_version" in *[!A-Za-z0-9._:-]*) old_pending_version= ;; esac
  case "$old_notified_version" in *[!A-Za-z0-9._:-]*) old_notified_version= ;; esac
  case "$old_probe_armed" in 1) ;; *) old_probe_armed=0 ;; esac
  case "$old_probe_invalidation_sequence" in ''|*[!0-9]*) old_probe_invalidation_sequence=0 ;; esac
  evidence=$(fm_reconcile_clean_value "$evidence")
  probe_invalidation_sequence=$old_probe_invalidation_sequence
  probe_invalidation_reason=$(fm_reconcile_record_value "$record" background_probe_invalidation_reason)
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  if [ "$old_probe_armed" -eq 1 ] || [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
    probe_invalidation_sequence=$((old_probe_invalidation_sequence + 1))
    probe_invalidation_reason="observer failure while pulse was armed: $evidence"
    probe_invalidated_at=$(date +%s)
  fi
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
    -v probe_invalidation_sequence="$probe_invalidation_sequence" \
    -v probe_invalidation_reason="$probe_invalidation_reason" \
    -v probe_invalidated_at="$probe_invalidated_at" \
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
      if (probe_invalidated_at != 0) {
        updates["background_probe_armed"] = "0"
        updates["background_probe_invalidation_sequence"] = probe_invalidation_sequence
        updates["background_probe_invalidation_reason"] = probe_invalidation_reason
        updates["background_probe_invalidated_at"] = probe_invalidated_at
      }
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
      order[21] = "background_probe_armed"
      order[22] = "background_probe_invalidation_sequence"
      order[23] = "background_probe_invalidation_reason"
      order[24] = "background_probe_invalidated_at"
      for (i = 1; i <= 24; i++) {
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
  if [ "$probe_invalidated_at" -ne 0 ]; then
    fm_reconcile_background_probe_pulse_load "$state" "$id"
    if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
      fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" invalidated "$probe_invalidation_reason" || return 1
    fi
  fi
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

fm_reconcile_background_probe_invalidate_locked() {  # <state-dir> <id> <evidence>
  local state=$1 id=$2 evidence=$3 meta record meta_signature lifecycle_generation repository_identity endpoint
  local old_armed old_sequence old_pending old_pending_version old_reason old_notified old_notified_version
  local old_pending_observation pending pending_version reason pending_observation token observation_key now tmp
  meta="$state/$id.meta"
  record="$state/$id.reconciled"
  [ -f "$meta" ] && [ -f "$record" ] || return 1
  meta_signature=$(fm_reconcile_file_signature "$meta")
  lifecycle_generation=$(fm_reconcile_meta_generation "$meta" 2>/dev/null || true)
  [ -n "$lifecycle_generation" ] \
    && [ "$(fm_reconcile_record_value "$record" lifecycle_generation)" = "$lifecycle_generation" ] \
    || return 1
  old_armed=$(fm_reconcile_record_value "$record" background_probe_armed)
  old_sequence=$(fm_reconcile_record_value "$record" background_probe_invalidation_sequence)
  old_pending=$(fm_reconcile_record_value "$record" pending_action_token)
  old_pending_version=$(fm_reconcile_record_value "$record" pending_action_version)
  old_reason=$(fm_reconcile_record_value "$record" pending_action_reason)
  old_notified=$(fm_reconcile_record_value "$record" notified_action_token)
  old_notified_version=$(fm_reconcile_record_value "$record" notified_action_version)
  old_pending_observation=$(fm_reconcile_record_value "$record" pending_action_observation_key)
  case "$old_sequence" in ''|*[!0-9]*) old_sequence=0 ;; esac
  case "$old_pending_version" in *[!A-Za-z0-9._:-]*) old_pending_version= ;; esac
  case "$old_notified_version" in *[!A-Za-z0-9._:-]*) old_notified_version= ;; esac
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  if [ "$old_armed" != 1 ] && [ "$FM_RECONCILE_PROBE_PULSE_STATE" != armed ]; then
    if [ -n "$old_pending" ] \
      && { [ "$old_pending" != "$old_notified" ] || [ "$old_pending_version" != "$old_notified_version" ]; } \
      && [ -n "$old_pending_version" ]; then
      printf 'action\t%s\t%s\t%s\n' "$old_pending" "$old_pending_version" "$old_reason"
      return 0
    fi
    return 1
  fi
  evidence=$(fm_reconcile_clean_value "$evidence")
  old_sequence=$((old_sequence + 1))
  token="probe:$old_sequence:invalidated"
  repository_identity=$(fm_reconcile_record_value "$record" repository_identity)
  endpoint=$(fm_reconcile_endpoint "$meta")
  observation_key=$(fm_reconcile_observation_key \
    "$lifecycle_generation" "$repository_identity" "$endpoint" \
    "$(fm_reconcile_record_value "$record" state)" \
    "$(fm_reconcile_record_value "$record" source)" \
    "$(fm_reconcile_record_value "$record" transition_sequence)" \
    "$(fm_reconcile_record_value "$record" wait_signature)" \
    "$(fm_reconcile_record_value "$record" wait_state)" \
    "$(fm_reconcile_record_value "$record" wait_sequence)" probe-invalidated "$old_sequence" "$evidence")
  pending=$old_pending
  pending_version=$old_pending_version
  reason=$old_reason
  pending_observation=$old_pending_observation
  if [ -n "$old_pending" ] \
    && { [ "$old_pending" != "$old_notified" ] || [ "$old_pending_version" != "$old_notified_version" ]; }; then
    reason="$old_reason; newer observation before delivery: background-probe-invalidated ($evidence)"
  else
    pending=$token
    reason="background-probe-invalidated ($evidence)"
  fi
  pending_version=$(fm_task_identity_new_token) || return 1
  pending_observation=$observation_key
  now=$(date +%s)
  tmp="$record.probe.${BASHPID:-$$}"
  awk \
    -v sequence="$old_sequence" \
    -v evidence="$evidence" \
    -v now="$now" \
    -v observation_key="$observation_key" \
    -v pending="$pending" \
    -v pending_version="$pending_version" \
    -v reason="$reason" \
    -v pending_observation="$pending_observation" '
    BEGIN {
      updates["background_probe_armed"] = "0"
      updates["background_probe_invalidation_sequence"] = sequence
      updates["background_probe_invalidation_reason"] = evidence
      updates["background_probe_invalidated_at"] = now
      updates["observation_key"] = observation_key
      updates["pending_action_token"] = pending
      updates["pending_action_version"] = pending_version
      updates["pending_action_reason"] = reason
      updates["pending_action_observation_key"] = pending_observation
    }
    {
      split($0, parts, "=")
      key = parts[1]
      if (key in updates) print key "=" updates[key]
      else print
      seen[key] = 1
    }
    END {
      order[1] = "background_probe_armed"
      order[2] = "background_probe_invalidation_sequence"
      order[3] = "background_probe_invalidation_reason"
      order[4] = "background_probe_invalidated_at"
      order[5] = "observation_key"
      order[6] = "pending_action_token"
      order[7] = "pending_action_version"
      order[8] = "pending_action_reason"
      order[9] = "pending_action_observation_key"
      for (i = 1; i <= 9; i++) {
        key = order[i]
        if (!(key in seen)) print key "=" updates[key]
      }
    }
  ' "$record" > "$tmp" || { rm -f "$tmp"; return 1; }
  fm_reconcile_meta_matches "$state" "$id" "$meta_signature" "$lifecycle_generation" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$record" || return 1
  fm_reconcile_background_probe_pulse_load "$state" "$id"
  if [ "$FM_RECONCILE_PROBE_PULSE_STATE" = armed ]; then
    fm_reconcile_background_probe_pulse_set_state "$FM_RECONCILE_PROBE_PULSE_FILE" invalidated "$evidence" || return 1
  fi
  printf 'action\t%s\t%s\t%s\n' "$pending" "$pending_version" "$reason"
}

fm_reconcile_background_probe_invalidate() {  # <state-dir> <id> <evidence>
  local state=$1 id=$2 evidence=$3 invalidate_rc
  fm_reconcile_lock_acquire "$state" "$id"
  if fm_reconcile_background_probe_invalidate_locked "$state" "$id" "$evidence"; then
    invalidate_rc=0
  else
    invalidate_rc=$?
  fi
  fm_reconcile_lock_release "$state" "$id"
  return "$invalidate_rc"
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
  local claim claim_pid claim_identity current_identity rescue_pending creation_phase
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
    creation_phase=$(fm_reconcile_record_value "$claim" creation_phase)
    claim_pid=$(fm_reconcile_record_value "$claim" owner_pid)
    claim_identity=$(fm_reconcile_record_value "$claim" owner_identity)
    current_identity=$(fm_reconcile_process_identity "$claim_pid" 2>/dev/null || true)
    if [ "$rescue_pending" = 1 ] || [ -n "$creation_phase" ]; then
      if fm_reconcile_spawn_claim_recover_locked "$state" "$id" "$claim"; then
        mark_rc=0
      else
        mark_rc=4
      fi
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
    --arg predicate "$FM_RECONCILE_WAIT_PREDICATE" \
    --arg probe_initial_evidence "$FM_RECONCILE_WAIT_PROBE_INITIAL_EVIDENCE" \
    --argjson progress_grace "${FM_RECONCILE_WAIT_PROGRESS_GRACE:-0}" \
    '{registered:($registered == 1),path:$path,kind:$kind,role:$role,description:$description,target:$target,signature:$signature,registration_id:($registration_id | if . == "" then null else . end),lifecycle_generation:($lifecycle_generation | if . == "" then null else . end),owner_worktree:($owner_worktree | if . == "" then null else . end),owner_tasktmp:($owner_tasktmp | if . == "" then null else . end),predicate:($predicate | if . == "" then null else . end),probe_initial_evidence:($probe_initial_evidence | if . == "" then null else . end),progress_grace_seconds:($progress_grace | if . == 0 then null else . end)}'
}
