# Get persisted history

`get` reads a compilation's saved record: state, exit code, duration (`duration_seconds`), command, directory, buffer, and either the last 4096 characters of output or, with `--full`, all of it. It works with the agent interface disabled, so it is the recovery path after a wait error while the server is reachable. Raw non-UTF-8 output bytes come back as U+FFFD.

## Sub-features

- `get-tail` returns `tail` and `tail_truncated`.
- `get-full` returns the complete `output` and no tail.
- `get-running` reports `running` with null `exit_code` and `duration_seconds`.
- `get-unknown` returns `unknown_id` with no `recovery`.
- `get-invalid` rejects an ID that is not a history timestamp with `invalid_request`.
- `get-interface-off` works while the interface is disabled.
- `get-large` returns multi-megabyte output in about a second.

## How to get to it (user POV)

- `compilation-history-agent get ID [--full]`, often from an error's `recovery` field.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Long output.** Run `id=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'seq 1 5000' | jq -r .id)`.
- **Tail.** Run `$S/capture.sh get-tail $S/cli.sh get "$id"`. `.tail_truncated == true`, `(.tail | length) == 4096`, `.tail` contains `5000`.
- **Short.** Run `sid=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf hello' | jq -r .id)` and `$S/cli.sh get "$sid"`. `.tail_truncated == false` and `.tail` contains `hello`.
- **Full.** Run `$S/capture.sh get-full $S/cli.sh get "$id" --full`. `.output` contains `\n1\n` and `5000`; no `tail` or `output_file` key.
- **No leaked file.** Run `find "$VERIFY_ROOT" -maxdepth 1 -name 'ch-agent-output-*' | wc -l`. Prints `0`.
- **Running.** Run `rid=$($S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 3' | jq -r .id)` then `$S/capture.sh get-running $S/cli.sh get "$rid"`. `.state == "running"`, `.exit_code == null`, `.duration_seconds == null`.
- **Unknown.** Run `$S/capture.sh get-unknown $S/cli.sh get 20000101T000000000000`. Exit 1; `.error == "unknown_id"` and no `recovery` key. `$S/capture.sh get-invalid $S/cli.sh get not-an-id` exits 1 with `invalid_request`.
- **Interface off.** Run `$S/observe.sh '(compilation-history-agent-mode -1)'`, then `$S/capture.sh get-interface-off $S/cli.sh get "$id"`. Exit 0 with the same state as `get-tail`. Restore with `$S/observe.sh '(compilation-history-agent-mode 1)'`.
- **Large.** Run `big=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'head -c 4194304 /dev/zero | tr "\0" x' | jq -r .id)`, then time `$S/capture.sh get-large $S/cli.sh get "$big" --full`. `(.output | length)` is over 4194304 and the call takes about a second.

## Gotchas

- Full output is handed over in a temporary file that the CLI deletes. The fixture's temp dir is `$VERIFY_ROOT`, so a leftover `ch-agent-output-*` there is a leak.
- Persisted output can contain raw ANSI escapes and differs from the displayed buffer.
