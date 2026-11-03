# Agent skill evaluation

Checks that a real coding agent, given only `skills/compilation-history/SKILL.md`
and the `compilation-history-agent` CLI, does what the skill promises. Run it
after any change to the skill, the CLI, or `compilation-history-agent.el`:

```sh
mise run check-agent-skill                      # all scenarios, sonnet, once
mise run check-agent-skill two_concurrent_builds
CH_EVAL_MODEL=opus CH_EVAL_REPEAT=3 mise run check-agent-skill
CH_EVAL_SKILL=/path/to/draft/SKILL.md mise run check-agent-skill
CH_EVAL_ROOT=$VERIFY_ROOT mise run check-agent-skill   # reuse a running launch
```

`CH_EVAL_ROOT` points the eval at a verify launch that is already running,
such as a `launch.sh --tui` session you are attached to. It counts only the
history records each scenario creates, re-enables the interface after the
recovery scenario, and leaves the session running.

It needs an authenticated `claude` CLI and costs model calls (about $0.10 per
sonnet round of all three scenarios). It is not part of `mise run check`, which
CI runs without credentials.

## How a scenario runs

1. `.claude/skills/verify/scripts/launch.sh` starts a disposable Emacs server
   with a fresh history database.
2. The skill is copied into the scenario's project, and `cli-logger.sh` stands
   in for the CLI on the agent's PATH, logging every call before running the
   real one.
3. The agent adapter runs the scenario's prompt with a cleaned environment:
   no user settings, plugins, `CLAUDE.md` or MCP servers. Only the CLI and
   read-only inspection are allowed. Anything else is refused and recorded.
4. Checks read the call log, the adapter's `result.json` and the history
   database. Nothing judges the agent's prose except for the presence of IDs
   and the word "fail".

Evidence for every run is kept under `.verify/agent-skill/`.

## Scenarios

- `single_failing_build`: one start, collected by wait or run, no polling,
  answer names the ID and the failure.
- `two_concurrent_builds`: both builds started with `start` before the first
  `wait`, each waited on, both IDs reported.
- `recovery_after_disable`: the interface is disabled while the agent waits;
  the agent must not restart the build or wait again, and recovers with one
  or two `get` calls.
- `find_earlier_build`: three seeded records, no build to run; the agent
  finds the newest `make lint` with `list`, starts nothing, and reports that
  record's ID and failure.

Every scenario also requires: the skill was loaded, no refused commands,
`doctor` first and only once (twice allowed in recovery), no display commands,
and exactly the expected history records.

To add a scenario, define `setup_NAME`, `prompt_NAME`, `checks_NAME` and
optionally `during_NAME` in `run.sh` and add NAME to `scenarios`.

## Adding another agent

Write `agents/NAME.sh PROJECT_DIR PROMPT OUT_DIR` that runs the agent in
PROJECT_DIR with PATH set to `$CH_EVAL_AGENT_PATH` and passes through
`COMPILATION_HISTORY_AGENT_SERVER`, `CH_EVAL_CALL_LOG` and `CH_EVAL_REAL_CLI`.
It must write `OUT_DIR/result.json` with `final_text`, `skill_loaded`,
`denied_commands`, `bash_commands`, `cost_usd` and `is_error`. Then run with
`CH_EVAL_AGENT=NAME`.

## Why results can still vary

The checks are deterministic, but the agent is not. Each scenario is written so
that exactly one behavior is correct, and builds that must still be running at
a given moment block on a release file rather than a sleep. A failure on any
round is a real finding: either the skill is ambiguous or the agent ignored it.
Use `CH_EVAL_REPEAT` to measure how often.
