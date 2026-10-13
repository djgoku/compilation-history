#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI_RELEASE="$PROJECT_ROOT/.mise/tasks/ci-release"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
PASS=0
FAIL=0

ci_release() {
  PATH="$fixture/.git/test-fixtures/bin:$PATH" \
    MISE_PROJECT_DIR="$fixture" CI_RELEASE_LOG="$fixture/.git/test-fixtures/mise.log" \
    bash "$CI_RELEASE" "$@"
}

test_ci_release_publishes_tested_remote_tip() {
  local tested_sha
  tested_sha=$(git rev-parse HEAD)
  git checkout -q --detach "$tested_sha" || return 1
  ci_release "$tested_sha" || return 1
  [ "$(git branch --show-current)" = main ] || return 1
  [ "$(git rev-parse HEAD)" = "$tested_sha" ] || return 1
  [ "$(cat .git/test-fixtures/mise.log)" = 'run release -- --allow-no-release' ] || return 1
}

test_ci_release_skips_stale_tested_sha() {
  local tested_sha before output
  tested_sha=$(git rev-parse HEAD)
  before=$(git show-ref --heads --tags)
  git clone -q .git/test-fixtures/origin.git .git/test-fixtures/racer || return 1
  git -C .git/test-fixtures/racer config user.name Test || return 1
  git -C .git/test-fixtures/racer config user.email test@test.com || return 1
  git -C .git/test-fixtures/racer config commit.gpgsign false || return 1
  git -C .git/test-fixtures/racer commit -q --allow-empty -m 'New main revision' || return 1
  git -C .git/test-fixtures/racer push -q || return 1
  output=$(ci_release "$tested_sha" 2>&1) || return 1
  echo "$output" | grep -qi 'obsolete' || return 1
  [ ! -s .git/test-fixtures/mise.log ] || return 1
  [ "$(git rev-parse HEAD)" = "$tested_sha" ] || return 1
  [ "$(git show-ref --heads --tags)" = "$before" ] || return 1
  [ -z "$(git status --porcelain)" ] || return 1
}

test_ci_release_fetch_failure_aborts() {
  local tested_sha output
  tested_sha=$(git rev-parse HEAD)
  git remote set-url origin "$fixture/.git/test-fixtures/missing.git" || return 1
  if output=$(ci_release "$tested_sha" 2>&1); then return 1; fi
  echo "$output" | grep -qi 'fetch origin/main' || return 1
  [ ! -s .git/test-fixtures/mise.log ] || return 1
  if echo "$output" | grep -qi 'obsolete'; then return 1; fi
}

test_ci_release_rejects_wrong_head_or_invalid_sha() {
  local tested_sha
  tested_sha=$(git rev-parse HEAD)
  git commit -q --allow-empty -m 'Another local revision' || return 1
  ci_release "$tested_sha" > .git/test-fixtures/output.log 2>&1 && return 1
  grep -qi 'does not match tested' .git/test-fixtures/output.log || return 1
  ci_release not-a-commit > .git/test-fixtures/output.log 2>&1 && return 1
  grep -qi 'invalid tested commit' .git/test-fixtures/output.log || return 1
  ci_release > .git/test-fixtures/output.log 2>&1 && return 1
  grep -qi 'usage' .git/test-fixtures/output.log || return 1
  ci_release HEAD extra > .git/test-fixtures/output.log 2>&1 && return 1
  grep -qi 'usage' .git/test-fixtures/output.log || return 1
  [ ! -s .git/test-fixtures/mise.log ] || return 1
}

test_ci_release_propagates_release_failure() {
  local tested_sha status=0
  tested_sha=$(git rev-parse HEAD)
  CI_RELEASE_EXIT=23 ci_release "$tested_sha" > .git/test-fixtures/output.log 2>&1 || status=$?
  [ "$status" -eq 23 ] || return 1
  [ "$(cat .git/test-fixtures/mise.log)" = 'run release -- --allow-no-release' ] || return 1
}

run_test() {
  local name="$1"
  fixture="$test_root/$name"
  mkdir -p "$fixture" || return 1
  cd "$fixture"
  git init -q -b main || return 1
  git config user.name Test || return 1
  git config user.email test@test.com || return 1
  git config commit.gpgsign false || return 1
  git commit -q --allow-empty -m 'Initial fixture' || return 1
  mkdir -p .git/test-fixtures/bin || return 1
  git init --bare -q -b main .git/test-fixtures/origin.git || return 1
  git remote add origin "$fixture/.git/test-fixtures/origin.git" || return 1
  git push -q -u origin main || return 1
  cat > .git/test-fixtures/bin/mise <<'MISEEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CI_RELEASE_LOG"
exit "${CI_RELEASE_EXIT:-0}"
MISEEOF
  chmod +x .git/test-fixtures/bin/mise || return 1
  : > .git/test-fixtures/mise.log
  if "$name"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
  cd "$PROJECT_ROOT"
}

run_test test_ci_release_publishes_tested_remote_tip
run_test test_ci_release_skips_stale_tested_sha
run_test test_ci_release_fetch_failure_aborts
run_test test_ci_release_rejects_wrong_head_or_invalid_sha
run_test test_ci_release_propagates_release_failure
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
