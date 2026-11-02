# Compile tracking

With `compilation-history-mode` on, every `M-x compile` the user runs gets its own uniquely named buffer and a history row with command, directory, git branch and commit, exit code, duration and output. Comint compiles (`C-u M-x compile`) are tracked too. Every finished compile buffer turns read-only, with `q` bound to `quit-window` and `g` to `recompile`.

## Sub-features

- `track-success` records a finished compile as `success` with exit 0.
- `track-failure` records a failing compile as `failure` with its exit code.
- `track-killed` records an interrupted compile as `killed`.
- `track-buffer-name` names the buffer `*compilation-history-<ID>==<dir>__<command>*`.
- `track-git` records the branch and commit of the compile directory.
- `track-comint` tracks `C-u M-x compile` and makes the finished buffer read-only with `q` bound to `quit-window`.

## How to get to it (user POV)

- `C-c c c` (`compilation-history-map` is bound to `C-c c` in the verify session).
- `M-x compile`.
- `C-u M-x compile` for a comint compile.

## Driving it with keys.sh

Preconditions:

- `eval "$($S/launch.sh --tui)"`, a fresh `VERIFY_EVIDENCE`, and `DOCTOR OK`.
- The session starts in `$VERIFY_ROOT/work`, a git repo on branch `verify-branch` with one commit.

- **Prompt.** Run `$S/keys.sh C-c c c` and `$S/screen.sh --wait 'Compile command:'`. The minibuffer shows `Compile command: make -k ...` the first time, then the last command.
- **Success.** Run `$S/keys.sh C-a C-k`, `$S/keys.sh -l "printf 'alpha-marker\n'"`, `$S/keys.sh Enter`, then `$S/screen.sh --wait 'Compilation finished' track-success 15`. The screen shows `alpha-marker` and a mode line naming `*compilation-history-…printf-alpha-marker…*`.
- **Failure.** Repeat with `printf 'beta-marker\n'; exit 3` and wait for `exited abnormally with code 3`.
- **Killed.** Repeat with `sleep 30` and wait for `Compilation started`. Run `$S/keys.sh C-x o` until `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'` names the `sleep-30` buffer, then `$S/keys.sh C-c C-k` and wait for `Compilation interrupt`. The view later shows that row as `killed` with exit `2`.
- **Persisted.** Run `$S/keys.sh C-c c v` and `$S/screen.sh --wait '\(3 records\)' track-rows`. Rows read, newest first, `killed 2`, `failure 3`, `success 0`, each with branch `verify-branch` and a 7-character commit. The view fills the frame; press `q` before the next compile.
- **Comint.** Run `$S/keys.sh C-u C-c c c`, clear the prompt, enter `printf 'name? '; read n; echo "hi $n"`, and wait for `name?`. Run `$S/keys.sh C-x o` until the selected buffer name contains `printf-name`, then `$S/keys.sh -l world` and `$S/keys.sh Enter`, and wait for `Comint finished`. The screen shows `hi world`, and `$S/observe.sh '(with-current-buffer (window-buffer (selected-window)) (list buffer-read-only (key-binding "q")))'` is `(t quit-window)`.

## Gotchas

- The compile prompt is prefilled, with `make -k ...` the first time and the previous command after that. Clear it with `C-a C-k` before typing.
- Wait for the finish text before the next step; `compilation-history-view` only shows a finished row after the final save.
- A new compilation is displayed in the other window but not selected. Keys like `C-c C-k` or typed comint input go to the selected window, so move there with `C-x o` and confirm with `observe.sh` first. Typing into the wrong buffer shows `C-c C-k is undefined` or `No error here`.
- Commands run in Emacs's `shell-file-name`, which may be zsh. Use POSIX-portable commands; `read -p` means "read from coprocess" in zsh.
- Comint compiles end with `Comint finished`, not `Compilation finished`.
- A `sleep 30` that isn't killed promptly finishes as `success`. Kill it within a few seconds.
