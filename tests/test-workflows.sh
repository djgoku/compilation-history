#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
PASS=0
FAIL=0

generate() {
  MISE_PROJECT_DIR="$fixture" bash "$PROJECT_ROOT/.mise/tasks/workflows-generate" "$@"
}

check() {
  MISE_PROJECT_DIR="$fixture" bash "$PROJECT_ROOT/.mise/tasks/workflows-check"
}

test_generation_is_deterministic() {
  generate "$fixture/first" || return 1
  generate "$fixture/second" || return 1
  [ -f "$fixture/first/ci.yml" ] || return 1
  diff -r "$fixture/first" "$fixture/second" || return 1
  cmp "$fixture/lock-before.json" "$fixture/.github/pkl/PklProject.deps.json" || return 1
}

test_check_detects_changed_missing_extra_output() {
  generate || return 1
  check || return 1
  cp "$fixture/.github/workflows/ci.yml" "$fixture/original.yml" || return 1
  printf '\n# drift\n' >> "$fixture/.github/workflows/ci.yml"
  cp "$fixture/.github/workflows/ci.yml" "$fixture/drifted.yml" || return 1
  check > "$fixture/check.log" 2>&1 && return 1
  cmp "$fixture/drifted.yml" "$fixture/.github/workflows/ci.yml" || return 1
  rm "$fixture/.github/workflows/ci.yml" || return 1
  check > "$fixture/check.log" 2>&1 && return 1
  [ ! -e "$fixture/.github/workflows/ci.yml" ] || return 1
  cp "$fixture/original.yml" "$fixture/.github/workflows/ci.yml" || return 1
  cp "$fixture/original.yml" "$fixture/.github/workflows/unexpected.yaml" || return 1
  check > "$fixture/check.log" 2>&1 && return 1
  cmp "$fixture/original.yml" "$fixture/.github/workflows/unexpected.yaml" || return 1
}

test_generation_rejects_missing_and_stale_lock() {
  rm "$fixture/.github/pkl/PklProject.deps.json" || return 1
  generate > "$fixture/check.log" 2>&1 && return 1
  [ ! -e "$fixture/.github/pkl/PklProject.deps.json" ] || return 1
  cp "$fixture/lock-before.json" "$fixture/.github/pkl/PklProject.deps.json" || return 1
  cp "$fixture/.github/pkl/PklProject" "$fixture/project-before" || return 1
  for pin in 1.9.1 1.9.3; do
    sed "s/@1.9.2/@$pin/" "$fixture/project-before" > "$fixture/.github/pkl/PklProject" || return 1
    generate > "$fixture/check.log" 2>&1 && return 1
    cmp "$fixture/lock-before.json" "$fixture/.github/pkl/PklProject.deps.json" || return 1
  done
}

test_generation_from_another_directory() {
  (cd "$test_root" && generate "$fixture/output with spaces") || return 1
  [ -s "$fixture/output with spaces/ci.yml" ] || return 1
}

run_test() {
  local name="$1"
  fixture="$test_root/$name"
  mkdir -p "$fixture/.github" || return 1
  if [ -d "$PROJECT_ROOT/.github/pkl" ]; then
    cp -R "$PROJECT_ROOT/.github/pkl" "$fixture/.github/pkl" || return 1
    cp "$fixture/.github/pkl/PklProject.deps.json" "$fixture/lock-before.json" || return 1
  fi
  if "$name"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

run_test test_generation_is_deterministic
run_test test_check_detects_changed_missing_extra_output
run_test test_generation_rejects_missing_and_stale_lock
run_test test_generation_from_another_directory
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
