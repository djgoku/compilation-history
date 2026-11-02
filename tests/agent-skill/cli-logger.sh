#!/bin/bash
# Installed as `compilation-history-agent` on the evaluated agent's PATH.
# Appends a begin and an end line per call to $CH_EVAL_CALL_LOG, then runs the
# real CLI with unchanged arguments, output and exit status.
set -u
jq -cn --args '{phase:"begin", argv:$ARGS.positional}' -- "$@" >> "$CH_EVAL_CALL_LOG"
"$CH_EVAL_REAL_CLI" "$@"
status=$?
jq -cn --argjson status "$status" --args '{phase:"end", status:$status, argv:$ARGS.positional}' -- "$@" >> "$CH_EVAL_CALL_LOG"
exit "$status"
