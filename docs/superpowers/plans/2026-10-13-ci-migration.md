# Cirrus to GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Cirrus with Pkl generated GitHub Actions that run the existing mise checks and publish automatically from tested main revisions.

**Architecture:** Keep commands in `.mise/tasks`, workflow configuration in `.github/pkl`, and generated YAML in `.github/workflows`. Preserve the existing Linux Emacs images and run generation/release validation on native Linux runners. Introduce GitHub publishing behind a disabled repository variable, validate alongside Cirrus, then switch to one publisher.

**Tech Stack:** Bash 4.3 or newer, Git, mise, Pkl 0.32.1, Pkl Pantry `com.github.actions` 1.9.2, actionlint 1.7.12, GitHub Actions, existing Emacs containers.

**Spec:** [Approved migration design](../specs/2026-10-12-ci-migration-design.md).

## Global Constraints

- Never create a Git branch whose name contains `codex`; continue on `ci/mise-pkl-github-actions`.
- Emacs 29.4 and 30.1 remain required Linux checks. Emacs master remains advisory and excluded from publishing dependencies.
- Preserve automatic releases from main, the conventional-commit version policy, and the existing release commit's `[skip ci]` behavior.
- Emacs must provide SQLite with FTS5 and the trigram tokenizer; keep the existing melpazoid dependency pins and ignore rules.
- Ordinary workflow generation consumes committed dependency/action pins and must not rewrite dependency locks or select newer versions.
- Publishing uses the tested event SHA, full history/tags, a clean checkout, and an actual main branch. Only publishing receives `contents: write`.
- Never use cancelling workflow-level concurrency; serialize publishers with `cancel-in-progress: false`.
- Extra platforms, scheduled runs, and new Emacs coverage remain separate changes. Never run both publishers together.

## Review Focus

- Missing, stale, changed, or unexpected generator inputs/outputs must fail verification without changing the checkout: Task 1 fixture tests.
- A valid no-release history must succeed only with the opt-in flag; other errors must remain failures: Task 2 release tests.
- A rejected tag push or failed GitHub API call must expose the actual remote state and avoid a false success: Task 2 local-origin tests.
- An obsolete tested SHA or failed freshness fetch must never publish untested code: Task 4 orchestration tests.
- Fork PRs and failed master builds must preserve read-only checks and the required stable release gate: Task 3 Pkl policy tests and hosted validation.

## File Structure

| File | Responsibility |
| --- | --- |
| `mise.toml`, `mise.lock` | Exact generator/tool versions and lock metadata |
| `.github/pkl/PklProject`, `PklProject.deps.json` | Named `githubActions` dependency and committed resolution |
| `.github/pkl/ci.pkl` | Sole workflow source, including reviewed action SHA constants |
| `.github/pkl/lockcheck.pkl` | Validate exact declared dependency pins against the committed lock |
| `.github/pkl/policy_test.pkl` | Assert workflow permissions, triggers, dependencies, and concurrency |
| `.mise/tasks/workflows-generate`, `workflows-check`, `workflows-update` | Render, verify, and explicitly update workflow dependencies |
| `.github/workflows/ci.yml` | Committed generated workflow |
| `tests/test-workflows.sh`, `.mise/tasks/workflows-test` | Real generator tests in temporary fixture checkouts |
| `.mise/tasks/release`, `tests/test-release.sh` | Existing release logic and regression suite |
| `.mise/tasks/ci-release`, `tests/test-ci-release.sh`, `.mise/tasks/ci-release-test` | Tested-revision freshness check and publishing orchestration |
| `README.org` | Developer commands and publisher operations |
| `.github/ci/emacs.Dockerfile` | Create only if job-container action compatibility requires the Docker fallback |

Paths below are relative to the repository root. Temporary test binaries, logs, and bare origins belong under the fixture's `.git/test-fixtures/` so they do not violate the release clean-tree preflight. Do not stage existing untracked `.claude/` files.

### Task 1: Reproducible workflow generation

**Files:** Create the Pkl project, `ci.pkl`, `lockcheck.pkl`, the three workflow tasks, `tests/test-workflows.sh`, `workflows-test`, and generated `ci.yml`. Modify `mise.toml`, create `mise.lock`, and add developer instructions to `README.org`.

**Interfaces:** `workflows-generate [output-directory]` writes exactly `ci.yml`, defaulting to `.github/workflows`. `workflows-check` renders into a temporary directory, compares expected filenames and bytes, and runs actionlint. `workflows-update` refreshes the Pkl dependency lock only after intentional declaration changes and then regenerates output; action SHA edits remain explicit reviewed source changes. Every task returns nonzero on a genuine failure.

- [ ] **Establish tool pins.** Declare Pkl 0.32.1 and actionlint 1.7.12. Use the already installed mise 2026.10.3 as the initial executable pin. The verified action pins are `jdx/mise-action` v5.1.1 at `2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca` and `actions/checkout` v7.0.1 at `3d3c42e5aac5ba805825da76410c181273ba90b1`; use a generic Step for checkout because this Pkl package's typed catalog exposes v6. Commit lock metadata for Linux amd64 and the developer's macOS arm64. The current system Bash is 3.2, and mise reports an unavailable `nix` backend. Replace only the macOS-scoped entries with `conda:git = { version = "2.56.0", os = ["macos"] }` and `conda:bash = { version = "5.2.37", os = ["macos"] }`. Bash 5.2.37 has [conda-forge macOS arm64 and Linux builds](https://api.anaconda.org/package/conda-forge/bash); Linux CI can retain the images' compatible system Git/Bash. These changes make the approved tasks executable.
- [ ] **Write failing generator tests.** In `tests/test-workflows.sh`, exercise the following named cases against temporary copies of the actual Pkl source and actual Pkl executable. Every setup command/assertion must return failure explicitly.

| Test | Required assertions |
| --- | --- |
| `test_generation_is_deterministic` | Two renders produce identical `ci.yml`; project lock bytes remain unchanged |
| `test_check_detects_changed_missing_extra_output` | Edit, delete, then add an unexpected `.yml` in separate fixtures; each check fails and leaves the fixture bytes unchanged |
| `test_generation_rejects_missing_and_stale_lock` | Missing lock fails; changing the declared package pin in either direction without updating the lock fails; no lock is created or rewritten |
| `test_generation_from_another_directory` | Explicit `MISE_PROJECT_DIR` and an output path containing spaces still produce the expected file |

- [ ] **Run the tests before implementation.** `bash tests/test-workflows.sh` must fail because generation tasks do not exist. Record the failing case rather than accepting an unrelated missing-tool failure.
- [ ] **Implement the generator contract.** Set `githubActions` to `package://pkg.pkl-lang.org/pkl-pantry/com.github.actions@1.9.2`. Amend that dependency's `Workflow.pkl` in `ci.pkl` and initially emit a read-only `workflows` job. Make `lockcheck.pkl` amend `pkl:test` and parse the lock using `new json.Parser { useMapping = true }` from `pkl:json`. Assert schemaVersion 1, the sole canonical dependency key `package://pkg.pkl-lang.org/pkl-pantry/com.github.actions@1`, remote dependency type, and resolved URI equal to the declared URI prefixed with `project`. This package has no transitive package dependencies. Pkl evaluation alone can accept a newer locked version and is insufficient. Run the lock checker with `pkl test --no-project` before rendering. Use an absolute project path and temporary output path with `pkl eval`; replace `ci.yml` only after successful evaluation and manage temporary directories with cleanup traps. `workflows-check` compares the complete managed `.yml`/`.yaml` output set and fails on extra files, then runs actionlint. `workflows-update` runs `pkl project resolve` only when intentionally updating the dependency lock.
- [ ] **Verify and commit.** Run `mise run workflows-test`, `mise run workflows-generate`, and `mise run workflows-check`; expect all fixture cases to pass, no output drift, and zero actionlint errors. Check `git diff --check`, then commit only these files with `ci: add Pkl workflow generation through mise`.

### Task 2: Explicit release no-ops and selective atomic pushes

**Files:** Modify `.mise/tasks/release` at flag parsing, no-release handling, and remote operations; extend `tests/test-release.sh`; document the new flag and recovery in `README.org`.

**Interfaces:** Add `--allow-no-release`. With that flag, only the existing `bump_type=none` condition exits successfully with a no-release message and no mutations. The default behavior, preflight order, and `--dry-run`/`--local-only` semantics remain unchanged. Publishing pushes the current release branch and only its new tag atomically to `origin`, then creates the GitHub release.

- [ ] **Write failing regression tests.** Keep `test_no_bumpable_commits` unchanged. Add the cases below using real temporary Git repositories; fake only gh/API access. Initialize remote fixtures explicitly on main, create a local bare origin, and set its HEAD/upstream. Record gh arguments/stdin and configure its exit code through the fixture.

| Test | Required assertions |
| --- | --- |
| `test_allow_no_release_dry_run_is_noop` | Tagged history plus a non-conventional commit; exit 0; HEAD, tags, status, files, and changelog existence unchanged |
| `test_allow_no_release_publish_is_noop` | Same history on main with a bare origin and fake gh; exit 0; local/remote refs unchanged; gh release never called |
| `test_allow_no_release_still_releases_conventional_commits` | `fix: sample` still produces version 0.1.1, changelog, release commit, and tag |
| `test_allow_no_release_preserves_preflight_failures` | Dirty tree, wrong branch, and missing gh remain nonzero even with no releasable history |
| `test_allow_no_release_preserves_auth_failure` | Clear both token variables; fake gh auth fails; nonzero, no mutations |
| `test_allow_no_release_preserves_tag_collision` | Existing off-lineage collision fixture still fails with the flag and preserves files/refs |
| `test_publish_pushes_only_release_branch_and_new_tag` | Remote main/new tag reach release HEAD; unrelated local branch/tag stay absent remotely |
| `test_publish_push_is_atomic` | Bare-origin hook rejects the new tag; remote main remains unchanged, tag is absent, gh was not called |
| `test_publish_reports_gh_failure_after_push` | Fake gh creation fails; nonzero, branch/tag already pushed, recovery diagnostic names the tag, no release-success message |

- [ ] **Make missing-gh coverage deterministic.** Replace its inherited PATH construction with an explicit Bash invocation and a PATH excluding gh. The existing preflight checks gh before invoking Git. Test functions are called inside `if` by `run_test`, so use explicit `|| return 1` for important setup/assertions rather than depending on `set -e`.
- [ ] **Run red tests.** `mise run release-test` must fail on the unrecognized flag and separate-push behavior. Preserve and distinguish any baseline failure before changing release logic.
- [ ] **Implement the release contract.** Add the flag, leave preflight before the no-release decision, and replace the two pushes with one `git push --atomic origin HEAD:refs/heads/<current-branch> refs/tags/v<new-version>`. Preserve branch override behavior for existing local tests. On gh failure, report the pushed tag and recovery requirement and return nonzero. Pin task-local gh to a verified exact release, initially 2.102.0.
- [ ] **Verify and commit.** Run `mise run release-test` and `bash -n .mise/tasks/release tests/test-release.sh`; require zero failed cases. Run `git diff --check`, then commit these changes with `fix: make CI release no-ops explicit and pushes atomic`.

### Task 3: Wire GitHub checks with publishing disabled

**Files:** Extend `.github/pkl/ci.pkl`, create `policy_test.pkl`, regenerate `ci.yml`, and update `README.org`. Create `.github/ci/emacs.Dockerfile` only if compatibility verification requires it.

**Interfaces:** Workflow job IDs are `workflows`, `check-stable`, `check-master`, `release-validation`, and `release`. Required release dependencies are exactly `workflows`, `check-stable`, and `release-validation`. `CI_PUBLISH_ENABLED` is a repository variable; publication requires its value to equal the string `true`, so an unset variable disables it.

- [ ] **Write failing Pkl policy assertions.** Import `ci.pkl` into a module amending `pkl:test`; test the typed workflow properties, including backtick-quoted `fail-fast`, `continue-on-error`, and `if`. Stable matrix equals `["29.4", "30.1"]`, fail-fast is false, master has continue-on-error true, release needs exclude master, default permissions equal `contents: read`, only release grants `contents: write`, read-only checkouts do not persist credentials, publishing requires a main push in `djgoku/compilation-history` and `CI_PUBLISH_ENABLED == 'true'`, and cancelling concurrency never appears at workflow scope. Assert release uses its own concurrency group with cancel-in-progress false. Run `mise exec -- pkl test --project-dir .github/pkl .github/pkl/policy_test.pkl` and observe failures for the absent jobs.

The core gate assertions are:

```pkl
ci.output.value.jobs["check-stable"].strategy.matrix["emacs"].toList() == List("29.4", "30.1")
ci.output.value.jobs["release"].needs.toList() == List("workflows", "check-stable", "release-validation")
ci.output.value.jobs["check-master"].`continue-on-error` == true
ci.output.value.permissions.contents == "read"
ci.output.value.jobs["release"].permissions.contents == "write"
```

- [ ] **Verify the container path.** On an amd64 Linux Docker host or GitHub runner, inspect the three existing image tags; verify Emacs version/build description and create an in-memory FTS5 table with `tokenize='trigram'`. Verify pinned checkout/mise actions run inside the images. Record stable image digests in Pkl after the probe passes, and leave master moving. If JavaScript action compatibility fails, perform setup on the host and run the same checks through a small Docker image derived from the same Emacs base, as allowed by the design.
- [ ] **Implement the five jobs.** Use `ubuntu-24.04`, branch pushes and PRs targeting main, no path filters, and explicit Bash shells. Stable/master jobs print build details and run `mise run check`. Release validation checks out full history/tags and runs `mise run release-test` followed by `mise run release -- --dry-run --no-branch-check --allow-no-release`. Include generator/policy tests in workflows and orchestration tests in release validation once Task 4 exists. Declare publication's exact guard, permissions, concurrency, token, full checkout, and the future `mise run ci-release -- "$GITHUB_SHA"` command, keeping the repository variable disabled.
- [ ] **Verify locally.** Run `mise run workflows-test`, the Pkl policy tests, and `mise run workflows-check`; expect zero failures/drift/lint errors. Run both stable check environments without caches wherever an amd64 Docker host is available; hosted cold runs are required even if these local checks pass.
- [ ] **Commit the reviewed output.** Keep Cirrus configuration active and commit source, generated YAML, policy assertions, and instructions with `ci: run Emacs and release checks in GitHub Actions`.
- [ ] **Run hosted validation.** Push the committed branch and open its review through the normal execution workflow, then inspect the real hosted branch/PR jobs alongside Cirrus, including cold-cache runs. Confirm no publishing job executes while the variable is unset. Validate the advisory policy with a disposable master-failure probe and restore generated output afterward.

### Task 4: Publish only the tested current main revision

**Files:** Create `.mise/tasks/ci-release`, `.mise/tasks/ci-release-test`, and `tests/test-ci-release.sh`; finish the publishing command/test hooks in `ci.pkl`, regenerate `ci.yml`, and document the wrapper in `README.org`.

**Interfaces:** `mise run ci-release -- <tested-sha>` consumes the single tested commit SHA. If local HEAD differs, arguments are invalid, fetch fails, or publication fails, it exits nonzero. If remote main has advanced, it exits 0 with an obsolete-run message and never invokes release. Otherwise it creates the local main branch at that SHA and invokes `mise run release -- --allow-no-release` exactly once. Freshness does not authorize a reset to newer remote code.

- [ ] **Write failing orchestration tests.** Use actual Git fetches against a local bare origin and a recording mise stub. Add `test_ci_release_publishes_tested_remote_tip` (one release invocation), `test_ci_release_skips_stale_tested_sha` (advance origin through a second clone; no release invocation or local branch/tag/file changes; the fetched origin/main tracking ref may update), `test_ci_release_fetch_failure_aborts` (nonzero; no invocation), `test_ci_release_rejects_wrong_head_or_invalid_sha` (nonzero; no invocation), and `test_ci_release_propagates_release_failure` (stub failure stays nonzero). Run `bash tests/test-ci-release.sh`; expect failure because the wrapper is absent.
- [ ] **Implement the wrapper.** Validate/resolve the supplied SHA as a commit, require local HEAD to match, fetch `refs/heads/main` into `refs/remotes/origin/main`, compare the fetched tip, and skip obsolete runs before modifying the branch. On a current run, create main at the tested SHA, configure GitHub Actions bot identity, and invoke the release task. Use ordinary non-force pushes; a subsequent main race must fail visibly instead of releasing newer code.
- [ ] **Complete workflow integration.** Publishing supplies authenticated HTTPS Git credentials and `GITHUB_TOKEN` only within the publishing job. Read-only jobs retain no push credentials. Run the wrapper on the exact event SHA after required jobs succeed. Add the orchestration tests to release validation; never regenerate YAML inside the publishing checkout.
- [ ] **Verify and commit.** Run `mise run ci-release-test`, `mise run release-test`, the Pkl policy tests, `mise run workflows-check`, and Bash syntax checks for the new files. Require zero failures and no generated drift. Commit with `ci: guard publishing with tested main revision`.

### Task 5: Validate parity and switch publishers

**Files:** Remove `.cirrus.yml` and `.cirrus.Dockerfile`; remove the commented Cirrus tool declaration from `mise.toml`; finalize `README.org`. Keep any Docker fallback introduced in Task 3.

**Interfaces:** Cutover uses the repository variable `CI_PUBLISH_ENABLED` and the GitHub check names from the actual successful hosted runs. Operational settings must follow the single-publisher order below. Automatic main publishing remains the final steady state.

- [ ] **Confirm readiness.** Verify stable checks, workflow verification, release-script tests, and release previews pass on branch and PR events, including cold caches. Inspect repository rules and the selected publisher identity to confirm the main release commit is permitted; use the built-in token when allowed, or configure the designated GitHub App identity without weakening branch rules. Do not create a production release as a probe.
- [ ] **Drain Cirrus publishing.** Disable future Cirrus release jobs and drain or cancel existing queued/running publishers. Confirm none remain. Keep GitHub publishing disabled during this step.
- [ ] **Remove Cirrus configuration and update required checks.** Commit the deletions/config cleanup with `ci: retire Cirrus after GitHub parity verification`. Update required checks using their observed GitHub names. Inspect the review before merging through the normal execution workflow.
- [ ] **Enable the GitHub publisher.** Set `CI_PUBLISH_ENABLED=true` only after Cirrus is drained and token/rule compatibility is confirmed. Let the next tested main push publish, or rerun the appropriate fully checked main workflow if no new push is needed. Its freshness check must still accept that event SHA.
- [ ] **Verify the first release or recover.** Confirm one release commit with version/changelog updates, one new tag pointing to it, and one GitHub release. If gh creation fails after the push, disable the variable and recover the release for that exact tag rather than bumping again. Before restoring Cirrus publishing, drain all GitHub publishers and reconcile refs. Record the verified cutover outcome in the review.

## Execution and verification boundary

Tasks 1 through 4 prepare reviewable code and hosted validation with GitHub publishing disabled. Task 5 owns the operational cutover and main merge; a local test or generated-file check cannot substitute for its hosted evidence. Planning approval does not assert that tools, tests, token access, or container compatibility have already passed.

Execute Task 1 first; Tasks 2 and 3 can be prepared independently afterward, and Task 4 consumes both. Every implementation commit stages only its listed files. Use the existing authorized branch rather than creating another one.
