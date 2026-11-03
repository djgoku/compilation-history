#!/usr/bin/env bash
# End-to-end evaluation of skills/compilation-history/SKILL.md: a real agent,
# given only that skill and the CLI, performs each scenario's task against a
# disposable Emacs server. Pass/fail comes from the CLI call log, the agent's
# denied commands, and the history database, never from judging prose.
#
#   tests/agent-skill/run.sh [SCENARIO...]
#   CH_EVAL_AGENT=claude CH_EVAL_MODEL=sonnet CH_EVAL_REPEAT=1 CH_EVAL_TIMEOUT=300
#   CH_EVAL_SKILL=path/to/SKILL.md evaluates an alternative skill text.
#   CH_EVAL_ROOT=/tmp/ch-verify.XXXXXX reuses a running verify launch (for
#   example `launch.sh --tui` you are watching) instead of a fresh server.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
here=$repo/tests/agent-skill
verify=$repo/.claude/skills/verify/scripts
agent=${CH_EVAL_AGENT:-claude}
adapter=$here/agents/$agent.sh
[ -x "$adapter" ] || { printf 'No adapter for agent %s at %s\n' "$agent" "$adapter" >&2; exit 2; }
out_root=$repo/.verify/agent-skill/$(date +%Y%m%dT%H%M%S)-$agent
mkdir -p "$out_root"

resolve() { (cd "$repo" && mise which "$1" 2>/dev/null) || command -v "$1"; }
tool_path=
for tool in jq emacs; do
  bin=$(resolve "$tool") || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 1; }
  tool_path=$tool_path:$(dirname "$bin")
done
tool_path=$tool_path:/usr/bin:/bin
export PATH="$(dirname "$(resolve jq)"):$PATH"

# --- Call log queries.  Each end line is one finished CLI call. ---
calls() {  # calls [OP] -> one JSON object per finished call: {op, id, status, index}
  jq -c --arg op "${1:-}" '
    select(.phase == "end")
    | (.argv | if .[0] == "--server" then .[2:] else . end) as $a
    | {op: $a[0], id: ($a[1] // null), status, argv}
    | select($op == "" or .op == $op)' "$log"
}
count() { calls "$1" | wc -l | tr -d ' '; }
line_of() {  # line_of PHASE OP FIRST|LAST -> 1-based log line, or 0
  jq -s --arg phase "$1" --arg op "$2" --arg which "$3" '
    [ to_entries[] | select(.value.phase == $phase)
      | select((.value.argv | if .[0] == "--server" then .[2:] else . end)[0] == $op)
      | .key + 1 ] | if length == 0 then 0 elif $which == "FIRST" then first else last end' "$log"
}
db_ids() {
  "$verify/observe.sh" '(mapconcat (function car) (compilation-history--with-db db (sqlite-select db "SELECT id FROM compilations ORDER BY id")) " ")' | jq -r .
}
final_text() { jq -r .final_text "$out/result.json"; }

failures=()
check() {  # check DESCRIPTION COMMAND... ; records a failure instead of exiting
  local description=$1; shift
  if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$description"
  else printf '  FAIL  %s\n' "$description"; failures+=("$scenario: $description"); fi
}
eq() { [ "$1" = "$2" ]; }
le() { [ "$1" -le "$2" ]; }
between() { [ "$2" -le "$1" ] && [ "$1" -le "$3" ]; }
before() { [ "$1" -gt 0 ] && [ "$2" -gt 0 ] && [ "$1" -lt "$2" ]; }
mentions() { final_text | grep -qF -- "$1"; }
mentions_re() { final_text | grep -qiE -- "$1"; }
true_in_result() { [ "$(jq -r "$1" "$out/result.json")" = true ]; }

common_checks() {  # common_checks MAX_DOCTOR EXPECTED_ROWS
  check 'agent finished without error' true_in_result '.is_error | not'
  check 'agent loaded the compilation-history skill' true_in_result .skill_loaded
  check 'agent attempted no commands outside the CLI' eq "$(jq '.denied_commands | length' "$out/result.json")" 0
  check 'doctor ran first' eq "$(calls | head -1 | jq -r .op)" doctor
  check "doctor ran at most $1 time(s)" le "$(count doctor)" "$1"
  check 'no display was requested' eq "$(calls | jq -s 'map(select(.op == "show" or (.argv | index("--display")) or (.argv | index("--select")))) | length')" 0
  check "history has exactly $2 record(s)" eq "$(wc -w <<< "$ids" | tr -d ' ')" "$2"
}

# --- Scenarios: setup_NAME writes files into $work; prompt_NAME prints the
#     task; during_NAME (optional) acts while the agent runs; checks_NAME scores.

setup_single_failing_build() {
  printf '#!/bin/sh\necho BUILD-MARKER-41\nexit 3\n' > "$work/build.sh"; chmod +x "$work/build.sh"
}
prompt_single_failing_build() {
  printf 'Use compilation-history to run `./build.sh` in %s. Tell me the compilation ID and whether the build passed.' "$work"
}
checks_single_failing_build() {
  common_checks 1 1
  check 'exactly one build was started' eq $(( $(count start) + $(count run) )) 1
  check 'the result was collected with wait or run' between $(( $(count wait) + $(count run) )) 1 2
  check 'get was not used to poll' le "$(count get)" 1
  check 'every CLI call succeeded' eq "$(calls | jq -s 'map(select(.status != 0)) | length')" 0
  check 'answer names the compilation ID' mentions "$ids"
  check 'answer reports the failure' mentions_re 'fail|exit(ed)?( with)?( code)? ?:? ?3'
}

setup_two_concurrent_builds() {
  printf '#!/bin/sh\nsleep 3\necho A-DONE\n' > "$work/a.sh"
  printf '#!/bin/sh\nsleep 3\necho B-DONE\nexit 1\n' > "$work/b.sh"
  chmod +x "$work/a.sh" "$work/b.sh"
}
prompt_two_concurrent_builds() {
  printf 'Use compilation-history to run `./a.sh` and `./b.sh` in %s at the same time, not one after the other. Tell me each compilation ID and whether each build passed.' "$work"
}
checks_two_concurrent_builds() {
  common_checks 1 2
  check 'both builds were started with start, not run' eq "$(count start):$(count run)" 2:0
  check 'both starts finished before the first wait began' before "$(line_of end start LAST)" "$(line_of begin wait FIRST)"
  check 'each build was waited on' eq "$(calls wait | jq -r .id | sort -u | tr '\n' ' ' | sed 's/ $//')" "$ids"
  check 'get was not used to poll' le "$(count get)" 2
  check 'answer names both compilation IDs' bash -c 'for id in $1; do grep -qF -- "$id" <<< "$2" || exit 1; done' _ "$ids" "$(final_text)"
}

setup_recovery_after_disable() {
  # Runs until the harness releases it, so the agent is always mid-wait when
  # the interface goes away, however long it takes to call wait.
  printf '#!/bin/sh\ni=0\nuntil [ -f %s/release ] || [ $i -ge 600 ]; do sleep 0.2; i=$((i+1)); done\necho SLOW-DONE\n' \
    "$VERIFY_ROOT" > "$work/slow.sh"
  chmod +x "$work/slow.sh"
}
prompt_recovery_after_disable() {
  printf 'Use compilation-history to run `./slow.sh` in %s and tell me how it finished.' "$work"
}
during_recovery_after_disable() {
  # Disable the interface once the agent is blocked waiting, as a user would.
  local deadline=$((SECONDS + 120))
  until grep -q '"phase":"begin","argv":\[[^]]*"\(wait\|run\)"' "$log" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 0
    sleep 0.2
  done
  sleep 1
  "$verify/observe.sh" '(compilation-history-agent-mode -1)' >/dev/null
  printf 'disabled\n' > "$out/during.done"
  touch "$VERIFY_ROOT/release"
}
checks_recovery_after_disable() {
  common_checks 2 1
  check 'the interface was disabled during a wait' test -f "$out/during.done"
  check 'exactly one build was started' eq $(( $(count start) + $(count run) )) 1
  check 'the blocked wait reported a failure' eq "$(calls | jq -s '[.[] | select(.op == "wait" or .op == "run")] | first | .status != 0')" true
  check 'no further waits after the failure' eq $(( $(count wait) + $(count run) )) 1
  check 'recovery used get once or twice, not a polling loop' between "$(count get)" 1 2
  check 'answer names the compilation ID' mentions "$ids"
}

setup_find_earlier_build() {
  # Seeded oldest first; the newest lint failed, an older one passed, and a
  # newer non-lint record sits on top.
  local seed
  for seed in '20260901T100000000001 make lint 0' '20260901T110000000002 make lint 2' \
              '20260901T120000000003 make test 0'; do
    set -- $seed
    "$verify/observe.sh" "(progn (compilation-history--insert-compilation-record (make-compilation-history :record-id \"$1\" :command \"$2 $3\" :compile-directory \"$work/\" :buffer-name \"*seed*\" :system-info (list :os system-type))) (compilation-history--update-compilation-record \"$1\" $4 \"SEED-OUTPUT $4\"))" >/dev/null
  done
}
prompt_find_earlier_build() {
  printf 'Did the most recent `make lint` compilation in %s pass? Use compilation-history and tell me its compilation ID.' "$work"
}
checks_find_earlier_build() {
  common_checks 1 3
  check 'no build was started' eq $(( $(count start) + $(count run) )) 0
  check 'list was used to find the record, once or twice' between "$(count list)" 1 2
  check 'get was not used to poll' le "$(count get)" 1
  check 'answer names the newest lint ID' mentions 20260901T110000000002
  check 'answer reports the failure' mentions_re 'fail|exit(ed)?( with)?( code)? ?:? ?2'
}

scenarios=(single_failing_build two_concurrent_builds recovery_after_disable find_earlier_build)
[ "$#" -eq 0 ] || scenarios=("$@")
total_cost=0
for round in $(seq 1 "${CH_EVAL_REPEAT:-1}"); do
  for name in "${scenarios[@]}"; do
    scenario="$name#$round"
    out=$out_root/$name-$round; mkdir -p "$out"
    printf '%s\n' "$scenario"
    if [ -n "${CH_EVAL_ROOT:-}" ]; then
      export VERIFY_ROOT=$CH_EVAL_ROOT
      "$verify/doctor.sh" >/dev/null || { printf 'CH_EVAL_ROOT is not a healthy verify launch\n' >&2; exit 1; }
      rm -f "$VERIFY_ROOT/release"
    else
      eval "$("$verify/launch.sh")"
    fi
    baseline=$(db_ids)
    work=$VERIFY_ROOT/work log=$out/calls.jsonl; : > "$log"
    mkdir -p "$work/.claude/skills/compilation-history" "$VERIFY_ROOT/eval-bin"
    cp "${CH_EVAL_SKILL:-$repo/skills/compilation-history/SKILL.md}" "$work/.claude/skills/compilation-history/SKILL.md"
    ln -sf "$here/cli-logger.sh" "$VERIFY_ROOT/eval-bin/compilation-history-agent"
    "setup_$name"
    prompt=$("prompt_$name"); printf '%s\n' "$prompt" > "$out/prompt.txt"
    during_pid=
    if declare -F "during_$name" >/dev/null; then "during_$name" & during_pid=$!; fi
    CH_EVAL_AGENT_PATH=$VERIFY_ROOT/eval-bin$tool_path \
      COMPILATION_HISTORY_AGENT_SERVER=$VERIFY_ROOT/emacs-server/agent-test \
      CH_EVAL_CALL_LOG=$log CH_EVAL_REAL_CLI=$repo/bin/compilation-history-agent \
      "$adapter" "$work" "$prompt" "$out" & agent_pid=$!
    (
      trap 'kill "$timer" 2>/dev/null; exit 0' TERM
      sleep "${CH_EVAL_TIMEOUT:-300}" & timer=$!
      wait "$timer" && kill -TERM "$agent_pid" 2>/dev/null
    ) >/dev/null 2>&1 & watchdog=$!
    wait "$agent_pid" || printf '  (agent adapter exited %s)\n' "$?"
    kill "$watchdog" 2>/dev/null || true
    [ -z "$during_pid" ] || kill "$during_pid" 2>/dev/null || true
    [ -f "$out/result.json" ] || printf '{"final_text":"","skill_loaded":false,"denied_commands":["<no result>"],"cost_usd":0,"is_error":true}\n' > "$out/result.json"
    ids=$(comm -13 <(tr ' ' '\n' <<< "$baseline" | sort) <(db_ids | tr ' ' '\n' | sort) | tr '\n' ' ' | sed 's/ $//')
    "checks_$name"
    total_cost=$(jq -n --argjson a "$total_cost" --argjson b "$(jq .cost_usd "$out/result.json")" '$a + $b')
    if [ -n "${CH_EVAL_ROOT:-}" ]; then
      "$verify/observe.sh" '(compilation-history-agent-mode 1)' >/dev/null
    else
      VERIFY_EVIDENCE=$out "$verify/cleanup.sh" >/dev/null
    fi
  done
done

printf '\nEvidence: %s\nAgent: %s, model: %s, cost: $%s\n' "$out_root" "$agent" "${CH_EVAL_MODEL:-sonnet}" "$total_cost"
if [ "${#failures[@]}" -gt 0 ]; then
  printf '%s failed check(s):\n' "${#failures[@]}"; printf '  %s\n' "${failures[@]}"
  exit 1
fi
printf 'All agent-skill checks passed.\n'
