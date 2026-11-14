# Show a compilation

`show` displays a compilation's buffer on the selected Emacs frame without selecting it, unless `--select` is given. When the buffer was closed, it first recreates it from the saved record and output, as `RET` in the history view does. `start --display` and `run --display` do the same at start. A `show` reply holds only `protocol_version`, `id`, `state`, `buffer` and `display`, so `get` has the outcome. Its `state` is the saved state, the one `get` and `list` report. `start --display` adds `command` and `directory`, as any `start` reply does, and `run --display` returns the full `get` result plus `display`. Nothing raises a frame or requests OS focus.

## Sub-features

- `show-no-select` makes the buffer visible and leaves the selected window alone.
- `show-select` selects the compilation window.
- `start-display` shows the buffer at start without selecting it.
- `show-split-frame` uses the other window when the frame is already split and cannot split again.
- `show-reopen` recreates a closed compilation's buffer from history, read-only with its saved output, then shows it.
- `show-unknown` returns `unknown_id` with recovery when neither a live buffer nor a history record has that ID.
- `show-state-matches-get` reports the saved state even when the buffer's in-memory record differs, as after `compilation-history-mode` is turned off mid-run.

## How to get to it (user POV)

- `compilation-history-agent show ID [--select]`.
- `compilation-history-agent start|run ... --display`.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Build.** Run `id=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf shown' | jq -r .id)`.
- **Show.** Run `$S/capture.sh show-plain $S/cli.sh show "$id"`. `.display.visible == true`, `.display.selected == false`, `.state == "success"`. Confirm with `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'`, which is not the compilation buffer named in `.buffer`.
- **Select.** Run `$S/capture.sh show-select $S/cli.sh show "$id" --select`. `.display.selected == true`; `observe.sh` now returns the compilation buffer's name.
- **Display at start.** Run `$S/capture.sh start-display $S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 1; printf at-start' --display`. `.state == "running"`, `.display.visible == true`, `.display.selected == false`. Then `wait` its ID. `run --display` would report the display at completion instead.
- **Split frame.** After the steps above, `$S/observe.sh '(length (window-list))'` is `2`. Run another `cli.sh run ... --display`. The window count stays `2`; no `error`; `.display.visible == true`, `.display.selected == false`, and the selected window's buffer is unchanged.
- **Reopen.** Run `oid=$($S/cli.sh run --directory "$VERIFY_ROOT" --command "printf 'old-build-marker\n'; exit 2" | jq -r .id)`. Close its buffer the way a user does in a `--tui` launch: `$S/cli.sh show "$oid" --select`, then `$S/keys.sh C-x k` and `$S/keys.sh Enter`. A finished buffer asks nothing. In a batch launch, close it instead with the setup form `$S/observe.sh "(let ((kill-buffer-query-functions nil)) (kill-buffer (compilation-history-agent--find-buffer \"$oid\")))"`. `$S/capture.sh show-reopen $S/cli.sh show "$oid"` reports `.state == "failure"`, `.display.visible == true` and `.display.selected == false`. In a `--tui` launch the screen shows `old-build-marker` and `exited abnormally with code 2`. A second `show` reuses that buffer: `observe.sh` finds one buffer whose name contains `$oid`. The plain `show` leaves another buffer selected, so first run `$S/cli.sh show "$oid" --select`, then `$S/keys.sh g`. `$S/cli.sh list --limit 1` then has a new ID with the same command as `$oid`.
- **State matches get.** Run `mid=$($S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 2; exit 4' | jq -r .id)`, then `$S/observe.sh '(compilation-history-mode -1)'` while it runs, then `$S/cli.sh wait "$mid"`. `$S/capture.sh show-mode-off $S/cli.sh show "$mid"` and `$S/capture.sh get-mode-off $S/cli.sh get "$mid"` report the same `.state`. Restore with `$S/observe.sh '(compilation-history-mode 1)'`.
- **Unknown.** Run `$S/capture.sh show-unknown $S/cli.sh show 20000101T000000000000`. Exit 1; `.error == "unknown_id"` and `.recovery` present.

## Gotchas

- A reopened buffer is read-only, and `g` in it recompiles. Since 07d7c6f it holds the saved output with typed comint input. That output lacks input typed at a hidden prompt, and its raw ANSI escapes can render differently from the live buffer.
