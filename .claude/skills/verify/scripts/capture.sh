#!/usr/bin/env bash
# Run COMMAND and keep its argv, stdout, stderr and exit status as evidence in
# $VERIFY_EVIDENCE/LABEL.{cmd,out,err,status}. Exits with COMMAND's status.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
evidence=${VERIFY_EVIDENCE:-$repo/.verify/evidence}
[ "$#" -ge 2 ] || { printf 'Usage: capture.sh LABEL COMMAND [ARG...]\n' >&2; exit 2; }
label=$1; shift
mkdir -p "$evidence"
printf '%q ' "$@" > "$evidence/$label.cmd"; printf '\n' >> "$evidence/$label.cmd"
"$@" > "$evidence/$label.out" 2> "$evidence/$label.err"
status=$?
printf '%s\n' "$status" > "$evidence/$label.status"
cat "$evidence/$label.out"
exit "$status"
