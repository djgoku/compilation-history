# Run, start and wait

An agent starts a build in the user's Emacs without moving their windows, gets its history ID immediately, and later blocks until the build finishes. `run` does both in one call. The finished result has the same shape as `get`.

## Sub-features

- `start-returns-id` returns `state: running`, the ID, command, directory and buffer.
- `start-keeps-selection` leaves the selected window and buffer unchanged.
- `wait-success` returns `succeeded`, `exit_code: 0` and the output tail.
- `wait-failure` returns `failed` with the real exit code.
- `wait-repeat` returns an identical result when waited again.
- `run-combined` starts then waits, printing only the final result.
- `unicode` round-trips non-ASCII commands and output.
- `invalid-utf8` reports non-UTF-8 output bytes as U+FFFD instead of failing.

## How to get to it (user POV)

- `compilation-history-agent start --command CMD --directory DIR [--display]`, then `wait ID`.
- `compilation-history-agent run --command CMD --directory DIR [--display]`.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Selection baseline.** Run `$S/observe.sh '(buffer-name (window-buffer (selected-window)))' > "$VERIFY_EVIDENCE/selected-before"`.
- **Start.** Run `id=$($S/capture.sh start-ok $S/cli.sh start --directory "$VERIFY_ROOT" --command "sleep 1; printf 'built-λ\n'" | jq -r .id)`. Exit 0; `.state == "running"`; `.display.selected == false`.
- **Selection unchanged.** Run the selection baseline command again into `selected-after` and compare. The two files match.
- **Wait.** Run `$S/capture.sh wait-ok $S/cli.sh wait "$id"`. It blocks about a second, then exits 0 with `.state == "succeeded"`, `.exit_code == 0` and `.tail` containing `built-λ`.
- **Repeat.** Run `$S/capture.sh wait-again $S/cli.sh wait "$id"`. Output equals `wait-ok.out` except for `display`.
- **Persisted.** Run `$S/capture.sh get-after-wait $S/cli.sh get "$id"`. `.state`, `.exit_code` and `.tail` match the wait result.
- **Failure.** Run `$S/capture.sh run-fail $S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf boom; exit 7'`. Exit 0; `.state == "failed"`, `.exit_code == 7`.
- **Invalid UTF-8.** Run `$S/capture.sh run-raw $S/cli.sh run --directory "$VERIFY_ROOT" --command "printf 'raw\377byte'"`. Exit 0; `.tail` contains `raw�byte`.

## Gotchas

- CLI exit 0 with `state: failed` is correct: exit status reports the protocol, `state` reports the build.
- `wait` asks `doctor` for the socket, then blocks on one socket connection. Do not poll with `get` instead.
- The tail is the persisted output, which includes the `compilation-mode` header and footer lines.
