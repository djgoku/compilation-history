#!/usr/bin/env bash
# Send keystrokes to the --tui Emacs. Arguments are tmux key names
# ("C-c" "c" "Enter" "Space" "M-x"); use -l TEXT to type TEXT literally.
#   keys.sh C-c c c        keys.sh -l 'printf hello'        keys.sh Enter
set -euo pipefail
: "${VERIFY_ROOT:?Run launch.sh --tui and export VERIFY_ROOT first}"
[ -S "$VERIFY_ROOT/tmux.sock" ] || { printf 'No --tui session in %s\n' "$VERIFY_ROOT" >&2; exit 1; }
# tmux 3.7 rejects send-keys from every connection while a read-only client is attached.
if tmux -S "$VERIFY_ROOT/tmux.sock" list-clients -F '#{client_flags}' 2>/dev/null | grep -q read-only; then
  printf 'keys.sh: a read-only tmux client is attached, so tmux rejects keys; detach it and watch with the loop launch.sh prints\n' >&2
  exit 1
fi
if [ "${1:-}" = -l ]; then
  [ "$#" -eq 2 ] || { printf 'Usage: keys.sh -l TEXT\n' >&2; exit 2; }
  exec tmux -S "$VERIFY_ROOT/tmux.sock" send-keys -t verify -l "$2"
fi
exec tmux -S "$VERIFY_ROOT/tmux.sock" send-keys -t verify "$@"
