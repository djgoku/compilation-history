#!/usr/bin/env bash
# Run the real agent CLI against the disposable server in $VERIFY_ROOT.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
: "${VERIFY_ROOT:?Run launch.sh and export VERIFY_ROOT first}"
exec "$repo/bin/compilation-history-agent" --server "$VERIFY_ROOT/emacs-server/agent-test" "$@"
