# Cirrus migration to mise and Pkl generated GitHub Actions

Move CI orchestration from Cirrus to GitHub Actions, keep executable commands in mise, and maintain workflows as Pkl source with committed generated YAML. Preserve the Linux Emacs checks and automatic releases from `main`.

Date: October 12, 2026. Status: approved. Branch: `ci/mise-pkl-github-actions`, based on `origin/main` at `cfc37a1`.

## Current behavior and required parity

The current [.cirrus.yml](../../../.cirrus.yml) runs `mise run check` in Emacs 29.4, 30.1, and `master` containers. The stable versions must pass; `master` may fail. The [check task](../../../.mise/tasks/check) runs melpazoid and the ERT suite. Non-main branches also run a release preview and release-script tests. Main releases wait for both stable checks.

The [release task](../../../.mise/tasks/release) reads Git history and tags, updates version headers and `CHANGELOG.org`, creates a commit and tag, pushes them, and creates a GitHub release. It requires a clean checkout, Bash 4.3 or newer, and an actual `main` branch for publishing. Its conventional-commit version policy remains unchanged.

| Behavior | Target |
| --- | --- |
| Emacs 29.4 and 30.1 | Required Linux checks, same `mise run check` command |
| Emacs master | Separate advisory job; cannot block stable checks or publishing |
| Release preview | Read-only job on branch pushes and pull requests, using full history and tags |
| Release-script tests | Required on all checked revisions, including main |
| Publishing | Automatic on main pushes after required checks succeed |
| Workflow maintenance | Edit Pkl, regenerate YAML through mise, verify both together |

Emacs builds must provide SQLite with FTS5 and the trigram tokenizer used by the package's database schema. Retain existing melpazoid dependency pins and ignore rules.

## Approach and alternatives

Use GitHub-hosted Linux runners with the existing `silex/emacs:29.4-ci`, `30.1-ci`, and `master-ci` images for Emacs jobs. Install mise within those jobs through `jdx/mise-action`, set the run shell explicitly to Bash, and run the existing tasks. Pin stable image digests after verifying them; keep the master image moving for upstream coverage. Generation and release jobs can use the Linux runner directly because they do not need Emacs.

This preserves the current Emacs environment while replacing Cirrus orchestration. Validate mise and JavaScript action compatibility inside the images before adopting job containers. If an image cannot run the selected actions, perform checkout/setup on the host and invoke the Emacs image explicitly through Docker, with the pinned mise binary added in a small CI Dockerfile. Adding mise alone does not repair an incompatible Node or libc runtime. Keep any replacement Dockerfile under `.github/ci/`.

Two alternatives have different trade-offs:

- Installing Emacs directly on the runner removes containers. [purcell/setup-emacs](https://github.com/purcell/setup-emacs) currently provides 29.4, 30.1, and a `snapshot` input through Nix, but adds another installer and requires verification of the package's SQLite capabilities. Pinning the setup action alone does not freeze its separately fetched Emacs package definitions.
- Using `misemacs` through mise aligns with local macOS tooling, but its current channels target macOS arm64 and omit Emacs 29. Its CalVer releases track Emacs branches rather than exact versions such as 30.1. Add this coverage separately after the migration. See the [misemacs installation and scope](https://github.com/djgoku/misemacs/blob/main/README.org).

## Pkl source and mise commands

Start with one generated workflow, `.github/workflows/ci.yml`. Keep checks and publishing in the same workflow so publishing can depend directly on results for the same revision.

Use `.github/pkl/ci.pkl` as the source, with a `PklProject` and committed dependency lockfile in that directory. Begin with Pkl 0.32.1 and the official Pkl Pantry `com.github.actions` package at 1.9.2. Its typed workflow modules provide the schema; do not build a second workflow schema or a shared abstraction for a single workflow. See the [Pkl workflow package](https://pkl-lang.org/package-docs/pkg.pkl-lang.org/pkl-pantry/com.github.actions/1.9.2/index.html) and [CLI installation and output options](https://pkl-lang.org/main/current/pkl-cli/index.html).

Extend [mise.toml](../../../mise.toml) to declare Pkl 0.32.1 and [actionlint 1.7.12](https://github.com/rhysd/actionlint/releases/tag/v1.7.12), and commit the resulting `mise.lock`. Pin the mise action and checkout action to reviewed commit SHAs in Pkl, with release-version comments in the generated YAML. Pin the mise action's executable version separately, and replace the release task's floating gh declaration with a tested exact version. Keep existing macOS tool configuration unless it prevents these tasks from working. The [mise action](https://github.com/jdx/mise-action) supplies mise installation, tool setup, and caching.

Add three task entry points:

- `mise run workflows-generate`: evaluate with the committed `PklProject.deps.json` and render the workflow into `.github/workflows/ci.yml`. Fail on a missing or stale dependency lock; do not rewrite it.
- `mise run workflows-check`: render into a temporary directory, compare filenames and file bytes against committed outputs, then run actionlint. Detect missing, changed, and unexpected generated files; do not rely solely on `git diff`, which misses untracked outputs.
- `mise run workflows-update`: explicitly update dependency or action pins, run `pkl project resolve` when dependency declarations change, and regenerate their outputs. Ordinary generation must not choose newer dependencies or consult a moving branch for action SHAs.

For a single workflow module, run `pkl eval ci.pkl -o ../workflows/ci.yml` from `.github/pkl`. The mise tasks should resolve the repository root and use absolute output paths when rendering into temporary directories. Keep action SHAs as committed Pkl data initially. A separate Dependabot-managed action lock workflow can follow later if needed; it is not required for this migration.

Generation must produce identical output without tokens, timestamps, machine-specific paths, or network-driven version selection. Keep Pkl package downloads and any action-pin metadata outside the release checkout or committed/ignored as appropriate. Document these commands in `README.org`.

## Workflow jobs and dependencies

Trigger checks on branch pushes and pull requests targeting main. Avoid path filters initially so changes to tasks, tests, release logic, and generator configuration always receive coverage. Use `contents: read` by default and disable persisted checkout credentials in read-only jobs.

| Job | Commands and conditions |
| --- | --- |
| `workflows` | `mise run workflows-check` on a native Linux runner |
| `check-stable` | Matrix for 29.4 and 30.1; print build description, verify SQLite/FTS5/trigram support, run `mise run check`; disable matrix fail-fast |
| `check-master` | Print build description and run the same checks; job may fail and is excluded from release dependencies |
| `release-validation` | Full history and tags; run `mise run release-test`, then a release dry-run with branch checking disabled and explicit no-release handling |
| `release` | Only a push to main in `djgoku/compilation-history`; needs `workflows`, `check-stable`, and `release-validation` |

The separate master job preserves the current policy without making publication wait for an experimental build. GitHub supports failure policy at the job level; see its [job matrix guidance](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations).

Use cache keys that include the relevant tool versions, operating system, and configuration hashes. Treat caches as optional: a cold run must still pass. Extra platforms, scheduled runs, and new Emacs version coverage are separate changes.

## Automatic release behavior

The release job checks out the tested event SHA with full history and tags, creates a local `main` branch at that SHA, and sets GitHub Actions bot identity. Immediately before publishing, fetch main and skip if the tested SHA is no longer the remote tip. Never publish newer code that has not passed this run's checks. Keep normal non-force pushes so a later concurrent main change causes a visible failure.

Serialize publishers with a repository-wide release concurrency group and `cancel-in-progress: false`. Apply cancellation only at the check-job level, with separate groups for matrix entries; never use cancelling workflow-level concurrency because it would also interrupt the publisher. A running publisher must not be interrupted by a newer push. Concurrency does not replace the freshness check. See [GitHub concurrency controls](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

Grant `contents: write` only to the publishing job. Supply its token for authenticated Git pushes and as `GITHUB_TOKEN` for the existing script's gh preflight. Begin with the built-in token; verify repository rules permit the release commit before cutover. If rules require a designated bot, use a GitHub App token with explicit permission rather than weakening branch protections. See [GitHub token permissions](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

Replace the current `mise run release || echo "Nothing to release"` wrapper. Add an opt-in `--allow-no-release` flag to the release task: only the existing no-releasable-commits condition becomes a successful no-op. Preserve default CLI behavior and let authentication, dirty-tree, collision, push, and API failures fail the job. Use this flag for both CI dry-runs and automatic publishing, with regression coverage in `tests/test-release.sh`.

Push only the new tag and release branch, preferably together with an atomic push. Creating the GitHub release remains a separate operation: report an API failure and the already-pushed tag clearly, and recover that release explicitly rather than rerunning the version bump. Retain the existing release commit's `[skip ci]` behavior.

## Migration sequence

1. Add pinned generator tooling, the Pkl workflow source, generation/verification tasks, and documentation. Validate rendering and actionlint locally.
2. Add the generated GitHub workflow with publishing disabled. Run the stable matrix, advisory master job, and release validation alongside Cirrus. Check cold-cache behavior and ordinary branch/PR events.
3. Adapt release no-op handling, checkout, credentials, and serialization. Run the existing release tests plus the new no-op/failure cases. Verify token compatibility with repository rules without creating a production release.
4. Switch to a single publisher: disable Cirrus publishing, drain or cancel its queued/running publishers, and confirm none remain before enabling GitHub publishing. Remove `.cirrus.yml`, `.cirrus.Dockerfile`, and the commented Cirrus tool declaration when parity checks pass. Update required status checks to the GitHub names during cutover.
5. Observe the first main run and confirm exactly one release commit, tag, and GitHub release. If publishing fails, disable GitHub publishing, drain or cancel queued/running publishers, identify whether a tag was already pushed, and recover before restoring the Cirrus publisher. Never run both publishers together.

The migration's conventional `ci:` commits can themselves trigger a patch release under the existing version policy. A planning commit with a non-conventional subject avoids introducing a version bump on its own.

## Acceptance criteria

- A clean regeneration changes no committed outputs; a changed or missing output fails verification. Actionlint accepts the generated workflow.
- The full stable ERT and melpazoid checks pass on 29.4 and 30.1. A master failure leaves stable results and publishing eligibility intact.
- Release-script tests and dry-runs pass for branch and PR checkouts with full tags and history. No-releasable-commits is the only tolerated release no-op.
- A release dry-run changes no files, commits, tags, or remote state. Fork PR checks need no publishing credentials.
- Publishing requires all required jobs for the same tested main SHA. Obsolete runs skip publishing; publishers are serialized.
- Repository rules permit the selected publisher identity. The first main release produces exactly one version update, tag, and GitHub release.
- Cirrus configuration is removed after cutover, and README instructions reproduce workflow generation and the CI commands locally.
