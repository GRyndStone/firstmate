#!/usr/bin/env bash
# tests/secondmate-helpers.sh - shared fixtures and mocks for the secondmate
# suites (fm-secondmate-lifecycle-e2e and fm-secondmate-safety).
#
# These mocks encode secondmate-lifecycle behavior (fake tmux that logs window
# ops, fake treehouse that leases/returns homes, fake no-mistakes that records
# init/doctor), so they live here rather than in the generic tests/lib.sh. The
# generic git/identity/meta primitives come from lib.sh, which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake tmux (window ops are logged to FM_FAKE_TMUX_LOG, list-windows returns
# FM_FAKE_TMUX_WINDOW, capture-pane echoes FM_FAKE_TMUX_CAPTURE) plus a fake
# treehouse (durable lease of FM_FAKE_TREEHOUSE_HOME, recording the lease holder
# to FM_FAKE_TREEHOUSE_LEASE_FILE; `return` removes the target and lease unless
# FM_FAKE_TREEHOUSE_RETURN_FAIL is set). Echoes the fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state_dir=$(cd "$(dirname "$0")/.." && pwd)
state="$state_dir/tmux.state"
load_state() {
  tmux_id=
  tmux_name=
  tmux_owner=
  tmux_active=0
  [ ! -f "$state" ] || . "$state"
}
save_state() {
  {
    printf 'tmux_id=%q\n' "$tmux_id"
    printf 'tmux_name=%q\n' "$tmux_name"
    printf 'tmux_owner=%q\n' "$tmux_owner"
    printf 'tmux_active=%q\n' "$tmux_active"
  } > "$state"
}
case "${1:-}" in
  has-session|new-session|send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  new-window)
    name=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -n ]; then name=$arg; fi
      prev=$arg
    done
    tmux_id=@1
    tmux_name=$name
    tmux_owner=
    tmux_active=1
    save_state
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    printf '@1\n'
    exit 0
    ;;
  set-window-option)
    load_state
    if [ "${4:-}" = @firstmate_home ]; then
      tmux_owner=${5:-}
      save_state
    fi
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  kill-window|if-shell)
    load_state
    tmux_active=0
    save_state
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    format=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -F ]; then format=$arg; fi
      prev=$arg
    done
    if [ "$format" = '#{session_name}:#{window_name}' ] && [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    fi
    load_state
    [ "$tmux_active" = 1 ] || exit 0
    case "$format" in
      *'#{@firstmate_home}'*) printf '%s\t%s\t%s\t_\n' "$tmux_id" "$tmux_name" "$tmux_owner" ;;
      '#{window_id} #{window_name}') printf '%s %s\n' "$tmux_id" "$tmux_name" ;;
      '#{window_id}') printf '%s\n' "$tmux_id" ;;
      '#{session_name}:#{window_name}') printf 'firstmate:%s\n' "$tmux_name" ;;
      '#{window_name}') printf '%s\n' "$tmux_name" ;;
    esac
    exit 0
    ;;
  display-message)
    load_state
    case "$*" in
      *'#{window_id}'*)
        if [ "$tmux_active" != 1 ]; then
          printf "can't find window\n" >&2
          exit 1
        fi
        case "$*" in
          *'#{@firstmate_home}'*'_') printf '%s\tfirstmate\t%s\t%s\t_\n' "$tmux_id" "$tmux_name" "$tmux_owner" ;;
          *) printf '%s\tfirstmate\t%s\t%s\n' "$tmux_id" "$tmux_name" "$tmux_owner" ;;
        esac
        exit 0
        ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    if [ -n "$target" ]; then
      git -C "${FM_ROOT_OVERRIDE:-/nonexistent}" worktree remove --force "$target" 2>/dev/null \
        || rm -rf -- "$target"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal firstmate home (AGENTS.md + bin/).
mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

# A firstmate home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled secondmate charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

# Make a directory look like a genuine seeded secondmate home (for handoff tests).
seed_secondmate_home_marker() {
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# Print the exact-home tmux identity fields used by hand-authored task meta.
fm_test_tmux_meta_identity() {
  FM_HOME=$1 bash -c '. "$1/bin/fm-backend.sh"; fm_backend_home_identity' _ "$ROOT"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
