#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_SCRIPT="${SCRIPT_DIR}/.mise/tasks/release"

PASS=0
FAIL=0

run_test() {
  local name="$1"
  shift
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  cd "$tmpdir"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  git config commit.gpgsign false

  # Create the two .el files
  for f in compilation-history.el compilation-history-view.el; do
    cat > "$f" <<'ELEOF'
;;; dummy.el --- Test -*- lexical-binding: t; -*-
;; Version: 0.1.0
;;; Code:
(provide 'dummy)
;;; dummy.el ends here
ELEOF
  done

  git add -A && git commit -q -m "initial commit"

  if "$@" "$tmpdir"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi

  cd "$SCRIPT_DIR"
}

summary() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# --- Tests ---

test_version_parsing() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add something"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q "0.1.0 → 0.1.1"
}

test_fix_only_patch_bump() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "fix: repair something"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q "0.1.0 → 0.1.1"
}

test_feat_patch_bump() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add new feature"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q "0.1.0 → 0.1.1"
}

test_breaking_minor_bump() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat!: remove deprecated API"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q "0.1.0 → 0.2.0"
}

test_breaking_body_minor_bump() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "refactor: change internal API

BREAKING CHANGE: the function signature changed"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q "0.1.0 → 0.2.0"
}

test_no_bumpable_commits() {
  local tmpdir="$1"
  cd "$tmpdir"
  # No new commits since initial — tag the initial commit
  git tag v0.1.0
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1) && return 1
  echo "$output" | grep -qi "no.*commits\|nothing.*release"
}

run_test "version parsing and feat bump" test_version_parsing
run_test "fix only → patch bump" test_fix_only_patch_bump
run_test "feat → patch bump" test_feat_patch_bump
run_test "feat! → minor bump" test_breaking_minor_bump
run_test "BREAKING CHANGE in body → minor bump" test_breaking_body_minor_bump
run_test "no bumpable commits → error" test_no_bumpable_commits

test_changelog_grouping() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add widget support"
  git commit -q --allow-empty -m "fix: handle nil input"
  git commit -q --allow-empty -m "refactor: simplify internal loop"
  git commit -q --allow-empty -m "chore: update CI config"
  git commit -q --allow-empty -m "test: add coverage for edge case"

  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check

  # Verify CHANGELOG.org exists and has correct sections
  [ -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org missing"; return 1; }
  grep -q '^\*\*\ Added' "$tmpdir/CHANGELOG.org" || { echo "Missing Added section"; return 1; }
  grep -q '^\*\*\ Fixed' "$tmpdir/CHANGELOG.org" || { echo "Missing Fixed section"; return 1; }
  grep -q '^\*\*\ Changed' "$tmpdir/CHANGELOG.org" || { echo "Missing Changed section"; return 1; }
  grep -q '^\*\*\ Other' "$tmpdir/CHANGELOG.org" || { echo "Missing Other section"; return 1; }
  # Verify prefix stripped
  grep -q '^- add widget support' "$tmpdir/CHANGELOG.org" || { echo "feat prefix not stripped"; return 1; }
  grep -q '^- handle nil input' "$tmpdir/CHANGELOG.org" || { echo "fix prefix not stripped"; return 1; }
}

test_changelog_no_empty_sections() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "fix: only a bugfix"

  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check

  [ -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org missing"; return 1; }
  grep -q '^\*\*\ Fixed' "$tmpdir/CHANGELOG.org" || { echo "Missing Fixed section"; return 1; }
  ! grep -q '^\*\*\ Added' "$tmpdir/CHANGELOG.org" || { echo "Unexpected Added section"; return 1; }
  ! grep -q '^\*\*\ Changed' "$tmpdir/CHANGELOG.org" || { echo "Unexpected Changed section"; return 1; }
  ! grep -q '^\*\*\ Other' "$tmpdir/CHANGELOG.org" || { echo "Unexpected Other section"; return 1; }
}

test_changelog_creates_file() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: first feature"

  [ ! -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org should not exist yet"; return 1; }
  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check
  [ -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org not created"; return 1; }
  head -1 "$tmpdir/CHANGELOG.org" | grep -q '#+TITLE: Changelog' || { echo "Missing org title"; return 1; }
}

run_test "changelog groups by type" test_changelog_grouping
run_test "changelog omits empty sections" test_changelog_no_empty_sections
run_test "changelog creates file with title" test_changelog_creates_file

test_dirty_tree_aborts() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: something"
  echo "dirty" > untracked.txt
  git add untracked.txt
  # Should fail with dirty tree message
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1) && return 1
  echo "$output" | grep -qi "clean\|dirty\|uncommitted"
}

test_wrong_branch_aborts() {
  local tmpdir="$1"
  cd "$tmpdir"
  git checkout -q -b feature/test
  git commit -q --allow-empty -m "feat: something"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run 2>&1) && return 1
  echo "$output" | grep -qi "main\|branch"
}

test_wrong_branch_with_flag_proceeds() {
  local tmpdir="$1"
  cd "$tmpdir"
  git checkout -q -b feature/test
  git commit -q --allow-empty -m "feat: something"
  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check
}

test_tag_collision_aborts() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: first"
  git tag v0.1.1
  # Create the collision tag on a throwaway branch so it doesn't affect HEAD lineage
  git checkout -q -b tmp-tag
  git commit -q --allow-empty -m "chore: placeholder"
  git tag v0.1.2
  git checkout -q main 2>/dev/null || git checkout -q master
  git commit -q --allow-empty -m "feat: second"
  # Now: last_tag=v0.1.1, bump=patch → new_version=0.1.2, but v0.1.2 already exists
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1) && return 1
  echo "$output" | grep -qi "already exists\|collision\|tag"
}

test_missing_gh_aborts() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: something"
  local output
  output=$(PATH="" MISE_PROJECT_DIR="$tmpdir" "$BASH" "$RELEASE_SCRIPT" --no-branch-check 2>&1) && return 1
  echo "$output" | grep -qi "gh"
}

test_dry_run_no_side_effects() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add something"
  local before_version
  before_version=$(grep -m1 '^;; Version:' compilation-history.el | sed 's/^;; Version:[[:space:]]*//')

  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check

  local after_version
  after_version=$(grep -m1 '^;; Version:' compilation-history.el | sed 's/^;; Version:[[:space:]]*//')
  [ "$before_version" = "$after_version" ] || { echo "Version was modified during dry-run"; return 1; }
  [ ! -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org created during dry-run"; return 1; }
  ! git tag -l | grep -q 'v0.1.1' || { echo "Tag created during dry-run"; return 1; }
}

test_dry_run_shows_markdown_preview() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add widget"
  git commit -q --allow-empty -m "fix: handle nil"
  local output
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check 2>&1)
  echo "$output" | grep -q '^## \[0.1.1\]' || { echo "Missing markdown version heading"; return 1; }
  echo "$output" | grep -q '^### Added' || { echo "Missing markdown Added heading"; return 1; }
  echo "$output" | grep -q '^### Fixed' || { echo "Missing markdown Fixed heading"; return 1; }
}

test_end_to_end_local() {
  local tmpdir="$1"
  cd "$tmpdir"
  git commit -q --allow-empty -m "feat: add widget"
  git commit -q --allow-empty -m "fix: handle edge case"
  git commit -q --allow-empty -m "chore: update deps"

  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check

  # Verify version updated in all .el files
  for f in compilation-history.el compilation-history-view.el; do
    grep -q '^;; Version: 0.1.1' "$tmpdir/$f" || { echo "$f version not updated"; return 1; }
  done

  # Verify changelog
  [ -f "$tmpdir/CHANGELOG.org" ] || { echo "CHANGELOG.org missing"; return 1; }
  grep -q '^\* \[0.1.1\]' "$tmpdir/CHANGELOG.org" || { echo "Version heading missing"; return 1; }

  # Verify commit
  git log -1 --format='%s' | grep -q 'chore: release v0.1.1' || { echo "Commit message wrong"; return 1; }

  # Verify tag
  git tag -l | grep -q 'v0.1.1' || { echo "Tag missing"; return 1; }
}

test_multi_release() {
  local tmpdir="$1"
  cd "$tmpdir"

  # First release
  git commit -q --allow-empty -m "feat: first feature"
  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check

  grep -q '^\* \[0.1.1\]' "$tmpdir/CHANGELOG.org" || { echo "First release heading missing"; return 1; }
  git tag -l | grep -q 'v0.1.1' || { echo "First tag missing"; return 1; }

  # Second release
  git commit -q --allow-empty -m "fix: important bugfix"
  git commit -q --allow-empty -m "feat: second feature"
  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --no-branch-check

  grep -q '^\* \[0.1.2\]' "$tmpdir/CHANGELOG.org" || { echo "Second release heading missing"; return 1; }
  git tag -l | grep -q 'v0.1.2' || { echo "Second tag missing"; return 1; }

  # Verify first release still in changelog
  grep -q '^\* \[0.1.1\]' "$tmpdir/CHANGELOG.org" || { echo "First release clobbered"; return 1; }

  # Verify second release appears before first
  local first_pos second_pos
  first_pos=$(grep -n '^\* \[0.1.1\]' "$tmpdir/CHANGELOG.org" | head -1 | cut -d: -f1)
  second_pos=$(grep -n '^\* \[0.1.2\]' "$tmpdir/CHANGELOG.org" | head -1 | cut -d: -f1)
  [ "$second_pos" -lt "$first_pos" ] || { echo "Second release not prepended before first"; return 1; }

  # Verify .el versions updated to latest
  for f in compilation-history.el compilation-history-view.el; do
    grep -q '^;; Version: 0.1.2' "$tmpdir/$f" || { echo "$f not at 0.1.2"; return 1; }
  done
}

run_test "dirty working tree aborts" test_dirty_tree_aborts
run_test "wrong branch aborts" test_wrong_branch_aborts
run_test "wrong branch with --no-branch-check proceeds" test_wrong_branch_with_flag_proceeds
run_test "tag collision aborts" test_tag_collision_aborts
run_test "missing gh binary aborts" test_missing_gh_aborts
run_test "dry-run has no side effects" test_dry_run_no_side_effects
run_test "dry-run shows markdown preview" test_dry_run_shows_markdown_preview
run_test "end-to-end local release" test_end_to_end_local
run_test "multi-release prepends correctly" test_multi_release

snapshot_repo() {
  git rev-parse HEAD
  git show-ref --heads --tags || true
  git status --porcelain
  git hash-object compilation-history.el compilation-history-view.el
  if [ -f CHANGELOG.org ]; then git hash-object CHANGELOG.org; fi
}

setup_remote() {
  local fixture="$1"
  mkdir -p "$fixture/.git/test-fixtures/bin" || return 1
  git tag v0.1.0 || return 1
  git init --bare -q -b main "$fixture/.git/test-fixtures/origin.git" || return 1
  git remote add origin "$fixture/.git/test-fixtures/origin.git" || return 1
  git push -q -u origin main refs/tags/v0.1.0 || return 1
  cat > "$fixture/.git/test-fixtures/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1:$2" in
  auth:status) exit "${FAKE_GH_AUTH_STATUS:-0}" ;;
  release:create)
    printf '%s\n' "$*" >> "$FIXTURE_GH_LOG"
    cat >> "$FIXTURE_GH_LOG"
    exit "${FAKE_GH_RELEASE_STATUS:-0}"
    ;;
  *) exit 99 ;;
esac
GHEOF
  chmod +x "$fixture/.git/test-fixtures/bin/gh" || return 1
  : > "$fixture/.git/test-fixtures/gh.log"
}

publish_fixture() {
  local fixture="$1"
  shift
  PATH="$fixture/.git/test-fixtures/bin:$PATH" \
    FIXTURE_GH_LOG="$fixture/.git/test-fixtures/gh.log" \
    GITHUB_TOKEN=fixture-token MISE_PROJECT_DIR="$fixture" \
    "$RELEASE_SCRIPT" "$@"
}

test_allow_no_release_dry_run_is_noop() {
  local tmpdir="$1" before output
  git tag v0.1.0 || return 1
  git commit -q --allow-empty -m "Non-conventional change" || return 1
  before="$(snapshot_repo)"
  output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --no-branch-check --allow-no-release 2>&1) || return 1
  echo "$output" | grep -qi 'no releasable commits' || return 1
  [ "$before" = "$(snapshot_repo)" ] || return 1
  [ ! -e CHANGELOG.org ] || return 1
}

test_allow_no_release_publish_is_noop() {
  local tmpdir="$1" before remote_before
  setup_remote "$tmpdir" || return 1
  git commit -q --allow-empty -m "Non-conventional change" || return 1
  before="$(snapshot_repo)"
  remote_before="$(git ls-remote origin)"
  publish_fixture "$tmpdir" --allow-no-release || return 1
  [ "$before" = "$(snapshot_repo)" ] || return 1
  [ "$remote_before" = "$(git ls-remote origin)" ] || return 1
  [ ! -s "$tmpdir/.git/test-fixtures/gh.log" ] || return 1
}

test_allow_no_release_still_releases_conventional_commits() {
  local tmpdir="$1"
  git tag v0.1.0 || return 1
  git commit -q --allow-empty -m "fix: sample" || return 1
  MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --local-only --allow-no-release || return 1
  grep -q '^;; Version: 0.1.1$' compilation-history.el || return 1
  grep -q '^;; Version: 0.1.1$' compilation-history-view.el || return 1
  grep -q '^\* \[0.1.1\]' CHANGELOG.org || return 1
  [ "$(git rev-parse v0.1.1)" = "$(git rev-parse HEAD)" ] || return 1
  [ "$(git log -1 --format=%s)" = 'chore: release v0.1.1 [skip ci]' ] || return 1
}

test_allow_no_release_preserves_preflight_failures() {
  local tmpdir="$1" output
  git tag v0.1.0 || return 1
  echo dirty > untracked.txt
  if output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --allow-no-release 2>&1); then return 1; fi
  echo "$output" | grep -qi 'not clean' || return 1
  rm untracked.txt || return 1
  git checkout -q -b feature/no-release || return 1
  if output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --allow-no-release 2>&1); then return 1; fi
  echo "$output" | grep -qi 'must be on main' || return 1
  if output=$(PATH="" MISE_PROJECT_DIR="$tmpdir" "$BASH" "$RELEASE_SCRIPT" --allow-no-release 2>&1); then return 1; fi
  echo "$output" | grep -qi 'gh CLI not found' || return 1
}

test_allow_no_release_preserves_auth_failure() {
  local tmpdir="$1" before output
  setup_remote "$tmpdir" || return 1
  before="$(snapshot_repo)"
  if output=$(PATH="$tmpdir/.git/test-fixtures/bin:$PATH" GITHUB_TOKEN="" GH_TOKEN="" \
    FAKE_GH_AUTH_STATUS=1 MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --allow-no-release 2>&1); then return 1; fi
  echo "$output" | grep -qi 'not authenticated' || return 1
  [ "$before" = "$(snapshot_repo)" ] || return 1
}

test_allow_no_release_preserves_tag_collision() {
  local tmpdir="$1" other before output
  git tag v0.1.0 || return 1
  git commit -q --allow-empty -m "fix: sample" || return 1
  other=$(printf 'Unrelated\n' | git commit-tree "$(git write-tree)") || return 1
  git tag v0.1.1 "$other" || return 1
  before="$(snapshot_repo)"
  if output=$(MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --dry-run --allow-no-release 2>&1); then return 1; fi
  echo "$output" | grep -qi 'already exists' || return 1
  [ "$before" = "$(snapshot_repo)" ] || return 1
}

test_publish_pushes_only_release_branch_and_new_tag() {
  local tmpdir="$1" other
  setup_remote "$tmpdir" || return 1
  git commit -q --allow-empty -m "fix: sample" || return 1
  other=$(printf 'Unrelated\n' | git commit-tree "$(git write-tree)") || return 1
  git tag unrelated "$other" || return 1
  git branch unrelated "$other" || return 1
  publish_fixture "$tmpdir" || return 1
  [ "$(git --git-dir="$tmpdir/.git/test-fixtures/origin.git" rev-parse main)" = "$(git rev-parse HEAD)" ] || return 1
  [ "$(git --git-dir="$tmpdir/.git/test-fixtures/origin.git" rev-parse v0.1.1)" = "$(git rev-parse HEAD)" ] || return 1
  [ -z "$(git ls-remote origin refs/tags/unrelated refs/heads/unrelated)" ] || return 1
  grep -q '^release create v0.1.1 --title v0.1.1 --notes-file -$' "$tmpdir/.git/test-fixtures/gh.log" || return 1
}

test_publish_push_is_atomic() {
  local tmpdir="$1" before
  setup_remote "$tmpdir" || return 1
  before=$(git rev-parse HEAD)
  git commit -q --allow-empty -m "fix: sample" || return 1
  cat > "$tmpdir/.git/test-fixtures/origin.git/hooks/update" <<'HOOKEOF'
#!/bin/sh
[ "$1" != refs/tags/v0.1.1 ]
HOOKEOF
  chmod +x "$tmpdir/.git/test-fixtures/origin.git/hooks/update" || return 1
  publish_fixture "$tmpdir" > "$tmpdir/.git/test-fixtures/output.log" 2>&1 && return 1
  [ "$(git --git-dir="$tmpdir/.git/test-fixtures/origin.git" rev-parse main)" = "$before" ] || return 1
  [ -z "$(git ls-remote origin refs/tags/v0.1.1)" ] || return 1
  [ ! -s "$tmpdir/.git/test-fixtures/gh.log" ] || return 1
}

test_publish_reports_gh_failure_after_push() {
  local tmpdir="$1" output
  setup_remote "$tmpdir" || return 1
  git commit -q --allow-empty -m "fix: sample" || return 1
  if output=$(FAKE_GH_RELEASE_STATUS=1 publish_fixture "$tmpdir" --allow-no-release 2>&1); then return 1; fi
  [ "$(git --git-dir="$tmpdir/.git/test-fixtures/origin.git" rev-parse main)" = "$(git rev-parse HEAD)" ] || return 1
  [ "$(git --git-dir="$tmpdir/.git/test-fixtures/origin.git" rev-parse v0.1.1)" = "$(git rev-parse HEAD)" ] || return 1
  echo "$output" | grep -q 'v0.1.1' || return 1
  echo "$output" | grep -qi 'recover' || return 1
  if echo "$output" | grep -q 'Created GitHub release'; then return 1; fi
}

run_test "allow no release dry-run is a no-op" test_allow_no_release_dry_run_is_noop
run_test "allow no release publishing is a no-op" test_allow_no_release_publish_is_noop
run_test "allow no release still bumps conventional commits" test_allow_no_release_still_releases_conventional_commits
run_test "allow no release preserves preflight failures" test_allow_no_release_preserves_preflight_failures
run_test "allow no release preserves authentication failures" test_allow_no_release_preserves_auth_failure
run_test "allow no release preserves tag collisions" test_allow_no_release_preserves_tag_collision
run_test "publish pushes only the release branch and new tag" test_publish_pushes_only_release_branch_and_new_tag
run_test "publish pushes branch and tag atomically" test_publish_push_is_atomic
run_test "publish reports GitHub API failure after push" test_publish_reports_gh_failure_after_push

summary
