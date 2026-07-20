#!/usr/bin/env bash
# Record a PR-ready task: stores pr=<url> and GitHub's pr_head=<sha> in
# state/<id>.meta, then lifecycle-locks the watcher's merge poll registration.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-reconcile-lib.sh
. "$SCRIPT_DIR/fm-reconcile-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id '$ID'" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
LIFECYCLE_GENERATION=$(fm_reconcile_meta_generation "$META") \
  || { echo "error: cannot resolve task lifecycle generation for $ID" >&2; exit 1; }
WT=$(fm_reconcile_meta_value "$META" worktree)
PR_HEAD=
if [ -n "$WT" ] && [ -d "$WT" ]; then
  if command -v gh >/dev/null 2>&1; then
    if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
      PR_HEAD=$REMOTE_HEAD
    fi
  fi
fi

META_UPDATE_ARGS=(--set pr "$URL")
if [ -n "$PR_HEAD" ]; then
  META_UPDATE_ARGS+=(--set pr_head "$PR_HEAD")
fi
if ! fm_reconcile_meta_update "$STATE" "$ID" "$LIFECYCLE_GENERATION" "${META_UPDATE_ARGS[@]}"; then
  echo "error: task $ID lifecycle changed while recording PR metadata" >&2
  exit 1
fi
LIFECYCLE_GENERATION=$FM_RECONCILE_META_UPDATED_GENERATION
CHECK_TMP="$STATE/$ID.check.sh.tmp.${BASHPID:-$$}"
{
  printf '#!/usr/bin/env bash\n'
  # shellcheck disable=SC2016
  printf 'if ! state=$(gh pr view %q --json state -q .state 2>&1); then\n' "$URL"
  # shellcheck disable=SC2016
  printf '  printf "PR state query failed: %%s\\n" "$state" >&2\n'
  printf '  exit 2\n'
  printf 'fi\n'
  # shellcheck disable=SC2016
  printf 'case "$state" in\n'
  printf '  MERGED) printf "merged\\n"; exit 0 ;;\n'
  printf '  OPEN) exit 1 ;;\n'
  printf '  CLOSED) printf "PR closed without merge\\n" >&2; exit 2 ;;\n'
  # shellcheck disable=SC2016
  printf '  *) printf "unexpected PR state: %%s\\n" "$state" >&2; exit 2 ;;\n'
  printf 'esac\n'
} > "$CHECK_TMP"
if ! fm_reconcile_legacy_check_register "$STATE" "$ID" "$LIFECYCLE_GENERATION" "$CHECK_TMP" "PR merge poll for $URL"; then
  echo "error: task $ID lifecycle changed while arming its PR merge poll" >&2
  exit 1
fi
echo "armed: state/$ID.check.sh polls $URL"
