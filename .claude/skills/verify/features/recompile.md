# Recompile

`g` in a compilation-history buffer reruns its command as a new compilation with a new history row. `C-u g` lets the user edit the command first. `compilation-history-recompile-switch-behavior` decides which window is selected afterwards: `switch` (the default) selects the window showing the new buffer, `pop` calls `pop-to-buffer` so `display-buffer-alist` rules apply, and nil leaves the selection alone, as plain Emacs `recompile` does. The original record and buffer are unchanged.

## Sub-features

- `recompile-new-record` adds a new row with the same command and directory.
- `recompile-switch` selects the new buffer under `switch` and `pop`, and keeps the old one selected under nil.
- `recompile-edit-command` reruns an edited command with `C-u g` and leaves the original buffer's command as recorded, so a later plain `g` there reruns the original.
- `recompile-original-kept` leaves the original buffer and row as they were.
- `recompile-from-view` works on a buffer opened from the history view.
- `recompile-after-show` works on a closed compilation that `compilation-history-agent show ID --select` reopened (c907b62): `g` there recompiles it.

## How to get to it (user POV)

- `g` in a `*compilation-history-…*` buffer, live or opened from the view.
- `g` in a buffer that `compilation-history-agent show ID --select` reopened.

## Driving it with keys.sh

Preconditions:

- A `--tui` launch with one finished `alpha-marker` record. Keep its ID: `orig=$($S/cli.sh run --directory "$VERIFY_ROOT/work" --command "printf 'alpha-marker\n'" | jq -r .id)`.

- **Open from view.** Run `$S/keys.sh C-c c v`, `$S/screen.sh --wait '\(1 records\)'`, `$S/keys.sh M-\<`, `$S/keys.sh Enter`. The selected buffer is the `alpha-marker` compilation.
- **Recompile.** Save `before=$($S/observe.sh '(buffer-name (window-buffer (selected-window)))')`, which keeps the Lisp quotes, then press `$S/keys.sh g`. Wait until `$S/cli.sh list` reports `.total == 2` with both records `success`. Don't wait for `Compilation finished`, because the opened buffer already shows it. The selected buffer name differs from `before` and contains `alpha-marker`.
- **New row.** Run `$S/keys.sh C-c c v`, which redraws the view, then `$S/keys.sh C-x 1` and `$S/screen.sh --wait '\(2 records\)' recompile-rows`. Both rows show `printf 'alpha-marker\n'` with `success 0`.
- **Original kept.** `$S/observe.sh "(buffer-live-p (get-buffer $before))"` is `t`, `$S/observe.sh "(with-current-buffer $before compile-command)"` is still the original command, and `$S/cli.sh get "$orig"` still reports `success` with exit 0. `$before` already carries its quotes, so don't add more.
- **Edit the command.** After New row's `C-x 1` only the view's window is left, so `C-x o` cannot reach `$before`. In the view, press `$S/keys.sh M-\<`, `$S/keys.sh C-n` and `$S/keys.sh Enter`. Row 2 is the original, because rows are newest first, and `RET` reuses its live buffer, so `observe.sh` names `$before`. Press `$S/keys.sh C-u g` and wait for `Compile command: printf 'alpha-marker`. Clear it with `C-a C-k`, type `printf 'edited-marker\n'`, and press `Enter`. Wait until `cli.sh list` grows by one. Its newest record has the edited command, and the selected buffer name contains `edited-marker`. `$S/observe.sh "(with-current-buffer $before (list compile-command (car compilation-arguments)))"` still names `printf 'alpha-marker\n'` twice. Go back to `$before` and press `g`; the next new record runs `printf 'alpha-marker\n'`.
- **Switch settings.** Run `$S/observe.sh "(setq compilation-history-recompile-switch-behavior 'nil)"`, select `$before`, and press `g`. A new record appears and the selected buffer is still `$before`. Repeat with `'pop`; the new buffer is selected. Restore with `'switch`.
- **From history.** `Q` works only in the view. Run `$S/keys.sh C-c c v`, then `$S/keys.sh Q` so no compilation buffer is live, then `$S/keys.sh C-c c v` again, and open row 1 with `M-\<` and `Enter`. The view rebuilds that buffer from the database with `compilation-history-buffer-mode` on. Press `g` and wait until `cli.sh list` grows by one; the new record is `success` with the same command.
- **After show.** Run `$S/cli.sh show "$orig" --select`. Its buffer is dead after `Q`, so `show` reopens it from history. Press `$S/keys.sh g` and wait until `$S/cli.sh list` grows by one. The new record runs `printf 'alpha-marker\n'`.

## Gotchas

- `g` in `*Compilation History*` refreshes the view; in a compilation buffer it recompiles. Check which buffer is selected before pressing it.
- `RET` opens the record below the view. The recompile then splits the view's window side by side, which cuts off the view's footer and mode line. `C-x 1` restores the full-width view so `(2 records)` is on screen.
- `RET` reuses a compilation buffer that is still live. Only the From history step, through the view, and the After show step, through `cli.sh show`, cover a buffer rebuilt from the database.
- With no `display-buffer-alist` rule for these buffers, `pop` and `switch` select the same window. Telling them apart needs a rule that sends the new buffer somewhere `compilation-start` did not.
- To get back to `$before` after a recompile, open the original's row in the view with `RET` (row 2 in the Edit the command step). Pressing `C-x o` until `observe.sh` names it works only while `$before` is still in a window.
- `C-x b` opens a buffer-name prompt; it does not go back to the view on its own.
