---
name: verify
description: Drive compilation-history end to end in a disposable Emacs. Terminal Emacs under tmux covers the user's side (M-x compile tracking, the history view, search, recompile); the agent CLI (bin/compilation-history-agent) covers start, wait, run, get, show and doctor. Use after changing any compilation-history*.el file or the CLI, and before claiming a change works.
---

# Verify compilation-history

compilation-history has two user surfaces:

- **Emacs UI.** A user runs `M-x compile` (`C-c c c`), browses
  `M-x compilation-history-view` (`C-c c v`), searches it, opens and
  recompiles entries. It works in terminal and graphical Emacs; this skill
  drives real keystrokes in `emacs -nw` under a private tmux server.
- **Agent CLI.** A coding agent runs `bin/compilation-history-agent` in a shell
  to start compilations, block until they finish, and recover persisted output.

Every drive runs against a **disposable Emacs** with its own history database
and server socket. Never point this skill at the user's personal Emacs, their
normal history DB, or their own tmux server: they hold the user's buffers and
real history rows, and the CLI's `--server` flag can reach them. Graphical-only
behavior (mouse clicks, alternating row colors) is not covered.

All helpers live in `.claude/skills/verify/scripts/` (paths below are relative
to the repo root) and are executable.

## Launch

```bash
eval "$(.claude/skills/verify/scripts/launch.sh)"        # agent CLI recipes
eval "$(.claude/skills/verify/scripts/launch.sh --tui)"  # Emacs UI recipes
export VERIFY_EVIDENCE=$PWD/.verify/evidence/$(date +%Y%m%dT%H%M%S)
```

Both modes create `/tmp/ch-verify.XXXXXX` with a git repo at `work/` (branch
`verify-branch`, one commit) and the same DB and server socket paths, so
`cli.sh`, `observe.sh` and `doctor.sh` work against either.

`--tui` starts `emacs -nw -Q -l .claude/skills/verify/scripts/tui-init.el` in
a 160x48 tmux session named `verify` on the private socket
`$VERIFY_ROOT/tmux.sock`, in `work/`. `tui-init.el` binds
`compilation-history-map` to `C-c c`, enables history and the agent interface,
starts the server, and writes `ready` once all of that is done.

`--tui` also prints a watch command on stderr, so the user can watch a drive
in their own terminal. It redraws `capture-pane` output in a loop instead of
attaching: while a read-only client (`attach -r`) is attached, tmux 3.7 rejects
every `send-keys`, so `keys.sh` refuses to run. Live runs catch focus,
window-layout and shell differences that headless runs miss. To find a launch
that is already running instead of asking for its root, use
`ls -dt /tmp/ch-verify.*`.

The default (batch) mode starts
`emacs --batch -Q -l tests/compilation-history-agent-server-fixture.el` from
this checkout with `CH_AGENT_TEST_ROOT` pointing there, and waits up to 20 s
for the fixture to write `ready` to a FIFO. Ready means `server-start`,
`compilation-history-mode`, `compilation-history-agent-mode` and the DB schema
have all completed, so the instance is usable from an empty data dir. On
timeout it prints the server log and exits nonzero.

The fixture sets `temporary-file-directory`, `default-directory`, the DB
(`$VERIFY_ROOT/history.db`) and the server socket
(`$VERIFY_ROOT/emacs-server/agent-test`) inside the root. Several launches can
run side by side; each has its own root.

## Doctor

```bash
.claude/skills/verify/scripts/doctor.sh
```

Read-only. Passes only when the root came from `launch.sh`, the recorded pid is
alive, the server loaded `compilation-history-agent.el` from **this checkout**,
and `cli doctor` reports history and interface enabled, a socket inside the
root, and `database == $VERIFY_ROOT/history.db`. Run it first, and again
whenever a result looks wrong.

## Drive

Emacs UI, after `launch.sh --tui`:

```bash
S=.claude/skills/verify/scripts
$S/keys.sh C-c c c                          # tmux key names
$S/keys.sh -l "printf 'hello\n'"            # literal text
$S/keys.sh Enter
$S/screen.sh --wait 'Compilation finished' compile-done 15
$S/screen.sh view-open                      # print and save the screen
```

`keys.sh` sends tmux key names, or literal text with `-l`. `screen.sh` prints
the screen as text; with a label it saves `$VERIFY_EVIDENCE/LABEL.screen`;
`--wait REGEX [LABEL] [SECONDS]` polls until the screen matches and fails with
the screen on timeout.

Agent CLI:

```bash
S=.claude/skills/verify/scripts
$S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf hello'
$S/cli.sh start --directory "$VERIFY_ROOT" --command 'sleep 2; exit 3'
$S/cli.sh wait ID
$S/cli.sh get ID [--full]
$S/cli.sh show ID [--select]
$S/observe.sh '(buffer-name (window-buffer (selected-window)))'
```

`cli.sh` runs the real CLI with `--server` fixed to the disposable server.
`observe.sh FORM` evaluates one Lisp form there to observe state the CLI does
not report (selected window, live buffers, DB rows). Use it only to observe,
never to cause the behavior under test.

Every CLI call prints one JSON object. Exit 0 means the protocol worked, not
that the build passed: read `state` (`running`, `succeeded`, `failed`,
`killed`) and `exit_code`. Protocol errors exit 1 with `error`, and with `id`
plus `recovery` when a compilation ID is known.

The feature recipes are in [features/README.md](features/README.md).

## Evidence

For UI steps, save `screen.sh LABEL` after each action and pair it with an
`observe.sh` read where the screen alone is ambiguous (selected buffer, DB
rows).

Wrap each CLI proving step in `capture.sh LABEL COMMAND...`. It writes
`$VERIFY_EVIDENCE/LABEL.cmd`, `.out`, `.err` and `.status`, and still prints
stdout so you can chain on it:

```bash
$S/capture.sh run-hello $S/cli.sh run --directory "$VERIFY_ROOT" --command 'printf hello'
```

Proof standards:
- Drive the surface the way its user does: keystrokes for the UI, the CLI for
  agents. Calling package functions through `observe.sh` is not proof.
- Capture the action and the resulting state: the `start` reply, then the
  `wait` reply, then an independent `get` read of the persisted record.
- Check side effects outside the reply: the DB row via `get` or `observe.sh`,
  and the selected window via `observe.sh` for display claims.
- No mocks. The fixture is the production module on a temporary DB.

`$VERIFY_EVIDENCE` lives under `.verify/`, which git ignores, and survives
cleanup. `cleanup.sh` also copies `server.log` there.

## Cleanup

```bash
.claude/skills/verify/scripts/cleanup.sh
```

Kills the private tmux server (for `--tui`) and the pid that `launch.sh`
recorded (TERM, then KILL after 5 s),
copies the server log into `$VERIFY_EVIDENCE`, and deletes `$VERIFY_ROOT`. It
refuses any root that isn't `/tmp/ch-verify.??????` with an `owned-fixture`
marker. It never deletes evidence. No operator records are changed by a drive,
because the server never opens the user's database or server socket. Run
cleanup after every failed attempt too.

## Gotchas

- The helper scripts and recipes use `jq`, which comes from mise
  (`jq = "1.8.2"` in `mise.toml`); the CLI itself needs only `emacs`. If `jq`
  fails with a mise "shim fallback recursion" error, run `mise install` in the
  repo.
- `doctor.sh` fails with "server loaded …/compilation-history-agent.elc" when
  compiled files sit in the checkout; `mise run check` (melpa-check) leaves
  them. `load` prefers them over the sources, so delete the checkout's `*.elc`
  and relaunch.
- `keys.sh` takes tmux key names: `Space`, `Enter`, `Tab`, `Escape`, `C-x`,
  `M-<`. A name tmux doesn't know, such as Emacs's `SPC`, is typed as letters.
- The view's `#` header is the window header line, not buffer text; buffer
  line 1 is the newest record.
- `--display` and `show` reuse a window already showing the build, split the
  frame when they can, otherwise use another window of the selected frame.
  `display_unavailable` means none of those worked, for example an
  unsplittable frame with no other window; treat it as a finding.
- Builds run with the **server's** environment and `default-directory`, not
  your shell's. Always pass `--directory "$VERIFY_ROOT"` or a subdirectory.
- Each `cli.sh` call that needs an ID takes it from an earlier reply. Keep IDs
  from `start` replies; never re-run `start` to get one.
