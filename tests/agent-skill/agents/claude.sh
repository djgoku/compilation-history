#!/usr/bin/env bash
# Agent adapter: run Claude Code headless in PROJECT_DIR on PROMPT and write
# OUT_DIR/result.json with the shape every adapter produces:
#   {final_text, skill_loaded, denied_commands, bash_commands, cost_usd, is_error}
# The caller supplies the agent's environment; only listed variables pass.
# Allowed: the CLI and read-only inspection. Anything else is refused and lands
# in denied_commands, which fails the scenario. /tmp is added only because
# Claude Code refuses `cd` outside the project even when cd is allowed.
set -euo pipefail
[ "$#" -eq 3 ] || { printf 'Usage: claude.sh PROJECT_DIR PROMPT OUT_DIR\n' >&2; exit 2; }
project=$1 prompt=$2 out=$3
claude=${CH_EVAL_CLAUDE:-$(command -v claude)}
cd "$project"
status=0
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TERM=dumb LANG=en_US.UTF-8 \
  PATH="$CH_EVAL_AGENT_PATH" \
  COMPILATION_HISTORY_AGENT_SERVER="$COMPILATION_HISTORY_AGENT_SERVER" \
  CH_EVAL_CALL_LOG="$CH_EVAL_CALL_LOG" CH_EVAL_REAL_CLI="$CH_EVAL_REAL_CLI" \
  "$claude" -p "$prompt" \
    --model "${CH_EVAL_MODEL:-sonnet}" \
    --setting-sources project --settings '{"autoMemoryEnabled":false}' \
    --strict-mcp-config --no-session-persistence \
    --tools Bash,Skill,Read,Glob,Grep --add-dir /tmp "$(cd -P /tmp && pwd)" \
    --allowedTools 'Bash(compilation-history-agent *)' Read Glob Grep \
      'Bash(cd *)' 'Bash(cat *)' 'Bash(ls *)' 'Bash(head *)' 'Bash(tail *)' 'Bash(pwd)' \
    --permission-mode dontAsk \
    --output-format stream-json --verbose \
  > "$out/transcript.jsonl" 2> "$out/agent.err" || status=$?
jq -s --argjson status "$status" '
  (map(select(.type == "result")) | last) as $result
  | [ .[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") ] as $uses
  | { final_text: ($result.result // ""),
      skill_loaded: any($uses[]; .name == "Skill" and (.input.skill // "" | test("compilation-history"))),
      denied_commands: [ $result.permission_denials[]? | .tool_input.command // .tool_name ],
      bash_commands: [ $uses[] | select(.name == "Bash") | .input.command ],
      cost_usd: ($result.total_cost_usd // 0),
      is_error: ($result == null or $result.is_error or $status != 0) }
' "$out/transcript.jsonl" > "$out/result.json"
