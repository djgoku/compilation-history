# History view

`M-x compilation-history-view` (`C-c c v`) lists recorded compilations newest first, a page at a time, and lets the user open, preview, refresh and page through them.

## Sub-features

- `view-columns` shows `#`, `Start Time`, `Duration`, `Status`, `Exit`, `Commit`, `Branch`, `Directory`, `Command`.
- `view-open` opens the record at point in another window with `RET` and selects it.
- `view-preview` shows the record at point with `SPC` and keeps the view selected; `n`/`p` then move and update the preview.
- `view-refresh` picks up new compilations with `g`.
- `view-paging` moves between pages with `C-v`, `M-v`, `<`, `>`.
- `view-quit` buries opened buffers and the view with `q`; `Q` kills them.

## How to get to it (user POV)

- `C-c c v` or `M-x compilation-history-view`.

## Driving it with keys.sh

Preconditions:

- A `--tui` launch with at least two finished compiles. Fastest is `$S/cli.sh run --directory "$VERIFY_ROOT/work" --command "printf 'alpha-marker\n'"`, then the same with `printf 'beta-marker\n'; exit 3`; `compile-tracking.md` covers the keyboard path.

- **Open view.** Run `$S/keys.sh C-c c v` and `$S/screen.sh --wait '\(2 records\)' view-list`. The header line lists the nine columns; row 1 is `beta-marker` with `failure 3`, row 2 `alpha-marker` with `success 0`. The footer reads `Page 1 of 1 (2 records)`.
- **Open a record.** Run `$S/keys.sh M-\<` then `$S/keys.sh Enter`. `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'` names the `beta-marker` compilation buffer, and `screen.sh` shows its output below the view.
- **Preview.** Run `$S/keys.sh C-x o` back to the view, `$S/keys.sh Space`, then `$S/keys.sh n`. The selected window stays `*Compilation History*` and the other window switches to the `alpha-marker` buffer.
- **Refresh.** Run another `cli.sh run` with `printf 'gamma-marker\n'`, then `$S/keys.sh g`. The footer reads `(3 records)` and row 1 is `gamma-marker`.
- **Paging.** Run `tmux -S "$VERIFY_ROOT/tmux.sock" resize-window -t verify -y 12`, make 8 more records with `cli.sh run`, then `$S/keys.sh g`. The footer shows `Page 1 of N` with N > 1; `C-v` shows `Page 2`, `>` the last page, `<` page 1.
- **Quit.** Run `$S/keys.sh q`. The view and opened buffers are no longer displayed; `$S/observe.sh '(get-buffer "*Compilation History*")'` is still a live buffer.

## Gotchas

- The `#` header is the window's header line, not buffer text. Buffer line 1 is the newest row; `M-<` lands on it.
- `n` and `p` only update the other window after `SPC` turns preview on. Send it as `keys.sh Space`; `keys.sh SPC` types the letters S, P and C.
- Page size is the window height minus 6, so paging needs a short window or many records.
- Rows sort by start time, and compilations started in the same second list newest first.
