# Show a compilation

`show` displays a compilation's buffer on the selected Emacs frame without selecting it, unless `--select` is given. When the buffer was closed, it first recreates it from the saved record and output, as `RET` in the history view does. `start --display` and `run --display` do the same at start. Each of these replies holds only `protocol_version`, `id`, `state`, `buffer` and `display`; `get` has the outcome. Nothing raises a frame or requests OS focus.

## Sub-features

- `show-no-select` makes the buffer visible and leaves the selected window alone.
- `show-select` selects the compilation window.
- `start-display` shows the buffer at start without selecting it.
- `show-split-frame` uses the other window when the frame is already split and cannot split again.
- `show-reopen` recreates a closed compilation's buffer from history, read-only with its saved output, then shows it.
- `show-unknown` returns `unknown_id` with recovery when neither a live buffer nor a history record has that ID.

## How to get to it (user POV)

- `compilation-history-agent show ID [--select]`.
- `compilation-history-agent start|run ... --display`.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Build.** Run `id=$($S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf shown' | jq -r .id)`.
- **Show.** Run `$S/capture.sh show-plain $S/cli.sh show "$id"`. `.display.visible == true`, `.display.selected == false`, `.state == "succeeded"`. Confirm with `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'`, which is not the compilation buffer named in `.buffer`.
- **Select.** Run `$S/capture.sh show-select $S/cli.sh show "$id" --select`. `.display.selected == true`; `observe.sh` now returns the compilation buffer's name.
- **Display at start.** Run `$S/capture.sh start-display $S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 1; printf at-start' --display`. `.state == "running"`, `.display.visible == true`, `.display.selected == false`. Then `wait` its ID. `run --display` would report the display at completion instead.
- **Split frame.** After the steps above, `$S/observe.sh '(length (window-list))'` is `2`. Run another `cli.sh run ... --display`. The window count stays `2`; no `error`; `.display.visible == true`, `.display.selected == false`, and the selected window's buffer is unchanged.
- **Reopen.** Run `oid=$($S/cli.sh run --directory "$VERIFY_ROOT" --command "printf 'old-build-marker\n'; exit 2" | jq -r .id)`, then close its buffer with `$S/observe.sh "(let ((kill-buffer-query-functions nil)) (kill-buffer (compilation-history-agent--find-buffer \"$oid\")))"`. `$S/capture.sh show-reopen $S/cli.sh show "$oid"` reports `.state == "failed"`, `.display.visible == true` and `.display.selected == false`. In a `--tui` launch the screen shows `old-build-marker` and `exited abnormally with code 2`. A second `show` reuses that buffer: `observe.sh` finds one buffer whose name contains `$oid`. `g` in it recompiles as a new record.
- **Unknown.** Run `$S/capture.sh show-unknown $S/cli.sh show 20000101T000000000000`. Exit 1; `.error == "unknown_id"` and `.recovery` present.

## Gotchas

- A reopened buffer holds the saved output, which can differ from what the live buffer showed.
