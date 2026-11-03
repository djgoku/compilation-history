#!/usr/bin/env bash
# Real server tests use only a newly created, explicitly selected test server.
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
for tool in emacs emacsclient jq; do
  command -v "$tool" >/dev/null || { printf 'Missing required test tool: %s\n' "$tool" >&2; exit 1; }
done
test_root=$(mktemp -d /tmp/ch-agent.XXXXXX)
printf 'owned\n' > "$test_root/owned-fixture"
server_pid= watchdog_pid= timer_pid=
children=()
cleanup() {
  status=$?
  trap - EXIT TERM INT
  if [ "$status" -ne 0 ]; then
    printf 'Agent server test failed; server log:\n' >&2
    [ ! -f "$test_root/server.log" ] || tail -80 "$test_root/server.log" >&2
  fi
  [ -z "$watchdog_pid" ] || kill "$watchdog_pid" 2>/dev/null || true
  for pid in ${children[@]+"${children[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  case "$test_root" in
    /tmp/ch-agent.??????) [ ! -f "$test_root/owned-fixture" ] || rm -r -- "$test_root" ;;
    *) printf 'Refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 124' TERM INT
trap 'printf "FAIL server test at line %s\n" "$LINENO" >&2' ERR
driver_pid=$$
(
  trap 'kill "$timer_pid" 2>/dev/null || true; exit 0' TERM INT
  sleep 180 & timer_pid=$!
  wait "$timer_pid"
  printf 'Agent matrix deadline exceeded\n' >&2
  kill -TERM "$driver_pid"
) & watchdog_pid=$!
mkfifo "$test_root/ready"
mkfifo "$test_root/events"
exec 3<> "$test_root/ready"
exec 4<> "$test_root/events"
CH_AGENT_TEST_ROOT="$test_root" emacs --batch -Q -L "$project_dir" \
  -l "$project_dir/tests/compilation-history-agent-server-fixture.el" \
  > "$test_root/server.log" 2>&1 & server_pid=$!
if ! IFS= read -r -t 15 -u 3 ready || [ "$ready" != ready ]; then
  printf 'Isolated server readiness deadline exceeded\n' >&2
  exit 1
fi
exec 3>&-
test_socket="$test_root/emacs-server/agent-test"
client=(emacsclient --alternate-editor=false "--socket-name=$test_socket" --eval)
cli=("$project_dir/bin/compilation-history-agent" --server "$test_socket")
event() {
  IFS= read -r -t 15 -u 4 received && [ "$received" = "$1" ] || {
    printf 'Expected event %s; received %s\n' "$1" "${received:-nothing}" >&2; exit 1;
  }
}
check() { jq -e "$1" "$2" >/dev/null || { printf 'FAIL %s: %s\n' "$2" "$1" >&2; exit 1; }; }

# Exercise the actual get gateway with large persisted values before relying on
# shell response handling.  Fixture configuration, never production, owns this DB.
for size in ${CH_AGENT_PAYLOAD_SIZES:-1048576 8388608}; do
  case "$size" in *[!0-9]*|'') printf 'Invalid test payload size\n' >&2; exit 1 ;; esac
  probe_started=$SECONDS
  "${client[@]}" "(progn (compilation-history--insert-compilation-record (make-compilation-history :record-id \"20260903T120000000001\" :command \"payload probe\" :compile-directory default-directory :buffer-name \"*payload*\" :system-info (list :os system-type))) (compilation-history--update-compilation-record \"20260903T120000000001\" 0 (make-string $size ?x)))" >/dev/null
  storage_seconds=$((SECONDS - probe_started))
  "${cli[@]}" get 20260903T120000000001 --full \
    | jq -e --argjson size "$size" '.protocol_version == 1 and (.output | length) == $size' >/dev/null
  printf 'PASS real CLI payload: %s bytes (%ss storage, %ss retrieval)\n' "$size" "$storage_seconds" "$((SECONDS - probe_started - storage_seconds))"
  "${client[@]}" '(compilation-history--with-db db (sqlite-execute db "DELETE FROM compilations WHERE id = ?" ["20260903T120000000001"]))' >/dev/null
done

# One early real start -> blocking wait -> persisted get vertical slice.
"${cli[@]}" doctor > "$test_root/doctor"
check '.interface_enabled and .history_enabled and (.socket | startswith("/"))' "$test_root/doctor"
socket=$(jq -r '.socket' "$test_root/doctor")
runtime=$(dirname "$socket")
"${cli[@]}" run --directory "$test_root" --command "printf 'vertical-λ-🚀\\n'" > "$test_root/vertical"
check '.state == "succeeded" and (.tail | contains("vertical-λ-🚀"))' "$test_root/vertical"
vertical_id=$(jq -r '.id' "$test_root/vertical")
"${cli[@]}" get "$vertical_id" > "$test_root/vertical-get"
check '.exit_code == 0 and (.tail | contains("vertical-λ-🚀"))' "$test_root/vertical-get"
printf 'PASS real CLI vertical slice\n'

"${cli[@]}" list --search 'vertical-λ' --limit 5 > "$test_root/list"
jq -e --arg id "$vertical_id" '.total == 1 and .records[0].id == $id and .records[0].state == "succeeded" and (.records[0] | has("tail") | not)' "$test_root/list" >/dev/null
"${cli[@]}" list --limit 1 > "$test_root/list-newest"
check ".records[0].id == \"$vertical_id\" and (.records | length) == 1" "$test_root/list-newest"
printf 'PASS real CLI list and search\n'

command_value=$'printf \'$HOME "λ" 🚀 \\\\ \'\n# $(touch SHOULD_NOT_EXIST)'
"${cli[@]}" start --directory "$test_root" --command "$command_value" > "$test_root/hostile"
jq -e --arg command "$command_value" '.command == $command' "$test_root/hostile" >/dev/null
command_value=$(jq -nr '"printf " + ("λ" * 8192)')
"${cli[@]}" start --directory "$test_root" --command "$command_value" > "$test_root/long"
jq -e --arg command "$command_value" '.command == $command' "$test_root/long" >/dev/null
"${cli[@]}" wait "$(jq -r .id "$test_root/hostile")" > /dev/null
"${cli[@]}" wait "$(jq -r .id "$test_root/long")" > /dev/null
[ ! -e SHOULD_NOT_EXIST ] && [ ! -e "$test_root/SHOULD_NOT_EXIST" ]
COMPILATION_HISTORY_AGENT_SERVER="$test_root/emacs-server/missing" \
  "$project_dir/bin/compilation-history-agent" --server "$test_socket" doctor > "$test_root/selector"
jq -e --arg socket "$test_socket" '.server_selector == $socket' "$test_root/selector" >/dev/null
COMPILATION_HISTORY_AGENT_SERVER="$test_socket" "$project_dir/bin/compilation-history-agent" doctor > "$test_root/env-selector"
jq -e --arg socket "$test_socket" '.server_selector == $socket and .interface_enabled' "$test_root/env-selector" >/dev/null
printf 'PASS commands round-trip verbatim; --server overrides the environment\n'

server_dir=$(dirname "$test_socket")
emacs --batch -Q --eval "(progn (make-network-process :name \"silent\" :server t :family 'local :service \"$server_dir/silent\") (while t (sleep-for 1)))" & silent=$!; children+=("$silent")
emacs --batch -Q --eval "(progn (require 'server) (setq server-socket-dir \"$server_dir\" server-name \"bare\") (server-start) (while t (sleep-for 1)))" & bare=$!; children+=("$bare")
for _ in $(seq 50); do [ -S "$server_dir/bare" ] && [ -S "$server_dir/silent" ] && break; sleep 0.1; done
status=0
"$project_dir/bin/compilation-history-agent" --server "$server_dir/bare" doctor > "$test_root/bare-doctor" || status=$?
[ "$status" -ne 0 ]
jq -e --arg socket "$test_socket" '.error == "interface_unavailable" and .loaded_servers == [$socket]' "$test_root/bare-doctor" >/dev/null ||
  { printf 'FAIL bare doctor: %s\n' "$(< "$test_root/bare-doctor")" >&2; exit 1; }
status=0
"$project_dir/bin/compilation-history-agent" --server "$server_dir/missing" doctor > "$test_root/missing-doctor" 2>/dev/null || status=$?
[ "$status" -ne 0 ]
jq -e --arg socket "$test_socket" '.error == "server_unavailable" and .loaded_servers == [$socket]' "$test_root/missing-doctor" >/dev/null ||
  { printf 'FAIL missing doctor: %s\n' "$(< "$test_root/missing-doctor")" >&2; exit 1; }
kill "$silent" "$bare"; wait "$silent" "$bare" 2>/dev/null || true
children=()
printf 'PASS doctor names sibling servers that have the module\n'

mkdir "$test_root/A" "$test_root/B" "$test_root/C"
"${cli[@]}" start --directory "$test_root/A" --command "i=0; while [ \$i -lt 2000 ]; do printf 'A-noise\\n'; i=\$((i+1)); done; sleep 3; printf 'A-done\\n'" > "$test_root/A-start"
"${cli[@]}" start --directory "$test_root/B" --command "printf 'B-done\\n'; exit 7" > "$test_root/B-start"
"${cli[@]}" start --directory "$test_root/C" --command "printf 'C-start\\n'; sleep 5; printf 'C-done\\n'" > "$test_root/C-start"
a=$(jq -r '.id' "$test_root/A-start"); b=$(jq -r '.id' "$test_root/B-start"); c=$(jq -r '.id' "$test_root/C-start")
[ "$a" != "$b" ] && [ "$a" != "$c" ] && [ "$b" != "$c" ]
"${client[@]}" '(advice-add (quote compilation-history-agent--filter) :after (quote ch-agent-test-client-event))' >/dev/null
"${cli[@]}" wait "$a" > "$test_root/A-result" & a_wait=$!; children+=("$a_wait")
"${cli[@]}" wait "$a" > "$test_root/A-second" & a_second=$!; children+=("$a_second")
"${cli[@]}" wait "$c" > "$test_root/C-disconnected" & disconnected=$!; children+=("$disconnected")
event client; event client; event client
kill "$disconnected"; wait "$disconnected" 2>/dev/null || true
TIMEFORMAT='%3R'
{ time "${client[@]}" '(+ 20 22)' > "$test_root/responsive-value"; } 2> "$test_root/responsive-seconds"
[ "$(< "$test_root/responsive-value")" = 42 ]
jq -e '. < 2' "$test_root/responsive-seconds" >/dev/null
printf 'PASS Emacs request while three jobs wait: %ss\n' "$(< "$test_root/responsive-seconds")"
"${cli[@]}" wait "$c" > "$test_root/C-result" & c_wait=$!; children+=("$c_wait")
event client
wait "$a_wait"; wait "$a_second"; wait "$c_wait"
"${cli[@]}" wait "$b" > "$test_root/B-result"
"${cli[@]}" wait "$b" > "$test_root/B-second"
check '.state == "succeeded" and .exit_code == 0 and .tail_truncated and (.tail | contains("\nA-done\n")) and (.tail | contains("\nB-done\n") | not)' "$test_root/A-result"
check '.state == "failed" and .exit_code == 7 and (.tail | contains("\nB-done\n"))' "$test_root/B-result"
check '.state == "succeeded" and .exit_code == 0 and (.tail | contains("\nC-done\n"))' "$test_root/C-result"
cmp "$test_root/A-result" "$test_root/A-second"
cmp "$test_root/B-result" "$test_root/B-second"
"${client[@]}" '(unless (cl-every (lambda (buffer) (not (local-variable-p (quote compilation-history-db-file) buffer))) (buffer-list)) (error "Buffer-local database override"))' >/dev/null
# One persisted query per ID after the wait-only measurement, using public get.
for pair in "A:$a" "B:$b" "C:$c"; do
  label=${pair%%:*}; record_id=${pair#*:}
  "${cli[@]}" get "$record_id" > "$test_root/$label-get"
  jq -e -s '.[0].id == .[1].id and .[0].state == .[1].state and .[0].exit_code == .[1].exit_code and .[0].directory == .[1].directory' "$test_root/$label-result" "$test_root/$label-get" >/dev/null
done
printf 'PASS three-job matrix, repeated waiters, disconnect, responsive server\n'
children=()
"${client[@]}" '(advice-remove (quote compilation-history-agent--filter) (quote ch-agent-test-client-event))' >/dev/null

# Three independent clients, not a Lisp loop of starts.
"${cli[@]}" run --directory "$test_root" --command 'printf instant-one' > "$test_root/instant-one" & first=$!; children+=("$first")
"${cli[@]}" run --directory "$test_root" --command 'printf instant-two' > "$test_root/instant-two" & second=$!; children+=("$second")
"${cli[@]}" run --directory "$test_root" --command 'printf instant-three' > "$test_root/instant-three" & third=$!; children+=("$third")
wait "$first"; wait "$second"; wait "$third"
jq -e -s 'map(.id) | unique | length == 3' "$test_root/instant-one" "$test_root/instant-two" "$test_root/instant-three" >/dev/null
for label in one two three; do check ".state == \"succeeded\" and (.tail | contains(\"instant-$label\"))" "$test_root/instant-$label"; done
children=()
printf 'PASS near-simultaneous instant clients\n'

# Change only the fixture server configuration; production must follow it.
"${client[@]}" '(setq compilation-history-db-file (expand-file-name "second.db" temporary-file-directory) compilation-history-agent-retention-seconds 0.5)' >/dev/null
"${client[@]}" '(advice-add (quote compilation-history-agent--expire) :after (quote ch-agent-test-expired-event))' >/dev/null
"${cli[@]}" run --directory "$test_root" --command 'printf expiry-kept' > "$test_root/expiry-result"
expired_id=$(jq -r '.id' "$test_root/expiry-result")
event expired
status=0; "${cli[@]}" wait "$expired_id" > "$test_root/expired" || status=$?
[ "$status" -ne 0 ]; check '.error == "wait_unavailable"' "$test_root/expired"
"${cli[@]}" get "$expired_id" > "$test_root/expired-get"
check '.state == "succeeded" and (.tail | contains("expiry-kept"))' "$test_root/expired-get"
"${cli[@]}" show "$expired_id" > "$test_root/expired-show"
check '.display.visible' "$test_root/expired-show"
"${cli[@]}" doctor > "$test_root/second-doctor"
check '.database | endswith("/second.db")' "$test_root/second-doctor"
"${client[@]}" '(progn (setq compilation-history-agent-retention-seconds 3600) (advice-remove (quote compilation-history-agent--expire) (quote ch-agent-test-expired-event)) (advice-add (quote compilation-history-agent--filter) :after (quote ch-agent-test-client-event)))' >/dev/null
printf 'PASS expiry preserves history/buffer; server-configured database is followed\n'

"${cli[@]}" start --directory "$test_root" --command "sleep 2; printf 'disable-survived'" > "$test_root/disable-start"
disable_id=$(jq -r '.id' "$test_root/disable-start")
"${cli[@]}" wait "$disable_id" > "$test_root/disable-result" & disabled_wait=$!; children+=("$disabled_wait")
event client
"${client[@]}" "(progn (with-current-buffer (compilation-history-agent--find-buffer \"$disable_id\") (add-hook 'compilation-finish-functions #'ch-agent-test-finished-event 95 t)) (compilation-history-agent-mode -1) (unless (process-live-p (get-buffer-process (compilation-history-agent--find-buffer \"$disable_id\"))) (error \"Disable stopped compilation\")))" >/dev/null
status=0; wait "$disabled_wait" || status=$?
[ "$status" -ne 0 ]; check '.error == "interface_disabled"' "$test_root/disable-result"
[ ! -d "$runtime" ]
event finished
"${cli[@]}" get "$disable_id" > "$test_root/disable-get"
check '.state == "succeeded" and (.tail | contains("disable-survived"))' "$test_root/disable-get"
"${cli[@]}" show "$disable_id" > "$test_root/disable-show" || { cat "$test_root/disable-show" >&2; exit 1; }
check '.display.visible' "$test_root/disable-show"
"${client[@]}" '(unless (and (= 0 (hash-table-count compilation-history-agent--jobs)) (not compilation-history-agent--runtime-directory)) (error "Interface resources survived disable"))' >/dev/null
printf 'PASS disable unblocks waiter without cancelling compilation\n'
children=()

# Abrupt death is confined to this owned server; the CLI must report transport
# failure and never restart it.  No compilation is running during this case.
"${client[@]}" '(compilation-history-agent-mode 1)' >/dev/null
"${cli[@]}" start --directory "$test_root" --command true > "$test_root/death-start"
death_id=$(jq -r '.id' "$test_root/death-start")
"${cli[@]}" wait "$death_id" > /dev/null
"${client[@]}" "(setf (compilation-history-agent--job-result (gethash \"$death_id\" compilation-history-agent--jobs)) nil)" >/dev/null
"${cli[@]}" wait "$death_id" > "$test_root/death-result" & death_wait=$!; children+=("$death_wait")
event client
kill -KILL "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=
status=0; wait "$death_wait" || status=$?
[ "$status" -ne 0 ]; check '.error == "server_disconnected" and .recovery' "$test_root/death-result"
printf 'PASS owned-server death unblocks wait without restart\n'
printf 'PASS isolated server matrix\n'
