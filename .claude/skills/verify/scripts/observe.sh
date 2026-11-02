#!/usr/bin/env bash
# Evaluate one read-only Lisp FORM in the disposable server to observe state
# (buffers, windows, the history DB) that the CLI does not report.
set -euo pipefail
: "${VERIFY_ROOT:?Run launch.sh and export VERIFY_ROOT first}"
[ "$#" -eq 1 ] || { printf 'Usage: observe.sh FORM\n' >&2; exit 2; }
exec emacsclient --alternate-editor=false \
  "--socket-name=$VERIFY_ROOT/emacs-server/agent-test" --eval "$1"
