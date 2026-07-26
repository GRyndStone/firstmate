#!/usr/bin/env bash
# Resolve a project's explicit delivery mode and yolo flag from the
# data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-first|local-only and yolo is on|off.
#
# Registry line format (data/projects.md):
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Mode selection starts with the product deliverable:
#   reference repository      -> direct-PR or no-mistakes
#   running local instance    -> local-first when GitHub backs it up
#   local instance, no remote -> local-only
# Then choose assurance within the reference path:
#   direct-PR    push + PR via gh-axi, focused tests/lint, no pipeline
#   no-mistakes  full pipeline -> PR -> captain merge (explicit opt-in only)
#   local-first  firstmate fast-forwards the local product, then pushes that
#                local default branch to origin as a backup
#   local-only   local branch, no remote/PR -> firstmate review -> captain approve -> local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
#
# An unknown/missing project, missing registry, omitted mode brackets, or unknown
# mode fails closed. The operator must determine whether the deliverable is a
# reference repository or a running local instance and record the matching mode;
# no delivery mode is safe to infer from omission.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

unresolved_mode() {
  local reason=$1
  echo "error: delivery mode unresolved for $NAME: $reason" >&2
  echo "Determine the deliverable first: is this project a reference repository or a running local instance?" >&2
  echo "Record [direct-PR] or [no-mistakes] for a reference, [local-first] for a running local instance backed up to GitHub, or [local-only] for a running local instance with no remote." >&2
  exit 2
}

if [ ! -f "$REG" ]; then
  unresolved_mode "no registry at $REG"
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode=""; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  unresolved_mode "project is not in $REG"
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-first|local-only) ;;
  '') unresolved_mode "registry entry omits [mode]" ;;
  *) unresolved_mode "unknown mode \"$mode\" in $REG" ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
echo "$mode $yolo"
