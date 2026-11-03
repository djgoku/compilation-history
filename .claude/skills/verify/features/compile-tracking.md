# Compile tracking

With `compilation-history-mode` on, every `M-x compile` the user runs gets its own uniquely named buffer and a history row with command, directory, git branch and commit, exit code, duration and output. Comint compiles (`C-u M-x compile`) are tracked too. Every finished compile buffer turns read-only, with `q` bound to `quit-window` and `g` to `recompile`.

## Sub-features

- `track-success` records a finished compile as `success` with exit 0.
- `track-failure` records a failing compile as `failure` with its exit code.
- `track-killed` records an interrupted compile (`C-c C-k`) as `killed` with the signal's exit code.
- `track-kill-buffer` records a running compile whose buffer is killed (`C-x k`) as `killed` with exit `-1`.
- `track-buffer-name` names the buffer `*compilation-history-<ID>==<project>[--subdir]__<command>*`. `<ID>` is the `YYYYMMDDTHHMMSSffffff` start time, `<project>` is the git root's name, and `<command>` has every character outside `[a-zA-Z0-9-]` turned into `-`, cut to 25 characters. A compile in `$VERIFY_ROOT/work` running `printf 'alpha-marker\n'` gets `==work__printf-alpha-marker-n-`.
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
- **Success.** Run `$S/keys.sh C-a C-k`, `$S/keys.sh -l "printf 'alpha-marker\n'"`, `$S/keys.sh Enter`, then `$S/screen.sh --wait 'Compilation finished' track-success 15`. The screen shows `alpha-marker` and a mode line naming `*compilation-history-…==work__printf-alpha-marker-n-*`.
- **Failure.** Repeat with `printf 'beta-marker\n'; exit 3` and wait for `exited abnormally with code 3`.
- **Killed.** Repeat with `sleep 30` and wait for `Compilation started`. Run `$S/keys.sh C-x o` until `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'` names the `sleep-30` buffer, then `$S/keys.sh C-c C-k` and wait for `Compilation interrupt`. The view later shows that row as `killed` with exit `2`.
- **Killed buffer.** Repeat with `sleep 31`, move to its buffer as above, then `$S/keys.sh C-x k Enter`, wait for `has a running process; kill it`, and answer `$S/keys.sh -l yes` then `Enter`. `$S/cli.sh list --limit 1` reports `killed` with `exit_code == -1`.
- **Persisted.** Run `$S/keys.sh C-c c v` and `$S/screen.sh --wait '\(4 records\)' track-rows`. Rows read, newest first, `killed -1`, `killed 2`, `failure 3`, `success 0`, each with branch `verify-branch` and a 7-character commit. The view fills the frame; press `q` before the next compile.
- **Comint.** Run `$S/keys.sh C-u C-c c c`, clear the prompt, enter `sleep 2; printf 'name? '; read n; echo "hi $n"`, and wait for `Comint started`. The prompt is printed once `$S/observe.sh '(with-current-buffer (seq-find (lambda (b) (string-match-p "printf-name" (buffer-name b))) (buffer-list)) (save-excursion (goto-char (point-max)) (looking-back "name\\? " nil)))'` returns `t`; it is `nil` during the first two seconds. Run `$S/keys.sh C-x o` until the selected buffer name contains `printf-name`, then `$S/keys.sh -l world` and `$S/keys.sh Enter`, and wait for `Comint finished`. The screen shows `hi world`, and `$S/observe.sh '(with-current-buffer (window-buffer (selected-window)) (list buffer-read-only (key-binding "q")))'` is `(t quit-window)`.

## Gotchas

- The compile prompt is prefilled, with `make -k ...` the first time and the previous command after that. Clear it with `C-a C-k` before typing.
- The view lists a compile from its start as `running` with no exit or duration. Status and exit appear only after the final save, so wait for the finish text before the next step.
- Don't wait for text that is part of the command. The command line is on screen as soon as you press `Enter`, so `--wait 'name?'` matches before the process prints anything.
- A new compilation is displayed in the other window but not selected. Keys like `C-c C-k` or typed comint input go to the selected window, so move there with `C-x o` and confirm with `observe.sh` first. Typing into the wrong buffer shows `C-c C-k is undefined` or `No error here`.
- Commands run in Emacs's `shell-file-name`, which may be zsh. Use POSIX-portable commands; `read -p` means "read from coprocess" in zsh.
- Comint compiles end with `Comint finished`, not `Compilation finished`.
- A `sleep 30` that isn't killed promptly finishes as `success`. Kill it within a few seconds.
