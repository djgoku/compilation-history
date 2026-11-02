#!/usr/bin/env bash
# Print the --tui Emacs screen as text. With LABEL, also save it as
# $VERIFY_EVIDENCE/LABEL.screen. With --wait REGEX, first poll (up to
# SECONDS, default 10) until the screen matches REGEX; exit 1 on timeout.
#   screen.sh                    screen.sh view-open
#   screen.sh --wait 'Compilation finished' compile-done 15
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
evidence=${VERIFY_EVIDENCE:-$repo/.verify/evidence}
: "${VERIFY_ROOT:?Run launch.sh --tui and export VERIFY_ROOT first}"
capture() { tmux -S "$VERIFY_ROOT/tmux.sock" capture-pane -p -t verify; }
pattern= label=
if [ "${1:-}" = --wait ]; then
  pattern=$2; label=${3:-}; deadline=$((SECONDS + ${4:-10}))
  until capture | grep -Eq -- "$pattern"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf 'Timed out waiting for /%s/; screen:\n' "$pattern" >&2
      capture >&2
      [ -z "$label" ] || { mkdir -p "$evidence"; capture > "$evidence/$label.timeout.screen"; }
      exit 1
    fi
    sleep 0.2
  done
else
  label=${1:-}
fi
if [ -n "$label" ]; then
  mkdir -p "$evidence"
  capture | tee "$evidence/$label.screen"
else
  capture
fi
