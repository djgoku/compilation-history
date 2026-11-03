# compilation-history agent verification map

This directory is the maintained source for verifying compilation-history from
both sides: what a user does in Emacs (compile, browse, search, recompile) and
what a shell agent does with `bin/compilation-history-agent`. Read the index,
then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `eval "$(.claude/skills/verify/scripts/launch.sh)"` for agent
  recipes, or `launch.sh --tui` for Emacs UI recipes, and export a fresh
  `VERIFY_EVIDENCE` per run, as `../SKILL.md` shows. CLI recipes also work
  against a `--tui` launch.
- `.claude/skills/verify/scripts/doctor.sh` prints `DOCTOR OK`.
- The server's history DB starts empty. Every recipe creates the compilations
  it needs.
- Never drive a server that this run did not launch.

## Driving conventions

- `S=.claude/skills/verify/scripts`. Run CLI actions as `$S/cli.sh <command>`.
- Wrap each proving step in `$S/capture.sh <feature>-<step> ...`.
- Pass `--directory "$VERIFY_ROOT"` to every `start` and `run`.
- Take IDs from `start` or `run` replies with `jq -r .id`.
- In `--tui` recipes, act only through `$S/keys.sh` and prove with
  `$S/screen.sh LABEL`; wait on screen text with `screen.sh --wait`, never a
  fixed sleep.
- Observe Emacs state only with `$S/observe.sh`.

## Proof and skip reporting

- CLI proof is the captured command, stdout, stderr and exit status.
- UI proof is the saved screen text after each user action.
- State proof pairs a CLI reply with an independent `get` or `observe.sh` read.
- Record the feature file and sub-feature ID next to each claim.
- Report an unreachable path with the attempted command and the unmet
  precondition. Do not count a different entry point as verifying it.

## Feature entry contract

Each feature file has an H1 title, one paragraph of user-visible behavior, then
exactly four H2 sections in this order: `Sub-features`,
`How to get to it (user POV)`, `Driving it with cli.sh` or
`Driving it with keys.sh`, `Gotchas`.

## Features

Emacs UI (`launch.sh --tui`):

- [Compile tracking](./compile-tracking.md) covers recording success, failure, killed and comint compiles.
- [History view](./history-view.md) covers listing, opening, preview, refresh, paging and quit.
- [Search](./search.md) covers plain, column, short-term, completion and clear.
- [Recompile](./recompile.md) covers rerunning from a history buffer.

Agent CLI (`launch.sh`):

- [Doctor](./doctor.md) covers health reporting with the interface on and off.
- [Run, start and wait](./run-and-wait.md) covers starting builds and blocking until they finish.
- [Get persisted history](./get.md) covers the compact tail, full output and recovery.
- [List and search history](./list.md) covers newest-first listing, paging, search and bad input.
- [Show a compilation](./show.md) covers displaying and selecting buffers.
- [Interface lifecycle](./interface-lifecycle.md) covers disable, re-enable, expiry, waits on unknown IDs and killed builds.
