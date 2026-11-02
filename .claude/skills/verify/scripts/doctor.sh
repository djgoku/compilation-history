#!/usr/bin/env bash
# Read-only: is the server in $VERIFY_ROOT ours, alive, running this checkout's
# code, and using its own database?
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
: "${VERIFY_ROOT:?Run launch.sh and export VERIFY_ROOT first}"
fail() { printf 'DOCTOR FAIL: %s\n' "$1" >&2; exit 1; }
case "$VERIFY_ROOT" in /tmp/ch-verify.??????) ;; *) fail "unexpected VERIFY_ROOT $VERIFY_ROOT" ;; esac
[ -f "$VERIFY_ROOT/owned-fixture" ] || fail 'root is not owned by a verify launch'
pid=$(cat "$VERIFY_ROOT/server.pid")
kill -0 "$pid" 2>/dev/null || fail "server pid $pid is not running"
library=$("$here/observe.sh" '(file-truename (locate-library "compilation-history-agent"))' | jq -r .)
[ "$library" = "$(cd -P "$repo" && pwd)/compilation-history-agent.el" ] || fail "server loaded $library, not this checkout"
doctor=$("$here/cli.sh" doctor) || fail "cli doctor: $doctor"
printf '%s' "$doctor" | jq -e --arg root "$VERIFY_ROOT" \
  '.history_enabled and .interface_enabled and (.socket | startswith($root))
   and .database == ($root + "/history.db")' >/dev/null || fail "unexpected doctor: $doctor"
printf 'DOCTOR OK pid=%s %s\n' "$pid" "$doctor"
