# List and search history

`list` returns saved compilations newest first, so an agent can find the ID of an earlier build without being given it. Each record is a summary: `id`, `state`, `exit_code`, `duration_seconds`, `start_time`, `command`, `directory` and `git_branch`, with no output. The reply also carries `total` (all matches, not just this page), `offset` and `search`. `--search` filters with the history view's search syntax, and `--limit` (default 20, at most 100) and `--offset` page through the results. Like `get`, it reads the database and works with the agent interface disabled.

## Sub-features

- `list-newest-first` orders records by start time, then ID, newest first, and reports each record's state.
- `list-page` honors `--limit` and `--offset` while `total` stays the full count.
- `list-search` filters by a plain term, a `column:value` term, or a term under 3 characters.
- `list-no-output` omits output from every record.
- `list-invalid` rejects an empty search, a limit outside 1 to 100, and flags from other commands.
- `list-interface-off` works while the interface is disabled.

## How to get to it (user POV)

- `compilation-history-agent list [--search TEXT] [--limit N] [--offset N]`, usually followed by `get ID` on a record it picked.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Records.** Run `a=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'echo LIST-A' | jq -r .id)`, then `b=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'echo LIST-B; exit 4' | jq -r .id)`.
- **Newest first.** Run `$S/capture.sh list-all $S/cli.sh list`. `.total == 2`, `[.records[].id] == [$b, $a]`, `[.records[].state] == ["failed", "succeeded"]`, `.search == null`.
- **No output.** Run `jq -e '[.records[] | has("tail") or has("output")] | any | not' "$VERIFY_EVIDENCE/list-all.out"`.
- **Page.** Run `$S/capture.sh list-page $S/cli.sh list --limit 1 --offset 1`. `.total == 2`, `.offset == 1`, and the only record is `$a`.
- **Search.** Run `$S/capture.sh list-search $S/cli.sh list --search 'compile_command:LIST-B'`. `.total == 1` and the record is `$b`. Then `$S/capture.sh list-short $S/cli.sh list --search 'B;'`, which takes the under-3-character path and also returns only `$b`.
- **Invalid.** Run `$S/capture.sh list-bad-limit $S/cli.sh list --limit 101` `$S/capture.sh list-bad-flag $S/cli.sh list --full` and `$S/capture.sh list-empty $S/cli.sh list --search ''`. Each exits 1 with `.error == "invalid_request"`.
- **Interface off.** Run `$S/observe.sh '(compilation-history-agent-mode -1)'`, then `$S/capture.sh list-off $S/cli.sh list`. Exit 0 with `.total == 2`. Restore with `$S/observe.sh '(compilation-history-agent-mode 1)'`.

## Gotchas

- Search also matches output text, as the view's search does, though records never include output.
- `start_time` is in the recording machine's local time with a one-second resolution. Records started in the same second are ordered by ID.
- `--limit 0` passes the CLI's integer check and is rejected by the server, so its message names the range.
