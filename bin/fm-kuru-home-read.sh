#!/usr/bin/env bash
# Run an observational KURU command against a disposable copy of a lived home.
#
# Firstmate must never mutate the captain's operational KURU home while reading
# it. Some KURU read surfaces can still mint local state, so this wrapper makes
# firstmate's observation side explicit: snapshot the source tree, copy it,
# execute the read command inside the copy with KURU_HOME pointed there, then
# verify the source tree's paths, content hashes, and mtimes are byte-identical.
#
# Usage:
#   fm-kuru-home-read.sh --home /Users/cal/kuru -- <command> [args...]
#
# Exit status is the command's exit status when the source home remains
# unchanged. If the source home changes during observation, this exits 4 and
# prints a bounded snapshot diff.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-kuru-home-read: %s\n' "$1" >&2
  exit "${2:-1}"
}

HOME_PATH=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || die "--home requires a path" 2
      HOME_PATH=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1" 2
      ;;
  esac
done

[ -n "$HOME_PATH" ] || die "missing --home <path>" 2
[ -d "$HOME_PATH" ] || die "home path is not a directory: $HOME_PATH" 2
[ "$#" -gt 0 ] || die "missing command after --" 2
command -v python3 >/dev/null 2>&1 || die "python3 required" 2

HOME_PATH=$(cd "$HOME_PATH" && pwd -P) || die "cannot resolve home path: $HOME_PATH"

TMP_ROOT=
# shellcheck disable=SC2329  # invoked by trap
cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-kuru-home-read.XXXXXX") || die "mktemp failed"
BEFORE="$TMP_ROOT/before.snapshot"
AFTER="$TMP_ROOT/after.snapshot"
COPY="$TMP_ROOT/home-copy"

snapshot_tree() {
  local root=$1 out=$2
  python3 - "$root" > "$out" <<'PY'
import hashlib
import json
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])

def mtime_ns(st):
    return getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000))

def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def emit(path, rel):
    st = os.lstat(path)
    mode = st.st_mode
    rec = {
        "path": rel,
        "mode": stat.S_IMODE(mode),
        "mtime_ns": mtime_ns(st),
    }
    if stat.S_ISLNK(mode):
        rec["type"] = "symlink"
        rec["target"] = os.readlink(path)
    elif stat.S_ISDIR(mode):
        rec["type"] = "dir"
    elif stat.S_ISREG(mode):
        rec["type"] = "file"
        rec["sha256"] = digest_file(path)
        rec["size"] = st.st_size
    else:
        rec["type"] = "other"
        rec["size"] = st.st_size
    print(json.dumps(rec, sort_keys=True, separators=(",", ":")))

def walk(path, rel):
    emit(path, rel)
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        return
    try:
        names = sorted(os.listdir(path))
    except PermissionError as e:
        print(f"snapshot: cannot list {path}: {e}", file=sys.stderr)
        sys.exit(1)
    for name in names:
        child = os.path.join(path, name)
        child_rel = name if rel == "." else f"{rel}/{name}"
        walk(child, child_rel)

walk(root, ".")
PY
}

snapshot_tree "$HOME_PATH" "$BEFORE"
mkdir -p "$COPY"
cp -a "$HOME_PATH/." "$COPY/"

cmd_rc=0
(
  cd "$COPY" || exit 1
  export KURU_HOME="$COPY"
  "$@"
) || cmd_rc=$?

snapshot_tree "$HOME_PATH" "$AFTER"
if ! cmp -s "$BEFORE" "$AFTER"; then
  printf 'fm-kuru-home-read: source home changed during observation: %s\n' "$HOME_PATH" >&2
  diff -u "$BEFORE" "$AFTER" 2>/dev/null | sed -n '1,80p' >&2 || true
  exit 4
fi

printf 'FM_KURU_HOME_READ_SOURCE_UNCHANGED=1\n'
printf 'FM_KURU_HOME_READ_COPY=%s\n' "$COPY"
exit "$cmd_rc"
