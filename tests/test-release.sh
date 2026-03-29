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
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

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
  # Use a restricted PATH that excludes gh, but still has git and bash
  local git_dir bash_dir
  git_dir="$(dirname "$(command -v git)")"
  bash_dir="$(dirname "$(command -v bash)")"
  local output
  output=$(PATH="${git_dir}:${bash_dir}:/usr/bin:/bin" MISE_PROJECT_DIR="$tmpdir" "$RELEASE_SCRIPT" --no-branch-check 2>&1) && return 1
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
run_test "end-to-end local release" test_end_to_end_local
run_test "multi-release prepends correctly" test_multi_release

summary
