#!/usr/bin/env bash
# Verify a KURU change against both the repository and the lived-home product.
#
# The KURU product the captain uses is the lived home, not only a clone of the
# repository. This command is the firstmate-owned verifier for that boundary:
# every check runs once in the repository and once against a disposable copy of
# the lived home through fm-kuru-home-read.sh. Only both surfaces passing prints
# FM_KURU_PRODUCT_CHECK_RESULT=verified.
#
# Usage:
#   fm-kuru-product-check.sh --repo <repo> --home <lived-home> [--check <sh-command>]...
#
# If no --check is supplied, the command auto-discovers the usual KURU gates
# from the repository: tests/all, bin/checks okf, and bin/checks authority.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_READ="$SCRIPT_DIR/fm-kuru-home-read.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-kuru-product-check: %s\n' "$1" >&2
  exit "${2:-1}"
}

REPO_PATH=
HOME_PATH=
CHECKS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires a path" 2
      REPO_PATH=$2
      shift 2
      ;;
    --home)
      [ "$#" -ge 2 ] || die "--home requires a path" 2
      HOME_PATH=$2
      shift 2
      ;;
    --check)
      [ "$#" -ge 2 ] || die "--check requires a shell command" 2
      CHECKS+=("$2")
      shift 2
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

[ -n "$REPO_PATH" ] || die "missing --repo <repo>" 2
[ -n "$HOME_PATH" ] || die "missing --home <lived-home>" 2
[ -d "$REPO_PATH" ] || die "repo path is not a directory: $REPO_PATH" 2
[ -d "$HOME_PATH" ] || die "home path is not a directory: $HOME_PATH" 2
[ -x "$HOME_READ" ] || die "home-read wrapper is not executable: $HOME_READ" 2

REPO_PATH=$(cd "$REPO_PATH" && pwd -P) || die "cannot resolve repo path"
HOME_PATH=$(cd "$HOME_PATH" && pwd -P) || die "cannot resolve home path"

if [ "${#CHECKS[@]}" -eq 0 ]; then
  if [ -x "$REPO_PATH/tests/all" ]; then
    CHECKS+=("./tests/all")
  elif [ -f "$REPO_PATH/tests/all" ]; then
    CHECKS+=("bash tests/all")
  fi
  if [ -x "$REPO_PATH/bin/checks" ]; then
    CHECKS+=("./bin/checks okf")
    CHECKS+=("./bin/checks authority")
  elif [ -f "$REPO_PATH/bin/checks" ]; then
    CHECKS+=("bash bin/checks okf")
    CHECKS+=("bash bin/checks authority")
  fi
fi

[ "${#CHECKS[@]}" -gt 0 ] || die "no checks supplied and no KURU gates discovered" 2

run_repo_checks() {
  local rc=0 check check_rc
  for check in "${CHECKS[@]}"; do
    printf 'check[repository]=%s\n' "$check"
    check_rc=0
    (
      cd "$REPO_PATH" || exit 1
      export KURU_HOME="$REPO_PATH"
      sh -c "$check"
    ) || check_rc=$?
    if [ "$check_rc" -ne 0 ]; then
      printf 'check_result[repository]=FAIL rc=%s command=%s\n' "$check_rc" "$check"
      rc=1
    else
      printf 'check_result[repository]=PASS command=%s\n' "$check"
    fi
  done
  return "$rc"
}

run_home_checks() {
  local rc=0 check check_rc out
  for check in "${CHECKS[@]}"; do
    printf 'check[lived-home-copy]=%s\n' "$check"
    check_rc=0
    out=$("$HOME_READ" --home "$HOME_PATH" -- sh -c "$check" 2>&1) || check_rc=$?
    printf '%s\n' "$out"
    if [ "$check_rc" -ne 0 ]; then
      printf 'check_result[lived-home-copy]=FAIL rc=%s command=%s\n' "$check_rc" "$check"
      rc=1
    else
      printf 'check_result[lived-home-copy]=PASS command=%s\n' "$check"
    fi
  done
  return "$rc"
}

printf 'FM_KURU_PRODUCT_CHECK_BEGIN=1\n'
printf 'FM_KURU_PRODUCT_CHECK_REPO=%s\n' "$REPO_PATH"
printf 'FM_KURU_PRODUCT_CHECK_HOME=%s\n' "$HOME_PATH"
printf 'FM_KURU_PRODUCT_CHECK_SURFACES=repository,lived-home-copy\n'

repo_rc=0
home_rc=0
run_repo_checks || repo_rc=$?
if [ "$repo_rc" -eq 0 ]; then
  printf 'surface=repository result=PASS\n'
else
  printf 'surface=repository result=FAIL\n'
fi

run_home_checks || home_rc=$?
if [ "$home_rc" -eq 0 ]; then
  printf 'surface=lived-home-copy result=PASS\n'
else
  printf 'surface=lived-home-copy result=FAIL\n'
fi

if [ "$repo_rc" -eq 0 ] && [ "$home_rc" -eq 0 ]; then
  printf 'FM_KURU_PRODUCT_CHECK_RESULT=verified\n'
  exit 0
fi

printf 'FM_KURU_PRODUCT_CHECK_RESULT=not-verified\n'
exit 1
