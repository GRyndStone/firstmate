#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P)
TMP_ROOT=$(TMPDIR="$TMP_BASE" fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_STAT_FOR_TEST=$(command -v stat)
export REAL_STAT_FOR_TEST

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/fm-home/data" "$fakebin"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$case_dir/fm-home/data/backlog.md"
  cat > "$case_dir/fm-home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: remove the exact worktree on success.
target=${!#}
git -C "$target" worktree remove --force "$target"
SH
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -e ] && printf '%s' "${2:-}" | grep -Fq 'rename($ARGV[0], $ARGV[1])'; then
  src=${@: -2:1}
  dst=${@: -1}
  if [ -x "$(dirname "$0")/mv" ]; then
    exec "$(dirname "$0")/mv" "$src" "$dst"
  fi
fi
exec /usr/bin/perl "$@"
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    printf "can't find window: %s\n" "${4:-unknown}" >&2
    exit 1
    ;;
  list-windows)
    case "$*" in
      *' -f '*) ;;
      *'#{session_name}:#{window_name}'*) printf '%s\n' 'firstmate:fm-other fm-other' ;;
      *) printf '%s\n' 'fm-other fm-other' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
if [ "${1:-}" = show ]; then
  if [ -n "${FM_TASKS_SHOW_READY:-}" ] && [ ! -e "${FM_TASKS_SHOW_RELEASE:-}" ]; then
    : > "$FM_TASKS_SHOW_READY"
    while [ ! -e "$FM_TASKS_SHOW_RELEASE" ]; do sleep 0.05; done
  fi
  printf '%s\n' 'code: NOT_FOUND'
  exit 1
fi
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/perl" "$fakebin/tmux" "$fakebin/tasks-axi" "$fakebin/gh-axi" "$fakebin/gh"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
if [ "${1:-}" = show ]; then
  if [ -n "${FM_TASKS_SHOW_READY:-}" ] && [ ! -e "${FM_TASKS_SHOW_RELEASE:-}" ]; then
    : > "$FM_TASKS_SHOW_READY"
    while [ ! -e "$FM_TASKS_SHOW_RELEASE" ]; do sleep 0.05; done
  fi
  if [ -n "${FM_TASKS_DONE_STATE:-}" ] && [ -e "$FM_TASKS_DONE_STATE" ]; then
    task_state=done
    held=no
    hold_reason=-
    hold_kind=-
    body=$(cat "$FM_TASKS_DONE_STATE")
  elif [ -n "${FM_TASKS_HELD_STATE:-}" ] && [ -e "$FM_TASKS_HELD_STATE" ]; then
    if [ -e "$FM_TASKS_HELD_STATE.reopened" ]; then task_state=queued; else task_state=in_flight; fi
    held=yes
    hold_reason=$(cat "$FM_TASKS_HELD_STATE")
    hold_kind=parked
    body=${FM_TASKS_SHOW_SUFFIX:-stable}
  else
    task_state=in_flight
    held=no
    hold_reason=-
    hold_kind=-
    body=${FM_TASKS_SHOW_SUFFIX:-stable}
  fi
  printf 'task:\n  id: %s\n  title: stable task\n  state: %s\n  blocked: no\n  blocked_by: none\n  held: %s\n  hold_reason: %s\n  hold_kind: %s\n  hold_until: -\n  kind: ship\n  repo: project\n  priority: -\n  created: 2026-07-17\n  closed: -\n  deps: none\n  links: none\n  body: %s\n' \
    "${2:-task-x1}" "$task_state" "$held" "$hold_reason" "$hold_kind" "$body"
  exit 0
fi
if [ "${1:-}" = done ]; then
  state=${FM_STATE_OVERRIDE:-/nonexistent}
  stage="$state/${2:-}.teardown-stage"
  note=
  previous=
  for arg in "$@"; do
    if [ "$previous" = note ]; then note=$arg; previous=; continue; fi
    [ "$arg" != --note ] || previous=note
  done
  if [ -e "$state/${2:-}.meta" ] || [ -e "$state/${2:-}.tearing-down" ]; then
    if [ ! -f "$stage" ] || ! grep -q '^version=4$' "$stage" \
       || ! grep -Eq '^done-ack=[0-9a-f]{32}$' "$stage" \
       || ! grep -q '^phase=backlog-done-started$' "$stage"; then
      echo 'tasks-axi done ran outside durable finalization' >&2
      exit 8
    fi
  fi
  if [ -n "${FM_TASKS_DONE_FAIL_FLAG:-}" ] && [ ! -e "$FM_TASKS_DONE_FAIL_FLAG" ]; then
    touch "$FM_TASKS_DONE_FAIL_FLAG"
    exit 9
  fi
  [ -z "${FM_TASKS_DONE_STATE:-}" ] || printf '%s\n' "$note" > "$FM_TASKS_DONE_STATE"
fi
if [ "${1:-}" = hold ] && [ -n "${FM_TASKS_HELD_STATE:-}" ]; then
  reason=
  previous=
  for arg in "$@"; do
    if [ "$previous" = reason ]; then reason=$arg; previous=; continue; fi
    [ "$arg" != --reason ] || previous=reason
  done
  printf '%s\n' "$reason" > "$FM_TASKS_HELD_STATE"
fi
if [ "${1:-}" = reopen ] && [ -n "${FM_TASKS_REOPEN_FAIL_FLAG:-}" ] \
   && [ ! -e "$FM_TASKS_REOPEN_FAIL_FLAG" ]; then
  touch "$FM_TASKS_REOPEN_FAIL_FLAG"
  exit 10
fi
if [ "${1:-}" = reopen ] && [ -n "${FM_TASKS_HELD_STATE:-}" ]; then
  touch "$FM_TASKS_HELD_STATE.reopened"
fi
case "${1:-}" in
  done|hold|reopen) [ -z "${FM_TASKS_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TASKS_LOG" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3 identity
  identity=$(FM_HOME="$case_dir/fm-home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=@42" \
    "tmux_home_identity=$identity" \
    "tmux_session=firstmate" \
    "tmux_window_id=@42" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

write_tmux_meta_at() {
  local meta=$1 home=$2 window_id=$3 identity
  shift 3
  identity=$(FM_HOME="$home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  fm_write_meta "$meta" \
    "window=$window_id" \
    "tmux_home_identity=$identity" \
    "tmux_session=firstmate" \
    "tmux_window_id=$window_id" \
    "$@"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  if "${REAL_GIT_FOR_TEST:?}" -C "$wt" worktree remove --force "$wt" 2>/dev/null; then
    exit 0
  fi
  /bin/rm -rf -- "$wt"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  if "${REAL_GIT_FOR_TEST:?}" -C "$wt" worktree remove --force "$wt" 2>/dev/null; then
    exit 0
  fi
  /bin/rm -rf -- "$wt"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_STAT_ERROR_PATH:?}" ]; then
    echo "stat: simulated failure" >&2
    exit 1
  fi
done
exec "${REAL_STAT_FOR_TEST:?}" "$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/fm-home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_records_tasks_axi_done_after_cleanup_when_compatible() {
  local case_dir out log
  case_dir=$(make_case tasks-axi-reminder)
  log="$case_dir/tasks.log"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"

  out=$(FM_TASKS_LOG="$log" run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  assert_contains "$(cat "$log")" 'done task-x1 --pr https://github.com/example/repo/pull/7' \
    "teardown did not record Done after cleanup"
  assert_absent "$case_dir/state/task-x1.teardown-complete" "successful backlog completion left reusable teardown proof"
  printf '%s\n' "$out" | grep -F 'recorded Done with https://github.com/example/repo/pull/7 after successful teardown' >/dev/null \
    || fail "teardown did not confirm ordered backlog completion: $out"
  printf '%s\n' "$out" | grep -F 'bin/fm-backlog.sh ready' >/dev/null \
    || fail "teardown did not name the serialized ready workflow: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown records serialized Done only after owned lifecycle cleanup"
}

test_teardown_manual_backend_uses_receipt_gated_done() {
  local case_dir out log
  case_dir=$(make_case tasks-axi-manual-optout)
  log="$case_dir/tasks.log"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"

  out=$(FM_TASKS_LOG="$log" run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  assert_contains "$(cat "$log")" 'done task-x1 --pr https://github.com/example/repo/pull/7' \
    "manual backend completion bypassed receipt-gated Done"
  printf '%s\n' "$out" | grep -F 'recorded Done' >/dev/null \
    || fail "manual backend did not confirm serialized completion: $out"
  pass "manual backend completion uses the serialized teardown receipt"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STAT_ERROR_PATH="$lock" \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
  if [ "${1:-} ${2:-}" = "pane get" ]; then
    printf '%s\n' '{"error":{"code":"pane_not_found","message":"gone"}}'
    exit 1
  elif [ "${1:-} ${2:-}" = "workspace get" ]; then
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"wG","label":"firstmate"}}}'
  elif [ "${1:-} ${2:-}" = "tab list" ]; then
    printf '%s\n' '{"result":{"tabs":[]}}'
  elif [ "${1:-} ${2:-}" = "pane list" ]; then
    printf '%s\n' '{"result":{"panes":[]}}'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

test_herdr_duplicate_endpoints_refuse_teardown_without_closure() {
  local case_dir log rc
  case_dir=$(make_case herdr-duplicate-refusal)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' 'herdr_session=default' 'herdr_workspace_id=w1' 'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  log="$case_dir/herdr.log"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get")
    printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}\n'
    ;;
  "tab list")
    printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-task-x1"},{"tab_id":"w1:t2","label":"fm-task-x1"}]}}\n'
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"

  rc=0
  FM_HERDR_LOG="$log" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "duplicate endpoint teardown"
  assert_contains "$(cat "$case_dir/stderr")" "same-home endpoint ownership anomaly" \
    "teardown did not refuse the endpoint ownership anomaly"
  assert_contains "$(cat "$case_dir/stderr")" "default:w1:p1,default:w1:p2" \
    "teardown refusal did not identify the exact duplicates"
  assert_not_contains "$(cat "$log")" "close" "duplicate refusal automatically closed an endpoint"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "duplicate refusal removed task meta"
  pass "Herdr duplicate endpoints block teardown and remain inspect-only"
}

test_endpoint_duplicate_created_after_preflight_blocks_close() {
  local case_dir log count rc
  case_dir=$(make_case herdr-duplicate-after-preflight)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' 'herdr_session=default' 'herdr_workspace_id=w1' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  log="$case_dir/herdr.log"
  count="$case_dir/tab-list-count"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}'
    ;;
  "tab list")
    current=0
    [ ! -f "${FM_HERDR_COUNT:?}" ] || current=$(cat "$FM_HERDR_COUNT")
    current=$((current + 1))
    printf '%s\n' "$current" > "$FM_HERDR_COUNT"
    if [ "$current" -eq 1 ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-task-x1"}]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-task-x1"},{"tab_id":"w1:t2","label":"fm-task-x1"}]}}'
    fi
    ;;
  "pane list")
    if [ "$(cat "${FM_HERDR_COUNT:?}")" -eq 1 ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    fi
    ;;
  "pane close") exit 0 ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"

  rc=0
  FM_HERDR_LOG="$log" FM_HERDR_COUNT="$count" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "duplicate created after teardown preflight"
  assert_contains "$(cat "$case_dir/stderr")" "immediately before close" \
    "teardown did not report its just-in-time duplicate refusal"
  assert_not_contains "$(cat "$log")" "pane close" \
    "teardown closed an endpoint after its duplicate audit became stale"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "just-in-time duplicate refusal removed lifecycle metadata"
  pass "teardown repeats duplicate auditing immediately before endpoint closure"
}

test_owned_close_refuses_duplicate_after_just_in_time_audit() {
  local case_dir log count rc
  case_dir=$(make_case herdr-duplicate-at-owned-close)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' 'herdr_session=default' 'herdr_workspace_id=w1' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  log="$case_dir/herdr.log"
  count="$case_dir/tab-list-count"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}'
    ;;
  "tab list")
    current=0
    [ ! -f "${FM_HERDR_COUNT:?}" ] || current=$(cat "$FM_HERDR_COUNT")
    current=$((current + 1))
    printf '%s\n' "$current" > "$FM_HERDR_COUNT"
    if [ "$current" -lt 5 ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-task-x1"}]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-task-x1"},{"tab_id":"w1:t2","label":"fm-task-x1"}]}}'
    fi
    ;;
  "pane list")
    if [ "$(cat "${FM_HERDR_COUNT:?}")" -lt 5 ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    fi
    ;;
  "pane close") exit 0 ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"

  rc=0
  FM_HERDR_LOG="$log" FM_HERDR_COUNT="$count" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "duplicate created at owned close"
  assert_not_contains "$(cat "$log")" "pane close" \
    "ownership-bound Herdr close ignored a new scoped duplicate"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "owned-close duplicate refusal removed lifecycle metadata"
  pass "teardown owned close rechecks scoped Herdr duplicates"
}

test_herdr_secondmate_teardown_uses_meta_home_ownership() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-secondmate-owned-close)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'backend=herdr' \
    'window=default:secondw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=secondw' \
    'herdr_pane_id=secondw:p2' \
    "worktree=$home" \
    "project=$home" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$home"
  log="$case_dir/herdr.log"
  closed="$case_dir/herdr-closed"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get")
    if [ -e "${FM_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"workspace_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"secondw","label":"2ndmate-task-x1"}}}'
    ;;
  "tab list")
    if [ -e "${FM_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"tabs":[]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"secondw:t2","label":"fm-task-x1"}]}}'
    fi
    ;;
  "pane list")
    if [ -e "${FM_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"panes":[]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"secondw:p2","tab_id":"secondw:t2"}]}}'
    fi
    ;;
  "pane close")
    : > "${FM_HERDR_CLOSED:?}"
    ;;
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1
    ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"

  rc=0
  FM_HERDR_LOG="$log" FM_HERDR_CLOSED="$closed" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "Herdr secondmate owned teardown"
  assert_contains "$(cat "$log")" 'pane close secondw:p2' \
    "Herdr secondmate teardown did not close its exact meta-owned pane"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "successful Herdr secondmate teardown retained metadata"
  [ ! -e "$home" ] || fail "successful Herdr secondmate teardown retained its home"
  pass "Herdr secondmate teardown derives every ownership probe from meta home"
}

test_secondmate_retirement_preflights_child_duplicates() {
  local case_dir home log rc
  case_dir=$(make_case secondmate-child-duplicate-refusal)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" \
    "project=$home" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$home"
  fm_write_meta "$home/state/child-a1.meta" \
    'backend=herdr' \
    'window=default:childw:p2' \
    'herdr_session=default' \
    'herdr_workspace_id=childw' \
    'herdr_pane_id=childw:p2' \
    "worktree=$case_dir/missing-child-worktree" \
    "project=$case_dir/project" \
    'kind=scout'
  log="$case_dir/herdr-child.log"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get") printf '{"result":{"workspace":{"workspace_id":"%s","label":"2ndmate-task-x1"}}}\n' "${3:-}" ;;
  "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"childw:t1","label":"fm-child-a1"},{"tab_id":"childw:t2","label":"fm-child-a1"}]}}' ;;
  "pane list") printf '%s\n' '{"result":{"panes":[{"pane_id":"childw:p1","tab_id":"childw:t1"},{"pane_id":"childw:p2","tab_id":"childw:t2"}]}}' ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"

  rc=0
  FM_HERDR_LOG="$log" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate child duplicate preflight"
  assert_contains "$(cat "$case_dir/stderr")" "child task child-a1 has a same-home endpoint ownership anomaly" \
    "forced secondmate retirement did not surface the child duplicate"
  assert_not_contains "$(cat "$log")" "close" "child duplicate preflight automatically closed an endpoint"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "child duplicate refusal removed secondmate meta"
  [ -f "$home/state/child-a1.meta" ] || fail "child duplicate refusal removed child meta"
  pass "forced secondmate retirement audits child-home duplicates before any closure"
}

test_secondmate_retirement_refuses_symlinked_child_metadata() {
  local case_dir home outside rc
  case_dir=$(make_case secondmate-child-meta-symlink-refusal)
  home="$case_dir/secondmate-home"
  outside="$case_dir/foreign-child.meta"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  printf 'window=@99\nworktree=%s\nproject=%s\nkind=ship\n' \
    "$case_dir/foreign-worktree" "$case_dir/project" > "$outside"
  ln -s "$outside" "$home/state/child-a1.meta"
  rc=0
  run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "symlinked child metadata retirement"
  assert_contains "$(cat "$case_dir/stderr")" "child task metadata is symlinked or non-regular" \
    "forced retirement parsed symlinked child metadata"
  [ -L "$home/state/child-a1.meta" ] || fail "child metadata refusal removed the symlink"
  [ -f "$outside" ] || fail "child metadata refusal removed the foreign target"
  [ -d "$home" ] || fail "child metadata refusal removed the secondmate home"
  pass "forced secondmate retirement rejects symlinked child metadata before parsing"
}

test_secondmate_retirement_refuses_unaccounted_child_authority() {
  local case_dir home rc artifact
  case_dir=$(make_case secondmate-unaccounted-child-authority)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"

  artifact="$home/state/child-a1.spawning"
  : > "$artifact"
  rc=0
  run_teardown "$case_dir" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate retirement with unaccounted spawn authority"
  assert_contains "$(cat "$case_dir/stderr")" "unaccounted child lifecycle authority" \
    "ordinary retirement erased a child spawn without metadata"
  [ -d "$home" ] || fail "ordinary retirement erased the secondmate home"

  for artifact in child-a1.spawning child-a1.teardown-stage child-a1.backlog-mutation-intent; do
    rm -f "$home/state"/* 2>/dev/null || true
    : > "$home/state/$artifact"
    rc=0
    run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "forced retirement with $artifact"
    assert_contains "$(cat "$case_dir/stderr")" "unaccounted child lifecycle authority" \
      "forced retirement erased $artifact without metadata"
    [ -e "$home/state/$artifact" ] || fail "forced retirement removed $artifact"
  done

  rm -f "$home/state"/* 2>/dev/null || true
  mkdir "$home/state/.child-a1.teardown.lock.owner.test"
  ln -s "$home/state/.child-a1.teardown.lock.owner.test" "$home/state/.child-a1.teardown.lock"
  rc=0
  run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "forced retirement with child teardown lock"
  assert_contains "$(cat "$case_dir/stderr")" "unresolved child teardown authority" \
    "forced retirement erased child teardown ownership"
  assert_present "$home/state/.child-a1.teardown.lock" "forced retirement removed the child teardown lock"
  rm -f "$home/state/.child-a1.teardown.lock"
  rmdir "$home/state/.child-a1.teardown.lock.owner.test"

  mkdir "$home/state/.backlog-mutation-owner"
  rc=0
  run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "forced retirement with backlog mutation owner"
  assert_contains "$(cat "$case_dir/stderr")" "unresolved backlog mutation authority" \
    "forced retirement erased child backlog mutation ownership"
  [ -d "$home/state/.backlog-mutation-owner" ] || fail "forced retirement removed mutation ownership"
  pass "secondmate retirement requires metadata for every child lifecycle authority"
}

test_teardown_publications_use_owned_random_temporaries() {
  local source
  source=$(cat "$TEARDOWN")
  assert_not_contains "$source" '.tmp.$$' \
    "teardown still publishes through predictable process-id temporaries"
  assert_contains "$source" 'fm_publish_file_no_follow "$tmp" "$TEARDOWN_STAGE" replace' \
    "teardown stage does not use the shared no-follow publisher"
  assert_contains "$source" 'fm_publish_file_no_follow "$tmp" "$COMPLETION_PROOF" exclusive' \
    "completion proof does not use exclusive no-follow publication"
  pass "teardown lifecycle publications use owned random no-follow temporaries"
}

test_secondmate_child_endpoint_close_requires_confirmed_absence() {
  local case_dir home log rc
  case_dir=$(make_case secondmate-child-close-noop)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  fm_write_meta "$home/state/child-a1.meta" \
    'backend=herdr' 'window=default:childw:p2' 'herdr_session=default' \
    'herdr_workspace_id=childw' 'herdr_pane_id=childw:p2' \
    "worktree=$case_dir/missing-child-worktree" "project=$case_dir/project" 'kind=scout'
  log="$case_dir/herdr-child.log"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get") printf '{"result":{"workspace":{"workspace_id":"%s","label":"2ndmate-task-x1"}}}\n' "${3:-}" ;;
  "tab list") printf '%s\n' '{"result":{"tabs":[{"tab_id":"childw:t2","label":"fm-child-a1"}]}}' ;;
  "pane list") printf '%s\n' '{"result":{"panes":[{"pane_id":"childw:p2","tab_id":"childw:t2"}]}}' ;;
  "pane get") printf '%s\n' '{"result":{"pane":{"pane_id":"childw:p2","tab_id":"childw:t2"}}}' ;;
  "pane close") exit 0 ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  rc=0
  FM_HERDR_LOG="$log" run_teardown "$case_dir" --force \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate child close no-op"
  assert_contains "$(cat "$case_dir/stderr")" 'still exists after close' \
    "forced child retirement accepted an unverified endpoint close"
  [ -f "$home/state/child-a1.meta" ] || fail "failed child close removed child metadata"
  [ -d "$home" ] || fail "failed child close removed the secondmate home"
  case_dir=$(make_case secondmate-child-missing-endpoint)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  fm_write_meta "$home/state/child-a1.meta" \
    "worktree=$case_dir/missing-child-worktree" "project=$case_dir/project" 'kind=scout'
  rc=0
  run_teardown "$case_dir" --force >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate child missing endpoint"
  assert_contains "$(cat "$case_dir/stderr")" 'kind=inventory_unavailable' \
    "forced child retirement did not fail closed when exact tmux scope was unavailable"
  [ -f "$home/state/child-a1.meta" ] || fail "missing child endpoint removed child metadata"
  pass "forced child retirement refuses missing exact endpoint scope before cleanup"
}

test_tmux_duplicate_endpoints_refuse_teardown_without_closure() {
  local case_dir log rc identity
  case_dir=$(make_case tmux-duplicate-refusal)
  write_meta "$case_dir" local-only ship
  identity=$(FM_HOME="$case_dir/fm-home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  log="$case_dir/tmux.log"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  display-message) printf '@42\tfirstmate\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}" ;;
  list-windows)
    case "$*" in
      *'#{window_id},@42}'*) ;;
      *) printf '@7\tfm-task-x1\t%s\t_\n@8\tfm-task-x1\t%s\t_\n' "${FM_TMUX_OWNER:?}" "$FM_TMUX_OWNER" ;;
    esac
    ;;
  kill-window) exit 0 ;;
  *) exit 8 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TMUX_LOG="$log" FM_TMUX_OWNER="$identity" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "tmux duplicate endpoint teardown"
  assert_contains "$(cat "$case_dir/stderr")" "same-home endpoint ownership anomaly" \
    "tmux teardown did not refuse the endpoint ownership anomaly"
  assert_contains "$(cat "$case_dir/stderr")" "@7,@8" \
    "tmux teardown refusal did not identify both exact duplicate windows"
  assert_not_contains "$(cat "$log")" "kill-window" "tmux duplicate refusal automatically closed an endpoint"
  assert_not_contains "$(cat "$log")" " -a " "tmux duplicate preflight enumerated other sessions"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "tmux duplicate refusal removed task meta"
  pass "tmux duplicate endpoints block teardown before automatic closure"
}

test_zellij_inventory_unavailable_refuses_teardown_without_sweep() {
  local case_dir log rc
  case_dir=$(make_case zellij-inventory-unavailable)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=fm:42/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=zellij' 'zellij_session=fm' 'zellij_tab_id=7' 'zellij_pane_id=42' >> "$case_dir/state/task-x1.meta"
  log="$case_dir/zellij.log"
  cat > "$case_dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ZELLIJ_LOG:?}"
exit 99
SH
  chmod +x "$case_dir/fakebin/zellij"

  rc=0
  FM_ZELLIJ_LOG="$log" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "Zellij unavailable endpoint inventory"
  assert_contains "$(cat "$case_dir/stderr")" "kind=inventory_unavailable live=unknown" \
    "Zellij teardown did not explain its fail-closed exact-home boundary"
  [ ! -s "$log" ] || fail "Zellij teardown enumerated the shared session: $(cat "$log")"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "Zellij inventory refusal removed task meta"
  pass "Zellij teardown fails closed without shared-session inventory"
}

test_cmux_duplicate_endpoints_refuse_teardown_without_closure() {
  local case_dir log rc
  case_dir=$(make_case cmux-duplicate-refusal)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=ws-a:sf-a/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=cmux' 'cmux_workspace_id=ws-a' 'cmux_surface_id=sf-a' >> "$case_dir/state/task-x1.meta"
  log="$case_dir/cmux.log"
  cat > "$case_dir/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_CMUX_LOG:?}"
exit 99
SH
  chmod +x "$case_dir/fakebin/cmux"

  rc=0
  FM_CMUX_LOG="$log" run_teardown "$case_dir" --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "cmux duplicate endpoint teardown"
  assert_contains "$(cat "$case_dir/stderr")" "kind=inventory_unavailable live=unknown" \
    "cmux teardown did not explain its fail-closed duplicate-audit boundary"
  [ ! -s "$log" ] || fail "cmux duplicate audit enumerated app-global inventory: $(cat "$log")"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "cmux duplicate refusal removed task meta"
  pass "cmux teardown fails closed without cross-home inventory enumeration"
}

test_backlog_operational_read_failure_refuses_before_teardown() {
  local case_dir rc
  case_dir=$(make_case backlog-read-failure)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.2'; exit 0 ;;
  "update --help") printf '%s\n' '--archive-body'; exit 0 ;;
  "mv --help") printf '%s\n' '[<id>...]'; exit 0 ;;
  "show task-x1") printf '%s\n' 'error: malformed backlog' 'code: VALIDATION_ERROR' >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "operational backlog read failure"
  assert_contains "$(cat "$case_dir/stderr")" "could not determine whether backlog task task-x1 exists" \
    "operational backlog failure was treated as task absence"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "backlog read failure removed lifecycle metadata"
  pass "operational backlog read failures refuse teardown while NOT_FOUND remains distinct"
}

test_non_delivery_outcomes_never_record_done() {
  local case_dir log held_state hold_line reopen_line

  case_dir=$(make_case force-truth)
  log="$case_dir/tasks.log"
  held_state="$case_dir/held-state"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "discarded work"
  add_compatible_tasks_axi "$case_dir"
  FM_TASKS_LOG="$log" FM_TASKS_HELD_STATE="$held_state" \
    run_teardown "$case_dir" --force >/dev/null || fail "forced truthful teardown failed"
  assert_contains "$(cat "$log")" "hold task-x1 --reason discarded during explicitly forced teardown" \
    "forced discard did not persist a truthful structured hold"
  assert_contains "$(cat "$log")" "reopen task-x1" "forced discard did not return the held item to Queued"
  hold_line=$(grep -n '^hold task-x1 ' "$log" | head -1 | cut -d: -f1)
  reopen_line=$(grep -n '^reopen task-x1' "$log" | head -1 | cut -d: -f1)
  [ "$hold_line" -lt "$reopen_line" ] || fail "forced discard reopened before its hold was durable"
  assert_not_contains "$(cat "$log")" "done task-x1" "forced discard was recorded Done"

  case_dir=$(make_case manual-force-truth)
  log="$case_dir/tasks.log"
  held_state="$case_dir/held-state"
  write_meta "$case_dir" local-only ship
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  wt_commit "$case_dir" "manually configured discarded work"
  add_compatible_tasks_axi "$case_dir"
  FM_TASKS_LOG="$log" FM_TASKS_HELD_STATE="$held_state" \
    run_teardown "$case_dir" --force >/dev/null \
    || fail "manual-mode forced truthful teardown failed"
  assert_contains "$(cat "$log")" "hold task-x1 --reason discarded during explicitly forced teardown" \
    "manual-mode discard did not persist through the serialized wrapper"
  assert_contains "$(cat "$log")" "reopen task-x1" \
    "manual-mode discard did not finish its truthful queued outcome"
  assert_not_contains "$(cat "$log")" "done task-x1" \
    "manual-mode discard was recorded Done"

  case_dir=$(make_case pushed-local-only-truth)
  log="$case_dir/tasks.log"
  held_state="$case_dir/held-state"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "pushed but not local main"
  add_fork_with_pushed_branch "$case_dir"
  add_compatible_tasks_axi "$case_dir"
  FM_TASKS_LOG="$log" FM_TASKS_HELD_STATE="$held_state" \
    run_teardown "$case_dir" >/dev/null || fail "remote-recoverable local-only teardown failed"
  assert_contains "$(cat "$log")" "hold task-x1 --reason teardown complete but work is recoverable only outside the delivered default branch" \
    "remote-only local work did not remain explicitly unlanded"
  assert_contains "$(cat "$log")" "reopen task-x1" "remote-only work did not return to Queued after its hold"
  hold_line=$(grep -n '^hold task-x1 ' "$log" | head -1 | cut -d: -f1)
  reopen_line=$(grep -n '^reopen task-x1' "$log" | head -1 | cut -d: -f1)
  [ "$hold_line" -lt "$reopen_line" ] || fail "remote-only work reopened before its hold was durable"
  assert_not_contains "$(cat "$log")" "done task-x1" "remote-only local work was recorded Done"

  case_dir=$(make_case unmerged-pr-truth)
  log="$case_dir/tasks.log"
  held_state="$case_dir/held-state"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "open PR work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_compatible_tasks_axi "$case_dir"
  FM_TASKS_LOG="$log" FM_TASKS_HELD_STATE="$held_state" \
    run_teardown "$case_dir" >/dev/null || fail "unmerged PR teardown failed"
  assert_contains "$(cat "$log")" "hold task-x1 --reason teardown complete but work is recoverable only outside the delivered default branch" \
    "unmerged PR did not remain explicitly unlanded"
  assert_contains "$(cat "$log")" "reopen task-x1" "unmerged PR work did not return to Queued after its hold"
  hold_line=$(grep -n '^hold task-x1 ' "$log" | head -1 | cut -d: -f1)
  reopen_line=$(grep -n '^reopen task-x1' "$log" | head -1 | cut -d: -f1)
  [ "$hold_line" -lt "$reopen_line" ] || fail "unmerged PR work reopened before its hold was durable"
  assert_not_contains "$(cat "$log")" "done task-x1" "unmerged PR was recorded Done"
  pass "discarded and unlanded teardowns remain outside Done with truthful holds"
}

test_endpoint_close_must_succeed_and_be_absent() {
  local case_dir log rc mode identity
  for mode in close-fails close-noop; do
    case_dir=$(make_case "endpoint-$mode")
    log="$case_dir/tmux.log"
    write_meta "$case_dir" local-only ship
    identity=$(FM_HOME="$case_dir/fm-home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TREEHOUSE_WT:-}" ] || rm -rf "$FM_TREEHOUSE_WT"
exit 0
SH
    cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  display-message) printf '@42\tfirstmate\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}" ;;
  list-windows)
    case "$*" in
      *'#{@firstmate_home}'$'\t_'*) printf '@42\tfm-task-x1\t%s\t_\n' "${FM_TMUX_OWNER:?}" ;;
      *' -f '*) printf '@42\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}" ;;
      *'#{session_name}:#{window_name}'*) printf '%s\n' 'firstmate:fm-task-x1 fm-task-x1' ;;
      *) printf '%s\n' 'fm-task-x1 fm-task-x1' ;;
    esac
    ;;
  list-panes) printf '%s\n' '%42' ;;
  kill-window) [ "${FM_TMUX_CLOSE_MODE:-}" = close-fails ] && exit 1; exit 0 ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"
    rc=0
    FM_TREEHOUSE_WT="$case_dir/wt" FM_TMUX_LOG="$log" FM_TMUX_CLOSE_MODE="$mode" \
      FM_TMUX_OWNER="$identity" \
      run_teardown "$case_dir" --force \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$mode endpoint close verification"
    [ -f "$case_dir/state/task-x1.meta" ] || fail "$mode removed meta after endpoint close failure"
    [ -f "$case_dir/state/task-x1.tearing-down" ] || fail "$mode removed teardown tombstone after endpoint close failure"
    [ -d "$case_dir/wt" ] || fail "$mode removed the worktree before endpoint closure was verified"
  done
  pass "endpoint close failure and success-shaped no-op both preserve lifecycle state"
}

test_unknown_endpoint_state_preserves_lifecycle() {
  local case_dir rc identity
  case_dir=$(make_case endpoint-unknown)
  write_meta "$case_dir" local-only ship
  identity=$(FM_HOME="$case_dir/fm-home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    case "$*" in
      *'#{window_id},@42'*) echo 'permission denied while reading tmux inventory' >&2; exit 2 ;;
      *'#{@firstmate_home}'$'\t_'*) printf '@42\tfm-task-x1\t%s\t_\n' "${FM_TMUX_OWNER:?}"; exit 0 ;;
      *' -f '*) printf '@42\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}"; exit 0 ;;
    esac
    echo 'permission denied while reading tmux inventory' >&2
    exit 2
    ;;
  list-panes) printf '%s\n' '%42' ;;
  list-sessions)
    echo 'permission denied while reading tmux inventory' >&2
    exit 2
    ;;
  kill-window)
    echo 'kill must not run for unknown endpoint state' >&2
    exit 99
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  FM_TMUX_OWNER="$identity" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "unknown endpoint inventory"
  assert_contains "$(cat "$case_dir/stderr")" "same-home endpoint ownership anomaly: kind=endpoint_ownership_mismatch" \
    "unreadable endpoint inventory was treated as confirmed absence"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "unknown endpoint state removed lifecycle metadata"
  [ -d "$case_dir/wt" ] || fail "unknown endpoint state removed worktree"
  assert_absent "$case_dir/state/task-x1.teardown-complete" "unknown endpoint state emitted a completion proof"
  pass "unknown recorded ownership fails closed with scoped replacements visible"
}

test_completion_proof_write_failure_preserves_lifecycle() {
  local case_dir rc proof log return_log stage marker token
  case_dir=$(make_case completion-proof-write-failure)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  proof="$case_dir/state/task-x1.teardown-complete"
  log="$case_dir/tasks.log"
  return_log="$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
target=${!#}
"${REAL_GIT_FOR_TEST:?}" -C "$target" worktree remove --force "$target"
SH
  chmod +x "$case_dir/fakebin/treehouse"
  cat > "$case_dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_PROOF_BLOCK_PATH:?}" ]; then
    exit 1
  fi
done
exec /bin/ln "$@"
SH
  cat > "$case_dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_PROOF_BLOCK_PATH:?}" ]; then
    exit 1
  fi
done
exec /usr/bin/perl "$@"
SH
  chmod +x "$case_dir/fakebin/ln" "$case_dir/fakebin/perl"

  rc=0
  FM_PROOF_BLOCK_PATH="$proof" FM_TASKS_LOG="$log" FM_TREEHOUSE_LOG="$return_log" run_teardown "$case_dir" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "completion proof persistence failure"
  assert_contains "$(cat "$case_dir/stderr")" "could not persist completion proof" \
    "proof persistence failure was not reported"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "proof persistence failure removed task meta"
  [ -d "$case_dir/wt" ] || fail "proof persistence failure removed the worktree"
  [ ! -s "$return_log" ] || fail "proof persistence failure ran destructive worktree cleanup"
  stage="$case_dir/state/task-x1.teardown-stage"
  [ -f "$stage" ] || fail "proof persistence failure removed durable retry authority"
  assert_contains "$(cat "$stage")" 'phase=prepared' \
    "proof persistence failure did not retain its prepared retry stage"
  marker=$(sed -n 's/^owner-marker=//p' "$stage")
  token=$(sed -n 's/^owner-token=//p' "$stage")
  [ -f "$marker" ] || fail "proof persistence failure removed the exact owner marker"
  assert_contains "$(cat "$marker")" "$token" \
    "proof persistence failure changed the exact owner token"
  assert_absent "$case_dir/state/task-x1.tearing-down" "proof persistence failure entered endpoint cleanup"
  if [ -f "$log" ]; then
    assert_not_contains "$(cat "$log")" "done task-x1" \
      "proof persistence failure recorded backlog completion"
  fi
  rm -f "$case_dir/fakebin/ln" "$case_dir/fakebin/perl"
  rc=0
  FM_TASKS_LOG="$log" FM_TREEHOUSE_LOG="$return_log" run_teardown "$case_dir" \
    > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "completion proof persistence retry"
  assert_contains "$(cat "$log")" "done task-x1" \
    "proof persistence retry did not complete the backlog record"
  pass "completion proof failures retain prepared retry authority before destructive cleanup"
}

test_cleanup_reuse_never_reuses_returned_worktree_path() {
  local case_dir rc log return_log
  case_dir=$(make_case cleanup-reused-path)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  log="$case_dir/tasks.log"
  return_log="$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
wt=${3:?}
rm -rf "$wt"
mkdir -p "$wt"
touch "$wt/reused-by-another-task"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_TASKS_LOG="$log" FM_TREEHOUSE_LOG="$return_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "cleanup path reuse absence verification"
  assert_contains "$(cat "$case_dir/stderr")" "not confirmed absent" \
    "cleanup path reuse was not refused before finalization"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "cleanup absence refusal removed task meta"
  [ -f "$case_dir/wt/reused-by-another-task" ] || fail "fixture did not model immediate worktree-path reuse"
  [ "$(grep -c '^return --force ' "$return_log")" = 1 ] || fail "first cleanup did not return the worktree exactly once"

  rc=0
  FM_TASKS_LOG="$log" FM_TREEHOUSE_LOG="$return_log" \
    run_teardown "$case_dir" > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "cleanup reuse retry with lost ownership"
  [ "$(grep -c '^return --force ' "$return_log")" = 1 ] \
    || fail "retry re-ran destructive cleanup against a reused worktree path"
  [ -f "$case_dir/wt/reused-by-another-task" ] || fail "retry modified the reused worktree path"
  assert_contains "$(cat "$case_dir/retry-stderr")" "teardown ownership is lost" \
    "retry did not fail closed after ownership disappeared"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" "phase=ownership-lost" \
    "retry did not persist the ownership-lost phase"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "ownership-lost retry removed lifecycle meta"
  if [ -f "$log" ]; then
    assert_not_contains "$(cat "$log")" "done task-x1" "ownership-lost retry recorded false completion"
  fi
  pass "cleanup reuse blocks finalization and preserves lost-ownership safety"
}

test_teardown_stage_does_not_dirty_retry_target() {
  local case_dir rc stage_fail status
  case_dir=$(make_case stage-outside-worktree)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] \
   && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=endpoint-closed$' "$src" 2>/dev/null; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"

  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "state-owned teardown identity interruption"
  status=$(git -C "$case_dir/wt" status --porcelain)
  [ -z "$status" ] || fail "teardown staging dirtied its own retry target: $status"
  assert_absent "$case_dir/wt/.fm-teardown-owner-task-x1" \
    "teardown staging wrote ownership authority into the worktree"

  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "state-owned teardown identity retry"
  pass "teardown retry ownership stays outside and never self-dirties the worktree"
}

test_absent_staged_target_retries_only_while_still_absent() {
  local case_dir rc stage_fail held_state mode
  for mode in absent reused registered; do
    case_dir=$(make_case "stage-absent-$mode")
    write_meta "$case_dir" local-only ship
    add_compatible_tasks_axi "$case_dir"
    if [ "$mode" = registered ]; then
      rm -rf "$case_dir/wt"
    else
      git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
    fi
    stage_fail="$case_dir/stage-failed"
    held_state="$case_dir/held-state"
    cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] \
   && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=endpoint-closed$' "$src" 2>/dev/null; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
    chmod +x "$case_dir/fakebin/mv"

    rc=0
    FM_TASKS_HELD_STATE="$held_state" \
      FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$mode absent-target staging interruption"
    assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" "owner-identity=absent" \
      "$mode fixture did not stage target absence"

    if [ "$mode" = reused ]; then
      mkdir -p "$case_dir/wt"
      printf '%s\n' 'replacement work' > "$case_dir/wt/replacement.txt"
    fi

    rc=0
    FM_TASKS_HELD_STATE="$held_state" \
      FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
      run_teardown "$case_dir" > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
    if [ "$mode" = absent ]; then
      expect_code 0 "$rc" "still-absent staged target retry"
    elif [ "$mode" = registered ]; then
      expect_code 1 "$rc" "registered absent target retry"
      assert_contains "$(cat "$case_dir/retry-stderr")" "remains registered" \
        "absent target with stale backend ownership did not fail closed"
      [ -f "$case_dir/state/task-x1.meta" ] || fail "registered absent-target retry removed lifecycle metadata"
    else
      expect_code 1 "$rc" "reused formerly absent target retry"
      assert_contains "$(cat "$case_dir/retry-stderr")" "cleanup-target identity no longer matches" \
        "formerly absent target reuse did not fail closed"
      [ -f "$case_dir/wt/replacement.txt" ] || fail "retry modified a path that appeared after absent staging"
      [ -f "$case_dir/state/task-x1.meta" ] || fail "reused absent-target retry removed lifecycle metadata"
    fi
  done
  pass "absent staged targets retry only while the recorded path remains absent"
}

test_secondmate_registry_cleanup_retries_after_home_removal() {
  local case_dir home registry fail_flag rc
  case_dir=$(make_case secondmate-registry-retry)
  home="$case_dir/secondmate-home"
  registry="$case_dir/fm-home/data/secondmates.md"
  fail_flag="$case_dir/registry-failed"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf -- '- task-x1 (home: %s; scope: test; projects: none)\n' "$home" > "$registry"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" 'kind=secondmate' \
    'mode=secondmate' "home=$home"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
dst=${2:-}
if [ "$dst" = "${FM_REGISTRY_PATH:?}" ] && [ ! -e "${FM_REGISTRY_FAIL_FLAG:?}" ]; then
  touch "$FM_REGISTRY_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"

  rc=0
  FM_REGISTRY_PATH="$registry" FM_REGISTRY_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate registry cleanup interruption"
  [ ! -e "$home" ] || fail "secondmate registry fixture did not remove its home"
  assert_contains "$(cat "$registry")" '- task-x1 ' \
    "secondmate registry fixture did not retain its interrupted entry"
  rm -f "$fail_flag"
  rc=0
  FM_REGISTRY_PATH="$registry" FM_REGISTRY_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "repeated secondmate registry cleanup interruption"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=worktree-cleanup-started' \
    "repeated registry interruption lost retry authority"
  rc=0
  FM_REGISTRY_PATH="$registry" FM_REGISTRY_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/final-retry-stderr" || rc=$?
  expect_code 0 "$rc" "secondmate registry cleanup retry"
  assert_not_contains "$(cat "$registry")" '- task-x1 ' \
    "secondmate registry retry retained the staged task entry"
  pass "secondmate registry cleanup remains retryable after home removal"
}

test_staged_retry_rechecks_dirty_and_unlanded_work() {
  local case_dir rc stage_fail return_log mode
  for mode in dirty unlanded; do
    case_dir=$(make_case "staged-recheck-$mode")
    write_meta "$case_dir" local-only ship
    add_compatible_tasks_axi "$case_dir"
    stage_fail="$case_dir/stage-failed"
    return_log="$case_dir/treehouse.log"
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
exit 0
SH
    cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] \
   && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src" 2>/dev/null; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
    chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/mv"

    rc=0
    FM_TREEHOUSE_LOG="$return_log" FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
      FM_STAGE_FAIL_FLAG="$stage_fail" run_teardown "$case_dir" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$mode staged cleanup interruption"
    assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" "phase=endpoint-closed" \
      "$mode fixture did not stop before destructive cleanup"

    if [ "$mode" = dirty ]; then
      printf '%s\n' 'new uncommitted work' > "$case_dir/wt/recovered.txt"
    else
      wt_commit_file "$case_dir" recovered.txt 'new committed work' 'recovered after interruption'
    fi

    rc=0
    FM_TREEHOUSE_LOG="$return_log" FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
      FM_STAGE_FAIL_FLAG="$stage_fail" run_teardown "$case_dir" \
      > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
    expect_code 1 "$rc" "$mode staged cleanup safety retry"
    [ ! -s "$return_log" ] || fail "$mode staged retry ran treehouse return after safety changed"
    if [ "$mode" = dirty ]; then
      assert_contains "$(cat "$case_dir/retry-stderr")" "uncommitted changes" \
        "staged retry did not recheck dirtiness"
    else
      assert_contains "$(cat "$case_dir/retry-stderr")" "not yet merged" \
        "staged retry did not recheck landing"
    fi
    [ -f "$case_dir/state/task-x1.meta" ] || fail "$mode staged retry removed lifecycle metadata"
  done
  pass "staged destructive retries recheck dirtiness and landing before cleanup"
}

test_orca_staged_cleanup_refuses_without_exact_duplicate_inventory() {
  local case_dir rc stage_fail remove_log other
  case_dir=$(make_case staged-orca-identity)
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'backend=orca' \
    'terminal=terminal-1' \
    'orca_worktree_id=orca-wt-1' \
    >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  remove_log="$case_dir/orca-remove.log"
  other="$case_dir/other-worktree"
  mkdir -p "$other"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "terminal read")
    printf '%s\n' '{"ok":false,"error":{"code":"terminal_not_found"}}'
    exit 1
    ;;
  "worktree show")
    printf '{"ok":true,"result":{"worktree":{"id":"orca-wt-1","path":"%s"}}}\n' "${FM_ORCA_PATH:?}"
    exit 0
    ;;
  "worktree rm")
    printf '%s\n' "$*" >> "${FM_ORCA_REMOVE_LOG:?}"
    printf '%s\n' '{"ok":true,"result":{}}'
    exit 0
    ;;
esac
exit 1
SH
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] \
   && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src" 2>/dev/null; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/orca" "$case_dir/fakebin/mv"

  rc=0
  FM_ORCA_PATH="$case_dir/wt" FM_ORCA_REMOVE_LOG="$remove_log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "Orca cleanup without exact duplicate inventory"

  rc=0
  FM_ORCA_PATH="$other" FM_ORCA_REMOVE_LOG="$remove_log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "Orca cleanup retry without exact duplicate inventory"
  assert_contains "$(cat "$case_dir/retry-stderr")" "kind=inventory_unavailable" \
    "Orca cleanup did not fail closed before backend worktree inspection"
  [ ! -s "$remove_log" ] || fail "Orca cleanup removed a worktree without exact duplicate inventory"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "Orca inventory refusal removed lifecycle metadata"
  pass "Orca cleanup stays blocked without exact duplicate inventory"
}

test_staged_teardown_refuses_changed_backlog_record() {
  local case_dir rc stage_fail
  case_dir=$(make_case staged-backlog-change)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] \
   && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=endpoint-closed$' "$src" 2>/dev/null; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"

  rc=0
  FM_TASKS_SHOW_SUFFIX=original FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
    FM_STAGE_FAIL_FLAG="$stage_fail" run_teardown "$case_dir" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "staged teardown interruption"
  [ -f "$case_dir/state/task-x1.teardown-stage" ] || fail "interrupted teardown lost its durable stage"

  rc=0
  FM_TASKS_SHOW_SUFFIX=recreated FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
    FM_STAGE_FAIL_FLAG="$stage_fail" run_teardown "$case_dir" \
    > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "staged teardown with changed backlog record"
  assert_contains "$(cat "$case_dir/retry-stderr")" "backlog task task-x1 changed after teardown was staged" \
    "staged retry accepted a changed backlog record"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "changed backlog retry removed lifecycle meta"
  [ -d "$case_dir/wt" ] || fail "changed backlog retry removed the worktree"
  pass "durable teardown stage is bound to the exact backlog record"
}

test_tmux_endpoint_probe_distinguishes_absent_unknown_and_mismatch() {
  local case_dir fakebin state actual identity
  case_dir="$TMP_ROOT/endpoint-state-unit"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  identity=$(FM_HOME="$case_dir" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${FM_TMUX_STATE:?}" in
  present) printf '@42\towned-session\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}"; exit 0 ;;
  absent) echo "can't find window: @42" >&2; exit 1 ;;
  mismatch-name) printf '@42\towned-session\tfm-other-task\t%s\n' "${FM_TMUX_OWNER:?}"; exit 0 ;;
  mismatch-owner) printf '@42\towned-session\tfm-task-x1\tother-home\n'; exit 0 ;;
  duplicate) printf '@42\towned-session\tfm-task-x1\t%s\n@43\towned-session\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}" "$FM_TMUX_OWNER"; exit 0 ;;
  no-server) echo 'no server running on /tmp/tmux-test/default' >&2; exit 1 ;;
  unknown) echo 'permission denied while reading tmux inventory' >&2; exit 2 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  for state in present absent mismatch-name mismatch-owner duplicate no-server unknown; do
    actual=$(PATH="$fakebin:$PATH" FM_TMUX_STATE="$state" FM_TMUX_OWNER="$identity" \
      FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1"; fm_backend_target_state tmux @42 fm-task-x1 "$2" /owned/worktree owned-session' \
        _ "$ROOT/bin/fm-backend.sh" "$identity")
    case "$state" in
      present) [ "$actual" = present ] || fail "present tmux endpoint read $actual" ;;
      absent|no-server) [ "$actual" = absent ] || fail "$state tmux endpoint read $actual" ;;
      mismatch-name|mismatch-owner|duplicate|unknown) [ "$actual" = unknown ] || fail "$state tmux endpoint read $actual" ;;
    esac
  done
  pass "tmux endpoint probe uses exact-home identity and rejects duplicates or unreadability"
}

test_orca_endpoint_probe_rejects_success_shaped_errors() {
  local case_dir fakebin state actual
  case_dir="$TMP_ROOT/orca-endpoint-state-unit"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "${FM_ORCA_STATE:?}" in
  present) printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":[]}}}'; exit 0 ;;
  absent) printf '%s\n' '{"ok":false,"error":{"code":"terminal_handle_stale"}}'; exit 0 ;;
  unknown) printf '%s\n' '{"ok":false,"error":{"code":"transport_error"}}'; exit 0 ;;
  failed) printf '%s\n' '{"ok":false,"error":{"code":"transport_error"}}'; exit 1 ;;
esac
SH
  chmod +x "$fakebin/orca"
  for state in present absent unknown failed; do
    actual=$(PATH="$fakebin:$PATH" FM_ORCA_STATE="$state" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1"; fm_backend_target_state orca terminal-42 fm-task-x1' _ "$ROOT/bin/fm-backend.sh")
    case "$state" in
      present|absent|unknown) [ "$actual" = "$state" ] || fail "$state Orca endpoint read $actual" ;;
      failed) [ "$actual" = unknown ] || fail "failed Orca endpoint read $actual" ;;
    esac
  done
  pass "Orca endpoint probe treats ok:false and CLI failures as typed absence or unknown"
}

test_zellij_endpoint_probe_refuses_shared_session_inventory() {
  local case_dir fakebin log actual
  case_dir="$TMP_ROOT/zellij-endpoint-state-unit"
  fakebin="$case_dir/fakebin"
  log="$case_dir/zellij.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ZELLIJ_LOG:?}"
exit 99
SH
  chmod +x "$fakebin/zellij"
  actual=$(PATH="$fakebin:$PATH" FM_ZELLIJ_LOG="$log" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; fm_backend_target_state zellij fm:42 fm-task-x1 7' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = unknown ] || fail "Zellij endpoint probe did not fail closed: $actual"
  [ ! -s "$log" ] || fail "Zellij endpoint probe enumerated the shared session: $(cat "$log")"
  pass "Zellij endpoint finalization fails closed without shared-session inventory"
}

test_cmux_endpoint_probe_refuses_cross_home_inventory() {
  local case_dir fakebin log actual
  case_dir="$TMP_ROOT/cmux-endpoint-state-unit"
  fakebin="$case_dir/fakebin"
  log="$case_dir/cmux.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/cmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_CMUX_LOG:?}"
case "${1:-}" in
  ping) printf 'PONG\n' ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/cmux"
  actual=$(PATH="$fakebin:$PATH" FM_CMUX_LOG="$log" FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$1"; fm_backend_target_state cmux ws-target:surface-target fm-task-x1' _ "$ROOT/bin/fm-backend.sh")
  [ "$actual" = unknown ] || fail "cmux endpoint probe did not fail closed without exact-home inventory: $actual"
  assert_contains "$(cat "$log")" "ping" "cmux endpoint probe did not check backend reachability"
  assert_not_contains "$(cat "$log")" "list-windows" "cmux endpoint probe enumerated app-global windows"
  assert_not_contains "$(cat "$log")" "workspace list" "cmux endpoint probe enumerated another home's workspace"
  pass "cmux endpoint probe fails closed without cross-home inventory"
}

test_forced_staged_retry_cannot_reuse_delivery_proof() {
  local case_dir stage_fail held_state log rc
  case_dir=$(make_case forced-staged-retry)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  stage_fail="$case_dir/stage-failed"
  held_state="$case_dir/held-state"
  log="$case_dir/tasks.log"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"

  rc=0
  FM_TASKS_HELD_STATE="$held_state" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    FM_TASKS_LOG="$log" run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "delivered staged interruption"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    FM_TASKS_LOG="$log" run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "forced staged retry"
  assert_not_contains "$(cat "$log")" 'done task-x1' "forced retry reused delivered proof"
  assert_contains "$(cat "$log")" 'hold task-x1 --reason discarded during explicitly forced teardown' \
    "forced retry did not persist discarded outcome"
  pass "forced staged retries invalidate delivery proof and remain outside Done"
}

test_task_owned_marker_rejects_recreated_worktree() {
  local case_dir stage_fail rc return_log
  case_dir=$(make_case nonrecyclable-owner-marker)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  return_log="$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
SH
  chmod +x "$case_dir/fakebin/mv" "$case_dir/fakebin/treehouse"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    FM_TREEHOUSE_LOG="$return_log" run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "owner marker staging interruption"
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git -C "$case_dir/project" worktree add -q -b fm/replacement "$case_dir/wt" main
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    FM_TREEHOUSE_LOG="$return_log" run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "recreated worktree ownership retry"
  [ ! -s "$return_log" ] || fail "recreated worktree was sent to destructive cleanup"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'cleanup-target identity no longer matches' \
    "recreated worktree did not fail its task-owned marker"
  pass "task-owned random marker rejects a replacement worktree"
}

test_absent_orca_path_requires_absent_recorded_id() {
  local case_dir other remove_log rc
  case_dir=$(make_case orca-absent-path-reused-id)
  write_meta "$case_dir" local-only ship
  printf '%s\n' 'backend=orca' 'terminal=terminal-1' 'orca_worktree_id=orca-wt-1' \
    >> "$case_dir/state/task-x1.meta"
  rm -rf "$case_dir/wt"
  other="$case_dir/other"
  mkdir -p "$other"
  remove_log="$case_dir/orca-remove.log"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'terminal read') printf '%s\n' '{"ok":false,"error":{"code":"terminal_not_found"}}'; exit 1 ;;
  'worktree show') printf '{"ok":true,"result":{"worktree":{"id":"orca-wt-1","path":"%s"}}}\n' "${FM_ORCA_OTHER:?}" ;;
  'worktree rm') printf '%s\n' "$*" >> "${FM_ORCA_REMOVE_LOG:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/orca"
  rc=0
  FM_ORCA_OTHER="$other" FM_ORCA_REMOVE_LOG="$remove_log" run_teardown "$case_dir" --force \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "absent Orca path with reused id"
  assert_contains "$(cat "$case_dir/stderr")" 'kind=inventory_unavailable' \
    "Orca teardown did not fail closed without exact-worktree terminal inventory"
  [ ! -s "$remove_log" ] || fail "reused Orca id was removed"
  pass "Orca cleanup refuses absent paths without exact duplicate inventory"
}

test_secondmate_child_absent_orca_path_requires_absent_id() {
  local case_dir home other remove_log rc
  case_dir=$(make_case child-orca-absent-path-reused-id)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" 'kind=secondmate' \
    'mode=secondmate' "home=$home"
  fm_write_meta "$home/state/child-a1.meta" \
    'backend=orca' 'window=fm-child-a1' 'terminal=terminal-child' \
    'orca_worktree_id=orca-child-1' "worktree=$case_dir/missing-child" \
    "project=$case_dir/project" 'kind=ship'
  other="$case_dir/other-child"
  mkdir -p "$other"
  remove_log="$case_dir/orca-child-remove.log"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'worktree show') printf '{"ok":true,"result":{"worktree":{"id":"orca-child-1","path":"%s"}}}\n' "${FM_ORCA_OTHER:?}" ;;
  'worktree rm') printf '%s\n' "$*" >> "${FM_ORCA_REMOVE_LOG:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/orca"
  rc=0
  FM_ORCA_OTHER="$other" FM_ORCA_REMOVE_LOG="$remove_log" run_teardown "$case_dir" --force \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "secondmate child absent Orca path with reused id"
  assert_contains "$(cat "$case_dir/stderr")" 'may have been reused' \
    "child Orca teardown did not reject the reused backend worktree id"
  [ ! -s "$remove_log" ] || fail "child reused Orca id was removed"
  [ -f "$home/state/child-a1.meta" ] || fail "child Orca mismatch removed metadata"
  pass "forced child retirement rejects reused Orca worktree identity"
}

test_teardown_state_must_be_external_to_cleanup_target() {
  local case_dir nested tasktmp rc
  case_dir=$(make_case internal-stage-state)
  nested="$case_dir/wt/state"
  mkdir -p "$nested"
  write_tmux_meta_at "$nested/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    'kind=ship' 'mode=local-only'
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/fm-home" FM_STATE_OVERRIDE="$nested" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "teardown state inside cleanup target"
  assert_contains "$(cat "$case_dir/stderr")" 'teardown state directory' \
    "internal teardown stage storage was not refused"
  [ -d "$case_dir/wt" ] || fail "internal stage refusal removed cleanup target"

  case_dir=$(make_case internal-tasktmp-state)
  tasktmp="$case_dir/tasktmp"
  nested="$tasktmp/state"
  mkdir -p "$nested"
  write_tmux_meta_at "$nested/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$case_dir/wt" "project=$case_dir/project" \
    'kind=ship' 'mode=local-only' "tasktmp=$tasktmp"
  rc=0
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/fm-home" FM_STATE_OVERRIDE="$nested" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "teardown state inside task temp root"
  assert_contains "$(cat "$case_dir/stderr")" 'task temp root' \
    "task temp root did not participate in stage-storage validation"
  [ -d "$tasktmp" ] || fail "internal stage refusal removed task temp root"
  pass "teardown stage storage is canonically external to every removal target"
}

test_confirmed_cleanup_retries_after_phase_write_failure() {
  local case_dir stage_fail rc log
  case_dir=$(make_case cleanup-confirmed-retry)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  log="$case_dir/tasks.log"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
"${REAL_GIT_FOR_TEST:?}" -C "${FM_PROJECT:?}" worktree remove --force "${3:?}"
SH
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleaned$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/mv"
  rc=0
  FM_PROJECT="$case_dir/project" FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
    FM_STAGE_FAIL_FLAG="$stage_fail" FM_TASKS_LOG="$log" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "cleanup phase write failure"
  [ ! -e "$case_dir/wt" ] || fail "cleanup fixture did not remove worktree"
  rc=0
  FM_PROJECT="$case_dir/project" FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
    FM_STAGE_FAIL_FLAG="$stage_fail" FM_TASKS_LOG="$log" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "confirmed cleanup retry"
  pass "independently confirmed cleanup remains retryable after phase interruption"
}

test_verified_owner_marker_removal_retries_after_cleanup() {
  local case_dir marker_fail rc
  case_dir=$(make_case owner-marker-removal-retry)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  marker_fail="$case_dir/marker-failed"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
target=${!#}
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
marker="$git_dir/.fm-teardown-owner-task-x1"
token=$(cat "$marker")
git -C "$target" worktree remove --force "$target"
mkdir -p "$git_dir"
printf '%s\n' "$token" > "$marker"
SH
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *'.fm-teardown-owner-task-x1'*)
    if [ ! -e "${FM_MARKER_FAIL_FLAG:?}" ]; then
      touch "$FM_MARKER_FAIL_FLAG"
      exit 1
    fi
    ;;
esac
exec /bin/rm "$@"
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/rm"

  rc=0
  FM_MARKER_FAIL_FLAG="$marker_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "owner marker removal interruption"
  [ ! -e "$case_dir/wt" ] || fail "owner marker retry fixture did not remove the worktree"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=worktree-cleanup-started' \
    "owner marker removal failure did not retain cleanup stage"
  rm -f "$marker_fail"
  rc=0
  FM_MARKER_FAIL_FLAG="$marker_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "repeated verified owner marker removal interruption"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=worktree-cleanup-started' \
    "repeated marker interruption lost retry authority"
  rc=0
  FM_MARKER_FAIL_FLAG="$marker_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/final-retry-stderr" || rc=$?
  expect_code 0 "$rc" \
    "verified owner marker removal retry: $(cat "$case_dir/final-retry-stderr")"
  assert_absent "$case_dir/state/task-x1.teardown-stage" \
    "verified marker removal retry retained teardown stage"
  pass "verified owner marker removal remains retryable after cleanup"
}

test_backlog_failure_retains_finalization_state() {
  local case_dir fail_flag log rc
  case_dir=$(make_case retained-finalization)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/done-failed"
  log="$case_dir/tasks.log"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" FM_TASKS_LOG="$log" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "serialized backlog failure"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "backlog failure removed retained meta"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=backlog-done-started' \
    "backlog failure did not retain its explicit Done subphase"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" FM_TASKS_LOG="$log" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "serialized backlog retry"
  assert_absent "$case_dir/state/task-x1.meta" "successful backlog retry retained meta"
  assert_absent "$case_dir/state/task-x1.teardown-stage" "successful backlog retry retained stage"
  pass "finalization state survives backlog failure until serialized retry succeeds"
}

test_done_record_retries_after_finalization_phase_failure() {
  local case_dir done_state stage_fail log rc
  case_dir=$(make_case done-phase-retry)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  done_state="$case_dir/done-state"
  stage_fail="$case_dir/stage-failed"
  log="$case_dir/tasks.log"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=backlog-recorded$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_TASKS_DONE_STATE="$done_state" FM_TASKS_LOG="$log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "post-Done phase interruption"
  [ -e "$done_state" ] || fail "fixture did not record Done before phase failure"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=backlog-done-started' \
    "post-Done interruption did not retain its explicit Done subphase"
  rc=0
  FM_TASKS_DONE_STATE="$done_state" FM_TASKS_LOG="$log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "truthfully Done finalization retry"
  assert_absent "$case_dir/state/task-x1.meta" "Done retry retained lifecycle meta"
  pass "truthfully Done records survive finalization phase interruption"
}

test_teardown_stage_requires_exact_schema_on_retry() {
  local case_dir fail_flag rc
  case_dir=$(make_case exact-stage-schema)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/done-failed"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "exact stage fixture"
  printf 'phase=backlog-recorded\n' >> "$case_dir/state/task-x1.teardown-stage"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "duplicate stage field retry"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'invalid or stale teardown stage' \
    "duplicate phase field bypassed exact stage validation"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "invalid stage retry removed lifecycle metadata"
  pass "every teardown retry phase requires an exact stage schema"
}

test_force_posture_cannot_change_after_backlog_recorded() {
  local case_dir log rc
  case_dir=$(make_case late-force-posture)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  log="$case_dir/tasks.log"
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_STAGE_PATH:?}" ]; then
    exit 1
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$case_dir/fakebin/rm"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_TASKS_LOG="$log" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "post-backlog lifecycle cleanup interruption"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=backlog-recorded' \
    "fixture did not retain backlog-recorded stage"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_TASKS_LOG="$log" \
    run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "late forced posture change"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'cannot change teardown force posture after cleanup completed' \
    "late forced retry did not refuse posture change"
  assert_not_contains "$(cat "$log")" 'hold task-x1' "late forced retry rewrote delivered outcome"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "late forced retry removed retained lifecycle meta"
  pass "force posture cannot change after backlog finalization"
}

test_partial_final_state_removal_retains_retry_authority() {
  local case_dir fail_flag rc
  case_dir=$(make_case partial-final-state-removal)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/meta-remove-failed"
  cat > "$case_dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_META_PATH:?}" ] && [ ! -e "${FM_REMOVE_FAIL_FLAG:?}" ]; then
    : > "$FM_REMOVE_FAIL_FLAG"
    exit 1
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$case_dir/fakebin/rm"
  rc=0
  FM_META_PATH="$case_dir/state/task-x1.meta" FM_REMOVE_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "partial final state removal"
  assert_present "$case_dir/state/task-x1.teardown-final-cleanup" \
    "partial final removal lost its retry authority"
  assert_absent "$case_dir/state/task-x1.teardown-stage" \
    "fixture did not remove the ordinary teardown stage before failing on meta"
  assert_present "$case_dir/state/task-x1.meta" \
    "fixture did not retain metadata after the selected removal failure"
  rc=0
  FM_META_PATH="$case_dir/state/task-x1.meta" FM_REMOVE_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "partial final state removal retry"
  assert_absent "$case_dir/state/task-x1.meta" "final cleanup retry retained metadata"
  assert_absent "$case_dir/state/task-x1.teardown-final-cleanup" \
    "final cleanup retry retained its consumed authority"
  pass "partial final lifecycle removal remains deterministically retryable"
}

test_partial_truthful_finalization_retries_idempotently() {
  local case_dir fail_flag held_state log rc
  case_dir=$(make_case partial-truthful-finalization)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/reopen-failed"
  held_state="$case_dir/held-state"
  log="$case_dir/tasks.log"
  rc=0
  FM_TASKS_REOPEN_FAIL_FLAG="$fail_flag" FM_TASKS_HELD_STATE="$held_state" \
    FM_TASKS_LOG="$log" run_teardown "$case_dir" --force \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "partial discarded backlog finalization"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=backlog-reopen-started' \
    "partial discarded finalization did not retain its explicit reopen subphase"
  assert_contains "$(cat "$log")" 'hold task-x1' "discarded finalization did not persist hold first"
  [ -e "$held_state" ] || fail "fixture did not expose the partial held backlog state"
  rc=0
  FM_TASKS_REOPEN_FAIL_FLAG="$fail_flag" FM_TASKS_HELD_STATE="$held_state" \
    FM_TASKS_LOG="$log" run_teardown "$case_dir" \
    >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "partial discarded finalization retry"
  assert_contains "$(cat "$log")" 'reopen task-x1' "discarded finalization retry did not finish reopen"
  assert_absent "$case_dir/state/task-x1.teardown-stage" "successful truthful retry retained stage"
  pass "partial truthful finalization retries from durable finalizing state"
}

test_interrupted_truthful_hold_binds_exact_result() {
  local case_dir held_state stage_fail log rc hold_count
  case_dir=$(make_case interrupted-truthful-hold)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  held_state="$case_dir/held-state"
  stage_fail="$case_dir/stage-failed"
  log="$case_dir/tasks.log"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=backlog-held$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_TASKS_LOG="$log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "interrupted truthful hold"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=backlog-hold-started' \
    "interrupted hold did not retain its pre-mutation phase"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_TASKS_LOG="$log" \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "exact interrupted truthful hold retry"
  hold_count=$(grep -c '^hold task-x1 ' "$log")
  [ "$hold_count" -eq 1 ] || fail "exact interrupted hold was applied more than once"

  case_dir=$(make_case mutated-truthful-hold)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  held_state="$case_dir/held-state"
  stage_fail="$case_dir/stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=backlog-held$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" \
    FM_STAGE_FAIL_FLAG="$stage_fail" run_teardown "$case_dir" --force \
    >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "mutated truthful hold fixture"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_TASKS_SHOW_SUFFIX=concurrent-change \
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "mutated interrupted truthful hold retry"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'changed during the staged hold transition' \
    "arbitrary mutation was accepted as the interrupted hold result"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "mutated interrupted hold removed lifecycle metadata"
  pass "truthful hold retries accept only their exact staged result"
}

test_postcleanup_retry_rechecks_endpoint_absence() {
  local case_dir held_state fail_flag rc identity
  case_dir=$(make_case postcleanup-endpoint-reappeared)
  write_meta "$case_dir" local-only ship
  identity=$(FM_HOME="$case_dir/fm-home" bash -c '. "$1"; fm_backend_home_identity' _ "$ROOT/bin/fm-backend.sh")
  add_compatible_tasks_axi "$case_dir"
  held_state="$case_dir/held-state"
  fail_flag="$case_dir/reopen-failed"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_TASKS_REOPEN_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "post-cleanup endpoint fixture"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    case "$*" in
      *'#{@firstmate_home}'$'\t_'*) printf '@42\tfm-task-x1\t%s\t_\n' "${FM_TMUX_OWNER:?}" ;;
      *' -f '*) printf '@42\tfm-task-x1\t%s\n' "${FM_TMUX_OWNER:?}" ;;
      *'#{session_name}:#{window_name}'*) printf '%s\n' 'firstmate:fm-task-x1 fm-task-x1' ;;
      *) printf '%s\n' 'fm-task-x1 fm-task-x1' ;;
    esac
    ;;
  list-panes) printf '%s\n' '%42' ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  FM_TASKS_HELD_STATE="$held_state" FM_TASKS_REOPEN_FAIL_FLAG="$fail_flag" \
    FM_TMUX_OWNER="$identity" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "reappeared endpoint retry"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'same-home endpoint ownership anomaly: kind=endpoint_ownership_mismatch' \
    "post-cleanup retry ignored a reappeared endpoint"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "reappeared endpoint removed lifecycle metadata"
  pass "post-cleanup phases re-confirm endpoint absence"
}

test_cleanup_success_requires_confirmed_absence() {
  local case_dir rc
  case_dir=$(make_case cleanup-noop-refusal)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "successful no-op cleanup"
  assert_contains "$(cat "$case_dir/stderr")" 'not confirmed absent' \
    "successful no-op cleanup advanced without an absence proof"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=worktree-cleanup-started' \
    "successful no-op cleanup lost its retryable phase"
  [ -d "$case_dir/wt" ] || fail "successful no-op cleanup unexpectedly removed the worktree"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "successful no-op cleanup removed lifecycle metadata"
  pass "cleanup success remains retryable until every target is absent"
}

test_tasktmp_replacement_loses_auxiliary_cleanup_authority() {
  local case_dir tasktmp stage_fail rc
  case_dir=$(make_case tasktmp-replacement-refusal)
  tasktmp="$case_dir/tasktmp"
  mkdir "$tasktmp"
  write_meta "$case_dir" local-only ship
  printf 'tasktmp=%s\n' "$tasktmp" >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  stage_fail="$case_dir/stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "tasktmp staged interruption"
  rm -rf "$tasktmp"
  mkdir "$tasktmp"
  printf 'replacement\n' > "$tasktmp/owned"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "replaced tasktmp retry"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'auxiliary cleanup target no longer has its staged ownership token' \
    "replaced tasktmp retained cleanup authority"
  assert_contains "$(cat "$tasktmp/owned")" replacement "replaced tasktmp was deleted"
  pass "tasktmp cleanup authority cannot transfer to a replacement path"
}

test_child_worktree_replacement_loses_auxiliary_cleanup_authority() {
  local case_dir home child_wt stage_fail rc
  case_dir=$(make_case child-worktree-replacement-refusal)
  home="$case_dir/secondmate-home"
  child_wt="$case_dir/child-wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  git -C "$case_dir/project" worktree add -q -b fm/child-a1 "$child_wt" main
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  write_tmux_meta_at "$home/state/child-a1.meta" "$home" @43 \
    "worktree=$child_wt" "project=$case_dir/project" \
    'kind=ship' 'mode=local-only'
  stage_fail="$case_dir/stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=worktree-cleanup-started$' "$src"; then
  touch "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "child worktree staged interruption"
  git -C "$case_dir/project" worktree remove --force "$child_wt"
  git -C "$case_dir/project" branch -D fm/child-a1 >/dev/null
  git -C "$case_dir/project" worktree add -q -b fm/child-a1-replacement "$child_wt" main
  printf 'replacement\n' > "$child_wt/replacement"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$stage_fail" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "replaced child worktree retry"
  assert_contains "$(cat "$case_dir/retry-stderr")" 'auxiliary cleanup target no longer has its staged ownership token' \
    "replaced child worktree retained cleanup authority"
  assert_contains "$(cat "$child_wt/replacement")" replacement "replaced child worktree was deleted"
  pass "child worktree cleanup authority cannot transfer to a replacement path"
}

test_interrupted_stage_preparation_is_retryable() {
  local case_dir fail_flag rc ack
  case_dir=$(make_case interrupted-stage-preparation)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/prepared-stage-failed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=prepared$' "$src"; then
  : > "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "interrupted stage preparation"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=preparing' \
    "interrupted preparation did not retain its provisional stage"
  ack=$(sed -n 's/^done-ack=//p' "$case_dir/state/task-x1.teardown-stage")
  [[ "$ack" =~ ^[0-9a-f]{32}$ ]] || fail "interrupted preparation did not persist its Done acknowledgement"
  rc=0
  FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "interrupted stage preparation retry"
  pass "interrupted stage preparation retains retryable exact authority"
}

test_orphan_auxiliary_plan_without_markers_is_recoverable() {
  local case_dir tasktmp fail_flag rc marker
  case_dir=$(make_case orphan-auxiliary-plan)
  tasktmp="$case_dir/tasktmp"
  mkdir "$tasktmp"
  write_meta "$case_dir" local-only ship
  printf 'tasktmp=%s\n' "$tasktmp" >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/aux-move-killed"
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_AUX_PATH:?}" ] && [ ! -e "${FM_AUX_FAIL_FLAG:?}" ]; then
  /bin/mv "$src" "$dst" || exit
  : > "$FM_AUX_FAIL_FLAG"
  kill -KILL "$PPID"
  exit 137
fi
exec /bin/mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_AUX_PATH="$case_dir/state/task-x1.teardown-owners" FM_AUX_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "orphan auxiliary plan fixture did not interrupt teardown"
  [ -f "$case_dir/state/task-x1.teardown-owners" ] || fail "interrupted auxiliary plan was not persisted"
  [ ! -e "$case_dir/state/task-x1.teardown-stage" ] || fail "orphan auxiliary plan fixture unexpectedly wrote a stage"
  marker=$(cut -f4 "$case_dir/state/task-x1.teardown-owners")
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || fail "orphan auxiliary plan created authority before its stage"
  rc=0
  FM_AUX_PATH="$case_dir/state/task-x1.teardown-owners" FM_AUX_FAIL_FLAG="$fail_flag" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 0 "$rc" "orphan auxiliary plan retry"
  pass "marker-free orphan auxiliary plans are deterministically recoverable"
}

test_fresh_teardown_context_is_validated_before_staging() {
  local case_dir kind mode force expected rc
  while IFS='|' read -r kind mode force expected; do
    case_dir=$(make_case "fresh-context-${kind}-${mode}-${force#--}")
    write_meta "$case_dir" "$mode" "$kind"
    rc=0
    if [ -n "$force" ]; then
      run_teardown "$case_dir" "$force" >/dev/null 2>"$case_dir/stderr" || rc=$?
    else
      run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "invalid fresh teardown context $kind/$mode/$force was accepted"
    assert_contains "$(cat "$case_dir/stderr")" "$expected" \
      "invalid fresh teardown context $kind/$mode/$force was not diagnosed"
    assert_absent "$case_dir/state/task-x1.teardown-stage" \
      "invalid fresh teardown context $kind/$mode/$force gained a teardown stage"
    assert_absent "$case_dir/state/task-x1.teardown-complete" \
      "invalid fresh teardown context $kind/$mode/$force gained a completion proof"
    [ -d "$case_dir/wt" ] || fail "invalid fresh teardown context $kind/$mode/$force removed the worktree"
    [ -f "$case_dir/state/task-x1.meta" ] || fail "invalid fresh teardown context $kind/$mode/$force removed lifecycle metadata"
  done <<'EOF'
unknown|local-only||invalid teardown metadata context
ship|unknown||invalid teardown metadata context
secondmate|local-only||invalid teardown metadata context
ship|local-only|--discard|invalid teardown force request
EOF
  case_dir=$(make_case fresh-context-extra-force-argument)
  write_meta "$case_dir" local-only ship
  rc=0
  run_teardown "$case_dir" --force extra >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "extra teardown force argument"
  assert_contains "$(cat "$case_dir/stderr")" 'only one optional --force argument' \
    "extra teardown force argument was not diagnosed"
  assert_absent "$case_dir/state/task-x1.teardown-stage" \
    "extra teardown force argument gained a teardown stage"
  [ -d "$case_dir/wt" ] || fail "extra teardown force argument removed the worktree"
  pass "fresh teardown kind, mode, and force context is validated before staging"
}

test_staged_outcome_requires_valid_context() {
  local case_dir fail_flag rc
  for outcome in invalid discarded; do
    case_dir=$(make_case "invalid-stage-outcome-$outcome")
    write_meta "$case_dir" local-only ship
    add_compatible_tasks_axi "$case_dir"
    fail_flag="$case_dir/endpoint-stage-failed"
    cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
src=${1:-}
dst=${2:-}
if [ "$dst" = "${FM_STAGE_PATH:?}" ] && [ ! -e "${FM_STAGE_FAIL_FLAG:?}" ] \
   && grep -q '^phase=endpoint-closed$' "$src"; then
  : > "$FM_STAGE_FAIL_FLAG"
  exit 1
fi
exec /bin/mv "$@"
SH
    chmod +x "$case_dir/fakebin/mv"
    rc=0
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$fail_flag" \
      run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$outcome outcome fixture"
    sed "s/^outcome=.*/outcome=$outcome/" "$case_dir/state/task-x1.teardown-stage" \
      > "$case_dir/state/task-x1.teardown-stage.next"
    /bin/mv "$case_dir/state/task-x1.teardown-stage.next" "$case_dir/state/task-x1.teardown-stage"
    rc=0
    FM_STAGE_PATH="$case_dir/state/task-x1.teardown-stage" FM_STAGE_FAIL_FLAG="$fail_flag" \
      run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
    expect_code 1 "$rc" "$outcome staged outcome"
    assert_contains "$(cat "$case_dir/retry-stderr")" 'invalid teardown outcome' \
      "$outcome staged outcome was accepted outside its kind/force context"
    [ -d "$case_dir/wt" ] || fail "$outcome staged outcome removed the worktree"
  done
  pass "staged outcomes are restricted to their kind and force posture"
}

test_plain_secondmate_home_rechecks_exact_owner_before_removal() {
  local case_dir home rc
  case_dir=$(make_case plain-secondmate-home-replacement)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
is_root=0
has_worktree=0
has_list=0
previous=
for arg in "$@"; do
  if [ "$previous" = -C ] && [ "$arg" = "${FM_REPLACE_ROOT:?}" ]; then
    is_root=1
  fi
  [ "$arg" != worktree ] || has_worktree=1
  [ "$arg" != list ] || has_list=1
  previous=$arg
done
if [ "$is_root" -eq 1 ] && [ "$has_worktree" -eq 1 ] && [ "$has_list" -eq 1 ] \
   && [ ! -e "${FM_REPLACE_FLAG:?}" ]; then
  : > "$FM_REPLACE_FLAG"
  /bin/rm -rf -- "${FM_REPLACE_HOME:?}"
  mkdir -p "$FM_REPLACE_HOME/state" "$FM_REPLACE_HOME/data" \
    "$FM_REPLACE_HOME/config" "$FM_REPLACE_HOME/projects"
  printf 'task-x1\n' > "$FM_REPLACE_HOME/.fm-secondmate-home"
  : > "$FM_REPLACE_HOME/replacement-owned"
fi
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
  rc=0
  FM_REPLACE_ROOT="$ROOT" FM_REPLACE_HOME="$home" FM_REPLACE_FLAG="$case_dir/home-replaced" \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "plain secondmate home replacement"
  [ -f "$home/replacement-owned" ] || fail "plain secondmate home cleanup removed a replacement without exact authority"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "plain secondmate home authority loss removed lifecycle metadata"
  assert_contains "$(cat "$case_dir/state/task-x1.teardown-stage")" 'phase=worktree-cleanup-started' \
    "plain secondmate home authority loss was not retained for reconciliation"
  pass "plain secondmate home removal rechecks exact staged authority"
}

test_symlinked_auxiliary_targets_are_refused() {
  local case_dir outside rc
  case_dir=$(make_case symlinked-tasktmp-refusal)
  outside="$case_dir/outside-tasktmp"
  mkdir "$outside"
  ln -s "$outside" "$case_dir/tasktmp-link"
  write_meta "$case_dir" local-only ship
  printf 'tasktmp=%s\n' "$case_dir/tasktmp-link" >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"
  rc=0
  run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "symlinked tasktmp"
  [ -d "$outside" ] || fail "symlinked tasktmp target was removed"

  case_dir=$(make_case symlinked-child-worktree-refusal)
  outside="$case_dir/child-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-a1 "$outside" main
  ln -s "$outside" "$case_dir/child-wt-link"
  mkdir -p "$case_dir/secondmate-home/state" "$case_dir/secondmate-home/data" \
    "$case_dir/secondmate-home/config" "$case_dir/secondmate-home/projects"
  printf 'task-x1\n' > "$case_dir/secondmate-home/.fm-secondmate-home"
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$case_dir/secondmate-home" \
    "project=$case_dir/secondmate-home" 'kind=secondmate' 'mode=secondmate' \
    "home=$case_dir/secondmate-home"
  write_tmux_meta_at "$case_dir/secondmate-home/state/child-a1.meta" "$case_dir/secondmate-home" @43 \
    "worktree=$case_dir/child-wt-link" \
    "project=$case_dir/project" 'kind=ship' 'mode=local-only'
  rc=0
  run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "symlinked child worktree"
  [ -d "$outside" ] || fail "symlinked child worktree target was removed"
  pass "symlinked auxiliary cleanup targets never gain teardown authority"
}

test_child_treehouse_retry_revalidates_auxiliary_authority() {
  local case_dir home child_wt attempts rc
  case_dir=$(make_case child-treehouse-retry-authority)
  home="$case_dir/secondmate-home"
  child_wt="$case_dir/child-wt"
  attempts="$case_dir/treehouse-attempts"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  git -C "$case_dir/project" worktree add -q -b fm/child-a1 "$child_wt" main
  write_tmux_meta_at "$case_dir/state/task-x1.meta" "$case_dir/fm-home" @42 \
    "worktree=$home" "project=$home" \
    'kind=secondmate' 'mode=secondmate' "home=$home"
  write_tmux_meta_at "$home/state/child-a1.meta" "$home" @43 \
    "worktree=$child_wt" "project=$case_dir/project" \
    'kind=ship' 'mode=local-only'
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
target=${!#}
attempts=${FM_TREEHOUSE_ATTEMPTS:?}
count=$(cat "$attempts" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$attempts"
if [ "$count" -eq 1 ]; then
  marker=$(printf '%s\n' "$target"/.fm-teardown-owner-task-x1-* | head -1)
  printf 'replacement\n' > "$marker"
  printf "fatal: Unable to create '%s/index.lock': File exists.\n" "$target" >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_TREEHOUSE_ATTEMPTS="$attempts" FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    run_teardown "$case_dir" --force >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "child Treehouse authority change"
  assert_contains "$(cat "$attempts")" 1 "child Treehouse return retried after authority changed"
  [ -d "$child_wt" ] || fail "child Treehouse retry removed a target after authority changed"
  pass "child Treehouse retries revalidate exact auxiliary authority"
}

test_finalizing_retry_rechecks_current_record() {
  local case_dir fail_flag rc
  case_dir=$(make_case finalizing-record-change)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  fail_flag="$case_dir/done-failed"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "initial finalizing failure"
  rc=0
  FM_TASKS_DONE_FAIL_FLAG="$fail_flag" FM_TASKS_SHOW_SUFFIX=changed \
    run_teardown "$case_dir" >/dev/null 2>"$case_dir/retry-stderr" || rc=$?
  expect_code 1 "$rc" "changed finalizing record"
  assert_contains "$(cat "$case_dir/retry-stderr")" \
    'teardown proof does not match the current backlog record' \
    "finalizing retry ignored the current backlog fingerprint"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "changed finalizing record removed lifecycle metadata"
  pass "finalizing retries remain bound to the current backlog record"
}

test_concurrent_force_retry_cannot_replace_staged_outcome() {
  local case_dir ready release log first_rc second_rc waited=0 first_pid second_pid
  case_dir=$(make_case serialized-teardown-retry)
  write_meta "$case_dir" local-only ship
  add_compatible_tasks_axi "$case_dir"
  ready="$case_dir/show-ready"
  release="$case_dir/show-release"
  log="$case_dir/tasks.log"
  FM_TASKS_SHOW_READY="$ready" FM_TASKS_SHOW_RELEASE="$release" FM_TASKS_LOG="$log" \
    run_teardown "$case_dir" >"$case_dir/first-out" 2>"$case_dir/first-err" &
  first_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "serialized teardown fixture never entered its critical section"
  FM_TASKS_LOG="$log" run_teardown "$case_dir" --force \
    >"$case_dir/second-out" 2>"$case_dir/second-err" &
  second_pid=$!
  : > "$release"
  first_rc=0
  wait "$first_pid" || first_rc=$?
  second_rc=0
  wait "$second_pid" || second_rc=$?
  expect_code 0 "$first_rc" "first serialized teardown"
  expect_code 1 "$second_rc" "concurrent forced retry"
  assert_not_contains "$(cat "$log")" 'hold task-x1' \
    "concurrent forced retry replaced a delivered outcome"
  assert_contains "$(cat "$log")" 'done task-x1' \
    "serialized teardown did not finish its original delivered outcome"
  pass "concurrent forced retries cannot replace an in-memory staged outcome"
}

test_effective_state_is_validated_before_teardown_lock_mutation() {
  local case_dir outside out status
  case_dir=$(make_case prelock-state-scope)
  outside="$case_dir/foreign-state"
  mkdir -p "$outside"
  rm -rf "$case_dir/state"
  ln -s "$outside" "$case_dir/state"
  status=0
  out=$(run_teardown "$case_dir" 2>&1) || status=$?
  expect_code 1 "$status" "symlinked teardown state before lock acquisition"
  assert_contains "$out" "symlinked effective state path component" \
    "teardown did not reject foreign state before acquiring its lock"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "teardown mutated foreign state before path validation: $(find "$outside" -mindepth 1 -maxdepth 2 -print)"
  pass "teardown validates effective state before every lock, read, and mutation"
}

test_treehouse_available_release_is_exact_project_and_path() {
  local case_dir project target other replacement alias_target fakebin
  case_dir="$TMP_ROOT/treehouse-available-release"
  project="$case_dir/project"
  target="$case_dir/target"
  other="$case_dir/other"
  replacement="$case_dir/replacement"
  fakebin="$case_dir/fakebin"
  mkdir -p "$project" "$target" "$other" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "$PWD" = "${FM_EXPECTED_PROJECT:?}" ] || exit 1
[ "${1:-}" = status ] || exit 1
printf '1     available    %s\n' "${FM_AVAILABLE_PATH:?}"
SH
  chmod +x "$fakebin/treehouse"
  PATH="$fakebin:$PATH" FM_EXPECTED_PROJECT="$project" FM_AVAILABLE_PATH="$target" \
    bash -c '. "$1"; fm_treehouse_worktree_available_for_project "$2" "$3"' \
      _ "$ROOT/bin/fm-treehouse-lib.sh" "$project" "$target" \
    || fail "exact Treehouse available release was not accepted"
  if PATH="$fakebin:$PATH" FM_EXPECTED_PROJECT="$project" FM_AVAILABLE_PATH="$other" \
    bash -c '. "$1"; fm_treehouse_worktree_available_for_project "$2" "$3"' \
      _ "$ROOT/bin/fm-treehouse-lib.sh" "$project" "$target"; then
    fail "a different available Treehouse path satisfied exact release proof"
  fi
  if PATH="$fakebin:$PATH" FM_EXPECTED_PROJECT="$other" FM_AVAILABLE_PATH="$target" \
    bash -c '. "$1"; fm_treehouse_worktree_available_for_project "$2" "$3"' \
      _ "$ROOT/bin/fm-treehouse-lib.sh" "$project" "$target"; then
    fail "Treehouse status from a different project satisfied exact release proof"
  fi
  ln -s "$target" "$replacement"
  if PATH="$fakebin:$PATH" FM_EXPECTED_PROJECT="$project" FM_AVAILABLE_PATH="$target" \
    bash -c '. "$1"; fm_treehouse_worktree_available_for_project "$2" "$3"' \
      _ "$ROOT/bin/fm-treehouse-lib.sh" "$project" "$replacement"; then
    fail "a replacement symlink satisfied exact Treehouse available-release proof"
  fi
  case "$target" in
    /private/var/*)
      if [ "$(cd /var 2>/dev/null && pwd -P)" = /private/var ]; then
        alias_target=${target#/private}
        PATH="$fakebin:$PATH" FM_EXPECTED_PROJECT="$project" FM_AVAILABLE_PATH="$target" \
          bash -c '. "$1"; fm_treehouse_worktree_available_for_project "$2" "$3"' \
            _ "$ROOT/bin/fm-treehouse-lib.sh" "$project" "$alias_target" \
          || fail "verified macOS /var alias did not preserve exact Treehouse release proof"
      fi
      ;;
  esac
  pass "Treehouse release proof binds exact paths, rejects symlinks, and preserves system aliases"
}

test_local_only_fork_remote_allows
test_teardown_records_tasks_axi_done_after_cleanup_when_compatible
test_teardown_manual_backend_uses_receipt_gated_done
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_herdr_teardown_clears_escalation_marker
test_herdr_duplicate_endpoints_refuse_teardown_without_closure
test_endpoint_duplicate_created_after_preflight_blocks_close
test_owned_close_refuses_duplicate_after_just_in_time_audit
test_herdr_secondmate_teardown_uses_meta_home_ownership
test_secondmate_retirement_preflights_child_duplicates
test_secondmate_retirement_refuses_symlinked_child_metadata
test_secondmate_retirement_refuses_unaccounted_child_authority
test_teardown_publications_use_owned_random_temporaries
test_secondmate_child_endpoint_close_requires_confirmed_absence
test_tmux_duplicate_endpoints_refuse_teardown_without_closure
test_zellij_inventory_unavailable_refuses_teardown_without_sweep
test_cmux_duplicate_endpoints_refuse_teardown_without_closure
test_backlog_operational_read_failure_refuses_before_teardown
test_non_delivery_outcomes_never_record_done
test_endpoint_close_must_succeed_and_be_absent
test_unknown_endpoint_state_preserves_lifecycle
test_completion_proof_write_failure_preserves_lifecycle
test_cleanup_reuse_never_reuses_returned_worktree_path
test_teardown_stage_does_not_dirty_retry_target
test_absent_staged_target_retries_only_while_still_absent
test_secondmate_registry_cleanup_retries_after_home_removal
test_staged_retry_rechecks_dirty_and_unlanded_work
test_orca_staged_cleanup_refuses_without_exact_duplicate_inventory
test_staged_teardown_refuses_changed_backlog_record
test_tmux_endpoint_probe_distinguishes_absent_unknown_and_mismatch
test_orca_endpoint_probe_rejects_success_shaped_errors
test_zellij_endpoint_probe_refuses_shared_session_inventory
test_cmux_endpoint_probe_refuses_cross_home_inventory
test_forced_staged_retry_cannot_reuse_delivery_proof
test_task_owned_marker_rejects_recreated_worktree
test_absent_orca_path_requires_absent_recorded_id
test_secondmate_child_absent_orca_path_requires_absent_id
test_teardown_state_must_be_external_to_cleanup_target
test_confirmed_cleanup_retries_after_phase_write_failure
test_verified_owner_marker_removal_retries_after_cleanup
test_backlog_failure_retains_finalization_state
test_done_record_retries_after_finalization_phase_failure
test_teardown_stage_requires_exact_schema_on_retry
test_force_posture_cannot_change_after_backlog_recorded
test_partial_final_state_removal_retains_retry_authority
test_partial_truthful_finalization_retries_idempotently
test_interrupted_truthful_hold_binds_exact_result
test_postcleanup_retry_rechecks_endpoint_absence
test_cleanup_success_requires_confirmed_absence
test_tasktmp_replacement_loses_auxiliary_cleanup_authority
test_child_worktree_replacement_loses_auxiliary_cleanup_authority
test_interrupted_stage_preparation_is_retryable
test_orphan_auxiliary_plan_without_markers_is_recoverable
test_fresh_teardown_context_is_validated_before_staging
test_staged_outcome_requires_valid_context
test_plain_secondmate_home_rechecks_exact_owner_before_removal
test_symlinked_auxiliary_targets_are_refused
test_child_treehouse_retry_revalidates_auxiliary_authority
test_finalizing_retry_rechecks_current_record
test_concurrent_force_retry_cannot_replace_staged_outcome
test_effective_state_is_validated_before_teardown_lock_mutation
test_treehouse_available_release_is_exact_project_and_path
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
