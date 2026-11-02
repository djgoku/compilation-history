#!/usr/bin/env bash
# Stop the server this run started and delete its scratch root. Copies the
# server log into the evidence directory first; never touches evidence.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
evidence=${VERIFY_EVIDENCE:-$repo/.verify/evidence}
: "${VERIFY_ROOT:?Set VERIFY_ROOT to the root printed by launch.sh}"
case "$VERIFY_ROOT" in /tmp/ch-verify.??????) ;; *) printf 'Refusing to clean %s\n' "$VERIFY_ROOT" >&2; exit 1 ;; esac
[ -f "$VERIFY_ROOT/owned-fixture" ] || { printf 'Refusing: %s was not created by launch.sh\n' "$VERIFY_ROOT" >&2; exit 1; }
mkdir -p "$evidence"
cp "$VERIFY_ROOT/server.log" "$evidence/server.log" 2>/dev/null || true
if [ -S "$VERIFY_ROOT/tmux.sock" ]; then
  tmux -S "$VERIFY_ROOT/tmux.sock" kill-server 2>/dev/null || true
fi
pid=$(cat "$VERIFY_ROOT/server.pid" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
fi
rm -r -- "$VERIFY_ROOT"
printf 'Cleaned %s; evidence kept in %s\n' "$VERIFY_ROOT" "$evidence"
