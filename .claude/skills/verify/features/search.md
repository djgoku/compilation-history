# Search

In the history view, `s` prompts for a search over command, directory, git branch and output. Terms of three or more characters use SQLite FTS5 substring matching. Shorter terms, and terms FTS5 rejects, fall back to `LIKE`. `column:value` limits the search to one column. `state:VALUE` filters by state (`running`, `success`, `failure` or `killed`), alone or with text. An empty search clears the filter.

## Sub-features

- `search-plain` matches any indexed field, including output.
- `search-column` limits to `compile_command:`, `default_directory:`, `git_branch:` or `output:`.
- `search-short` matches a one- or two-character term.
- `search-state` filters with `state:VALUE`. An unknown value shows `Unknown state` and keeps the current search.
- `search-complete` completes column names and, after `state:`, state names.
- `search-clear` restores all records on empty input.

## How to get to it (user POV)

- Press `s` in `*Compilation History*`.

## Driving it with keys.sh

Preconditions:

- A `--tui` launch with only the `alpha-marker` and `beta-marker` records from `history-view.md`'s preconditions, and the view open. Run this before `history-view.md`'s Refresh step adds more.

- **Plain.** Run `$S/keys.sh s`, `$S/keys.sh -l beta`, `$S/keys.sh Enter`, then `$S/screen.sh --wait '\(1 records\)' search-plain`. Only `beta-marker` is listed and the mode line shows `[search: beta]`. For every later search, also wait on `\[search: TERM\]`, so an earlier screen with the same count cannot satisfy the wait.
- **Output only.** Search `output:started`. The screen shows `(2 records)`.
- **Column.** Search `compile_command:started`. The screen shows `No compilations found.`
- **Branch.** Search `git_branch:branch`. The screen shows `(2 records)`, because both records are on branch `verify-branch`.
- **Short.** Search `compile_command:ex`. The two-character value uses the `LIKE` fallback; only `beta-marker` is listed.
- **State.** Search `state:failure`. The screen shows `(1 records)` with `beta-marker`. Then press `s`, type `state:bogus` and press `Enter`. The screen shows `Unknown state` and the mode line still shows `[search: state:failure]`.
- **Complete.** Press `s`, type `sta`, press `Tab`, type `fa`, press `Tab`. The prompt reads `state:failure`. Press `C-a C-k`, type `compile_c`, press `Tab`. The prompt reads `compile_command:`. The prompt is still open.
- **Clear.** In that open prompt, press `C-a C-k` then `Enter`. The footer returns to all records and the mode line drops `[search: …]`.

## Gotchas

- The prompt shows `Search (current: TERM):` while a filter is active; a new term replaces it.
- Keys sent while the prompt is open are typed into it. Pressing `s` again there types `s` into the prompt.
