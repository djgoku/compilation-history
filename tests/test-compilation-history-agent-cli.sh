#!/usr/bin/env bash
# CLI cases that need no Emacs server; tests/test-compilation-history-agent-server.sh
# covers every command against a real one.
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cli="$project_dir/bin/compilation-history-agent"
[ -x "$cli" ] || { printf 'FAIL: CLI executable is missing\n' >&2; exit 1; }
test_root=$(mktemp -d /tmp/ch-cli.XXXXXX)
trap 'rm -r -- "$test_root"' EXIT
id=20260903T120000000001
count=0
trap 'printf "FAIL CLI case %s at line %s\n" "$count" "$LINENO" >&2' ERR
run_case() {
  status=0
  "$cli" "$@" > "$test_root/out" 2> "$test_root/err" || status=$?
  count=$((count + 1))
}
assert_json() {
  jq -e -s "length == 1 and (.[0] | .protocol_version == 1 and ($1))" "$test_root/out" >/dev/null || {
    printf 'FAIL case %s: %s\n' "$count" "$1" >&2; cat "$test_root/out" "$test_root/err" >&2; exit 1; }
}
assert_status() { [ "$status" -eq "$1" ] || { printf 'FAIL case %s status: %s\n' "$count" "$status" >&2; cat "$test_root/out" "$test_root/err" >&2; exit 1; }; }
assert_invalid() { assert_status 1; assert_json '.error == "invalid_request"'; }

for command in doctor start run wait show get list; do
  run_case "$command" --unsupported; assert_invalid
done
run_case wait 'id") (kill-emacs)'; assert_invalid
run_case start --command true --directory /tmp --full; assert_invalid
run_case start --command true; assert_invalid
run_case get "$id" --select; assert_invalid
run_case show "$id" --full; assert_invalid
run_case wait "$id" --display; assert_invalid
run_case get "$id" extra; assert_invalid
run_case doctor "$id"; assert_invalid
run_case doctor --server ''; assert_invalid
run_case list "$id"; assert_invalid
run_case list --full; assert_invalid
run_case list --limit -1; assert_invalid
run_case list --limit 2x; assert_invalid
run_case list --search ''; assert_invalid
run_case get "$id" --search make; assert_invalid
run_case bogus; assert_invalid
run_case --version
assert_invalid; assert_json '.message == "Unknown option: --version"'
LC_ALL=C LANG=C run_case --λ-🚀
assert_invalid; assert_json '.message == "Unknown option: --λ-🚀"'

run_case get "$id" --help
assert_status 0; grep -q '^Usage: compilation-history-agent' "$test_root/out"

run_case --server "$test_root/no-such-socket" get "$id"
assert_status 1
assert_json ".error == \"server_unavailable\" and .id == \"$id\" and .recovery == \"get $id\""
LC_ALL=C LANG=C run_case --server "$test_root/no-such-λ" doctor
assert_status 1
assert_json '.error == "server_unavailable" and .loaded_servers == []'
printf 'PASS %s CLI cases without a server\n' "$count"
