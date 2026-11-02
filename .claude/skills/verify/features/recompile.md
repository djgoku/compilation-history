# Recompile

`g` in a compilation-history buffer reruns its command as a new compilation with a new history row, and by default selects the new buffer (`compilation-history-recompile-switch-behavior` is `switch`). The original record is unchanged.

## Sub-features

- `recompile-new-record` adds a new row with the same command and directory.
- `recompile-switch` selects the new buffer.
- `recompile-original-kept` leaves the original buffer and row as they were.
- `recompile-from-view` works on a buffer opened from the history view.

## How to get to it (user POV)

- `g` in a `*compilation-history-…*` buffer, live or opened from the view.

## Driving it with keys.sh

Preconditions:

- A `--tui` launch with one finished `alpha-marker` record.

- **Open from view.** Run `$S/keys.sh C-c c v`, `$S/screen.sh --wait '\(1 records\)'`, `$S/keys.sh M-\<`, `$S/keys.sh Enter`. The selected buffer is the `alpha-marker` compilation.
- **Recompile.** Record `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'` as `before`, press `$S/keys.sh g`, and wait for `Compilation finished`. The selected buffer name differs from `before` and contains `alpha-marker`.
- **New row.** Run `$S/keys.sh C-c c v`, which redraws the view, then `$S/keys.sh C-x 1` and `$S/screen.sh --wait '\(2 records\)' recompile-rows`. Both rows show `printf 'alpha-marker\n'` with `success 0`.
- **Original kept.** `$S/observe.sh "(buffer-live-p (get-buffer \"$before\"))"` is `t`.

## Gotchas

- `g` in `*Compilation History*` refreshes the view; in a compilation buffer it recompiles. Check which buffer is selected before pressing it.
- After the recompile the frame is split side by side, which cuts off the view's footer and mode line. `C-x 1` restores the full-width view so `(2 records)` is on screen.
- `C-x b` opens a buffer-name prompt; it does not go back to the view on its own.
