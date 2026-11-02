# Search

In the history view, `s` prompts for a search over command, directory, git branch and output. Terms of three or more characters use SQLite FTS5 substring matching; shorter terms fall back to `LIKE`. `column:value` limits the search to one column, and an empty search clears the filter.

## Sub-features

- `search-plain` matches any indexed field, including output.
- `search-column` limits to `compile_command:`, `default_directory:`, `git_branch:` or `output:`.
- `search-short` matches a one- or two-character term.
- `search-complete` completes a partial column name.
- `search-clear` restores all records on empty input.

## How to get to it (user POV)

- Press `s` in `*Compilation History*`.

## Driving it with keys.sh

Preconditions:

- A `--tui` launch with the `alpha-marker` and `beta-marker` records from `history-view.md`, and the view open.

- **Plain.** Run `$S/keys.sh s`, `$S/keys.sh -l beta`, `$S/keys.sh Enter`, then `$S/screen.sh --wait '\(1 records\)' search-plain`. Only `beta-marker` is listed and the mode line shows `[search: beta]`.
- **Output only.** Search `output:alpha-marker`. Only the `alpha-marker` row is listed.
- **Column.** Search `compile_command:exit`. Only `beta-marker` is listed.
- **Short.** Search `compile_command:ex`. The two-character value uses the `LIKE` fallback; only `beta-marker` is listed.
- **Complete.** Press `s`, type `compile_c`, press `Tab`. The prompt reads `compile_command:`. The prompt is still open.
- **Clear.** In that open prompt, press `C-a C-k` then `Enter`. The footer returns to all records and the mode line drops `[search: …]`.

## Gotchas

- The prompt shows `Search (current: TERM):` while a filter is active; a new term replaces it.
- Keys sent while the prompt is open are typed into it. Pressing `s` again there searches for the letter `s`.
