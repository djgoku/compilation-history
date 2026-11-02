# Using compilation-history with coding agents

The repository ships one portable instruction package:
[`skills/compilation-history/SKILL.md`](../skills/compilation-history/SKILL.md).
It teaches agents to use the existing CLI; it is not another server, MCP bridge,
or database client. Keeping the skill in this repository does **not** install it
into every agent automatically.

## Set up the local interface first

Follow the [README's optional local agent interface setup](../README.org).
Keep your normal Emacs server, configuration, and history database. Put
`bin/compilation-history-agent` on the agent shell's `PATH`, or give the agent its
absolute path. Installing the Emacs package or copying the skill alone does not
install the CLI. The CLI is an Emacs Lisp script and needs only an `emacs` with
JSON support on the agent's `PATH`; the skill adds no runtime dependencies.

From the agent's actual shell environment, check:

```sh
compilation-history-agent doctor
```

If the default `server` socket is not your server, supply
`--server /absolute/path/to/socket` or set `COMPILATION_HISTORY_AGENT_SERVER` in
the environment inherited by the agent. Keep that selection for subsequent
commands. Successful doctor output is diagnostic: check `history_enabled`,
`interface_enabled`, and a non-null `socket` before starting builds. Doctor does not
enable them. Builds inherit **Emacs's** environment, not the agent shell's.

The agent needs permission to execute the requested command and reach the local
Emacs socket. Grant access using the host's normal permission controls; a skill
does not bypass them. Do not expose the socket or database to a network service
to make this work.

## Make the shared skill discoverable

Copy the entire `skills/compilation-history` directory into **one** appropriate
location below. Use a personal location to use it across your projects, or a
project location in the repository whose builds you want to track. Review any
existing same-named skill before replacing it. Keep copied versions in sync when
updating the CLI. Restart/reload the host and confirm it lists the skill.

| Local host | Personal skill folder | Project skill folder | How to confirm/use |
|---|---|---|---|
| Codex | `~/.agents/skills/compilation-history/` | `.agents/skills/compilation-history/` | CLI/IDE: `/skills`, then `$compilation-history` |
| Claude Code | `~/.claude/skills/compilation-history/` | `.claude/skills/compilation-history/` | `/compilation-history` |
| Kiro | `~/.kiro/skills/compilation-history/` | `.kiro/skills/compilation-history/` | `/compilation-history` |
| Gemini CLI | `~/.gemini/skills/compilation-history/` | `.gemini/skills/compilation-history/` | `/skills reload`, `/skills list`; ask to use compilation-history |

These are documentation-verified discovery paths, not a claim that every product
has been live-tested. Sources checked September 4, 2026:
[OpenAI skills](https://learn.chatgpt.com/docs/build-skills),
[Claude Code skills](https://code.claude.com/docs/en/skills),
[Kiro skills](https://kiro.dev/docs/skills/), and
[Gemini CLI skills](https://geminicli.com/docs/cli/using-agent-skills/).

Codex and Claude Code also document symlinked skill folders, useful for a stable
checkout. Do not link to a disposable worktree that you intend to remove.
Gemini CLI supports `~/.agents/skills/` and `.agents/skills/` aliases and
`gemini skills link /absolute/path/to/skills/compilation-history`; avoid installing
duplicate copies through multiple routes. See the linked host documentation.

For a Kiro custom agent, add the desired `skill://` resource to its existing
`resources` array (preserve its other settings), for example:

```json
"skill://~/.kiro/skills/compilation-history/SKILL.md"
```

Kiro documents this explicit resource configuration for custom agents.
[Kiro skill scope](https://kiro.dev/docs/skills/#skill-scope)

### ChatGPT and other environments

OpenAI documents standalone skills in the ChatGPT desktop app, with `@` selection
for installed skills; plugin-packaged skills also work across Chat/Work surfaces.
This repository supplies a standalone skill, **not** that plugin packaging.
Use the desktop skill controls available in your environment and confirm the
skill appears. [OpenAI skills](https://learn.chatgpt.com/docs/build-skills)

Discovery and execution are separate. In any host with an authorized local shell,
you can explicitly ask it to read the shared `SKILL.md` by its absolute path and
use the installed CLI. In a hosted ChatGPT, Claude, Kiro, or other session without
access to your machine, uploading the skill does not make your Emacs reachable.
Use a local coding session or run the suggested commands yourself. A remote
bridge would be separate work; this interface does not supply one.

## Ask for work

For example:

> Use compilation-history to run `make test` in `/absolute/project`. Keep the
> compilation ID and report the result. Leave my Emacs windows unchanged.

Or:

> Start these three independent commands in compilation-history before waiting
> for them. Show the lint compilation in Emacs without selecting its window.

The agent starts once, keeps each ID, waits on a socket, and summarizes the compact
result. If its terminal tool yields a running process, it resumes that process;
it does not repeatedly ask Emacs or SQLite whether the build is done. Only request
concurrent jobs when they can safely share their build directories/artifacts.

To reconnect later, supply the ID and the same server selector. After wait-result
expiry, `get ID` retrieves persisted history once. A partial record is not proof
of completion. Request `get ID --full` only when earlier output matters.

## Validation scope

The CLI and isolated-server tests cover the protocol and three-job concurrency.
`mise run check-agent-skill` runs a real agent with only the skill and the CLI
through build, concurrency and recovery scenarios and scores its CLI calls; see
[tests/agent-skill](../tests/agent-skill/README.md). It covers Claude Code today. Native discovery and end-to-end
execution in every listed product remain separate compatibility checks.
