# Interface lifecycle

Turning the agent interface off answers every blocked `wait` with `interface_disabled` and a recovery hint, but never stops a running build or removes its history. Finished results are kept for `compilation-history-agent-retention-seconds` after completion; later waits get `wait_unavailable` and should fall back to `get`.

## Sub-features

- `disable-answers-waiters` returns `interface_disabled` with `id` and `recovery` to a blocked wait.
- `disable-keeps-build` lets the build finish and persist.
- `wait-when-disabled` refuses `wait` with `interface_disabled` while off.
- `start-when-disabled` refuses `start` and `run` with `interface_disabled` and no `id` while off.
- `reenable-forgets-jobs` answers `wait` on a job from before the disable with `wait_unavailable` and recovery after re-enabling.
- `wait-unknown` answers `wait` on an ID that was never started with `wait_unavailable` and recovery.
- `expiry` returns `wait_unavailable` after retention while `get` still works.
- `kill-reports-killed` reports `killed` with `exit_code: -1` when the running buffer is killed; this is a normal reply, so the CLI exits 0.

## How to get to it (user POV)

- The user runs `M-x compilation-history-agent-mode` in Emacs while an agent waits.
- An agent waits on an ID after its result has expired.
- The user kills a running compilation buffer.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Blocked waiter.** Save `sock=$($S/cli.sh doctor | jq -r .socket)`. Run `id=$($S/cli.sh start --directory "$VERIFY_ROOT" --command "sleep 2; printf survived" | jq -r .id)`, then `$S/capture.sh disable-wait $S/cli.sh wait "$id" &`.
- **Disable.** After a second, run `$S/observe.sh '(compilation-history-agent-mode -1)'`, then `wait`. `disable-wait.status` is `1`; `jq -e --arg id "$id" '.error == "interface_disabled" and .recovery == ("get " + $id)' "$VERIFY_EVIDENCE/disable-wait.out"` passes, and `test ! -e "$sock"` passes because disabling removes the runtime directory.
- **Build survives.** Run `sleep 3`, then `$S/capture.sh disable-get $S/cli.sh get "$id"`. `.state == "succeeded"`, `.tail` contains `survived`.
- **Wait while off.** Run `$S/capture.sh wait-off $S/cli.sh wait "$id"`. Exit 1; `.error == "interface_disabled"`. `$S/capture.sh start-off $S/cli.sh start --directory "$VERIFY_ROOT" --command true` also exits 1 with `interface_disabled` and no `id`. Then `$S/observe.sh '(compilation-history-agent-mode 1)'`.
- **Re-enabled.** Run `$S/capture.sh reenabled-wait $S/cli.sh wait "$id"`. Exit 1; `.error == "wait_unavailable"` and `.recovery == "get " + $id`, because disabling forgot every job. `$S/capture.sh wait-unknown $S/cli.sh wait 20000101T000000000000` gives the same error.
- **Expiry.** Run `$S/observe.sh '(setq compilation-history-agent-retention-seconds 1)'`, then `eid=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf kept' | jq -r .id)`, `sleep 2`, and `$S/capture.sh expired-wait $S/cli.sh wait "$eid"`. Exit 1; `.error == "wait_unavailable"`. `$S/cli.sh get "$eid"` still returns `succeeded`. Restore it with `$S/observe.sh '(setq compilation-history-agent-retention-seconds 3600)'`.
- **Kill.** Run `kid=$($S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 30' | jq -r .id)`, start `$S/capture.sh kill-wait $S/cli.sh wait "$kid" &`, then `$S/observe.sh "(let ((kill-buffer-query-functions nil)) (kill-buffer (compilation-history-agent--find-buffer \"$kid\")))"` and `wait`. `kill-wait.status` is `0`; `.state == "killed"`, `.exit_code == -1`.

## Gotchas

- Disabling, retention changes and buffer kills are user actions in Emacs with no CLI command, so they go through `observe.sh`. The proof is still the CLI's reply.
- Re-enable the interface before any later recipe; a disabled interface makes `doctor.sh` fail.
