# Compile tracking

With `compilation-history-mode` on, every `M-x compile` the user runs gets its own uniquely named buffer and a history row with command, directory, git branch and commit, exit code, duration and output. Comint compiles (`C-u M-x compile`) are tracked too, and their saved output includes the input the user typed, so for plain output it matches the buffer. Saved output keeps raw ANSI escapes. Every finished compile buffer turns read-only, with `q` bound to `quit-window` and `g` to `recompile`.

## Sub-features

- `track-success` records a finished compile as `success` with exit 0.
- `track-failure` records a failing compile as `failure` with its exit code.
- `track-killed` records an interrupted compile (`C-c C-k`) as `killed` with the signal's exit code.
- `track-kill-buffer` records a running compile whose buffer is killed (`C-x k`) as `killed` with exit `-1`.
- `track-buffer-name` names the buffer `*compilation-history-<ID>==<project>[--subdir]__<command>*`. `<ID>` is the `YYYYMMDDTHHMMSSffffff` start time, `<project>` is the git root's name, and `<command>` has every character outside `[a-zA-Z0-9-]` turned into `-`, each run of `-` collapsed to one, then cut to 25 characters. A compile in `$VERIFY_ROOT/work` running `printf 'alpha-marker\n'` gets `==work__printf-alpha-marker-n-`.
- `track-git` records the branch and commit of the compile directory.
- `track-incremental` saves output while the compile runs, every 10 s or 100 lines, so `get` on a running compile already has a tail.
- `track-ansi` keeps raw ANSI escapes in the saved output.
- `track-comint` tracks `C-u M-x compile`, saves typed input along with process output so the saved output equals the buffer for plain output, and makes the finished buffer read-only with `q` bound to `quit-window`.
- `track-comint-password` keeps a password typed at a hidden prompt out of the buffer and the saved output.

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
- **Failure.** Repeat with `printf 'beta-marker\n'; exit 3` and wait for `exited abnormally with code 3`. To cover `track-ansi` too, use `printf '\033[31mbeta-marker\033[0m\n'; exit 3` instead. Take the ID from `$S/cli.sh list --limit 1`, and `$S/cli.sh get ID --full | jq '.output|contains("\u001b[31m")'` prints `true`.
- **Killed.** Repeat with `sleep 30`. Don't wait for `Compilation started`, because the previous buffer still shows it and the wait returns at once. Instead wait until `$S/observe.sh '(seq-find (lambda (b) (string-match-p "sleep-30" (buffer-name b))) (buffer-list))'` returns a buffer, not `nil`. Run `$S/keys.sh C-x o` until `$S/observe.sh '(buffer-name (window-buffer (selected-window)))'` names the `sleep-30` buffer, then `$S/keys.sh C-c C-k` and wait for `Compilation interrupt`. The view later shows that row as `killed` with exit `2`.
- **Killed buffer.** Repeat with `seq 1 150; sleep 31`. Wait until `observe.sh` finds a buffer whose name contains `sleep-31`, as above, and move to it. Take the ID from `$S/cli.sh list --limit 1`. Before `C-x k`, `$S/cli.sh get ID` reports `.state == "running"` with `.tail` containing `100`, which the incremental save wrote. Then run `$S/keys.sh C-x k Enter`, wait for `has a running process; kill it`, and answer `$S/keys.sh -l yes` then `Enter`. `$S/cli.sh list --limit 1` reports `killed` with `exit_code == -1`.
- **Persisted.** Run `$S/keys.sh C-c c v` and `$S/screen.sh --wait '\(4 records\)' track-rows`. Rows read, newest first, `killed -1`, `killed 2`, `failure 3`, `success 0`, each with branch `verify-branch` and a 7-character commit. Each row shows the status, then the right-aligned exit, so the screen reads like `failure     3`. Match `failure +3`, not the literal `failure 3`, and the same for the others. The view fills the frame; press `q` before the next compile.
- **Comint.** Run `$S/keys.sh C-u C-c c c`, clear the prompt, enter `sleep 2; printf 'name? '; read n; echo "hi $n"`, and wait for `Comint started`. The prompt is printed once `$S/observe.sh '(with-current-buffer (seq-find (lambda (b) (string-match-p "printf-name" (buffer-name b))) (buffer-list)) (save-excursion (goto-char (point-max)) (looking-back "name\\? " nil)))'` returns `t`; it is `nil` during the first two seconds. Run `$S/keys.sh C-x o` until the selected buffer name contains `printf-name`, then `$S/keys.sh M-\>`, `$S/keys.sh -l world` and `$S/keys.sh Enter`, and wait for `Comint finished`. The screen shows `hi world` on its own line, and `$S/observe.sh '(with-current-buffer (window-buffer (selected-window)) (list buffer-read-only (key-binding "q") (equal (buffer-substring-no-properties (point-min) (point-max)) (caar (sqlite-select (sqlite-open compilation-history-db-file) "select output from compilations where id = ?" (vector (compilation-history-record-id compilation-history-record)))))))'` is `(t quit-window t)`. Take the ID from `$S/cli.sh list --limit 1`; `$S/capture.sh track-comint-saved $S/cli.sh get ID --full` has `.output` with `name? world` followed by `hi world`.
- **Password.** Run `$S/keys.sh C-u C-c c c`, clear the prompt, enter `sleep 1; printf 'Password: '; read p; echo "len ${#p}"`, and wait for `Comint started`. Wait for `$S/screen.sh --wait 'Password: *$' track-password-prompt 10`; the minibuffer reads `(In buffer *compilation-history-…printf-Password-r*) Password:`, so no `C-x o` is needed. Run `$S/keys.sh -l hunter2-secret`; the minibuffer shows only `*` characters. Press `$S/keys.sh Enter` and wait for `Password: len 14`, not `Comint finished`, which the previous step's comint buffer still shows. `Password: len 14` proves the process got the secret. Take the ID from `$S/cli.sh list --limit 1`: `$S/capture.sh track-password-saved $S/cli.sh get ID --full` has no `hunter2` in `.output`, and `$S/observe.sh '(with-current-buffer (seq-find (lambda (b) (string-match-p "printf-Password" (buffer-name b))) (buffer-list)) (equal (buffer-substring-no-properties (point-min) (point-max)) (caar (sqlite-select (sqlite-open compilation-history-db-file) "select output from compilations where id = ?" (vector (compilation-history-record-id compilation-history-record))))))'` returns `t`. It finds the buffer by name because the selected window still holds the `printf-name` buffer.

## Gotchas

- The compile prompt is prefilled, with `make -k ...` the first time and the previous command after that. Clear it with `C-a C-k` before typing.
- The view lists a compile from its start as `running` with no exit or duration. Output is saved during the run, but status and exit appear only after the final save, so wait for the finish text before the next step.
- Don't wait for text that is part of the command. The command line is on screen as soon as you press `Enter`, so `--wait 'name?'` matches before the process prints anything.
- A new compilation is displayed in the other window but not selected. Keys like `C-c C-k` or typed comint input go to the selected window, so move there with `C-x o` and confirm with `observe.sh` first. Typing into the wrong buffer shows `C-c C-k is undefined` or `No error here`.
- Commands run in Emacs's `shell-file-name`, which may be zsh. Use POSIX-portable commands; `read -p` means "read from coprocess" in zsh.
- The hidden prompt only appears when the process output matches `comint-password-prompt-regexp` (`Password:` does) and `comint-watch-for-password-prompt` is on `comint-output-filter-functions`, which it is by default. Any other prompt text is read as ordinary input, so it is echoed and saved.
- Comint compiles end with `Comint finished`, not `Compilation finished`.
- `C-x o` into a new comint buffer leaves point at the top. Press `M->` before typing input; otherwise `Enter` resends the old text at point (the header lines) as input, and `hi world` still appears, but as `hi world-*- mode: …`.
- A `sleep 30` that isn't killed promptly finishes as `success`. Kill it within a few seconds.
