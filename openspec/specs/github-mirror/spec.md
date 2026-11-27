# github-mirror Specification

## Purpose

Keeps GitHub copies of forgejo-hosted repositories in sync by mirroring them
from forgejo CI, using short-lived GitHub App installation tokens instead of
long-lived personal tokens, so GitHub stays a read mirror without becoming a
source of long-lived credentials.

## Requirements

### Requirement: Mirror runs as CI, not as a forgejo-side push mirror

The mirror SHALL run as a forgejo Actions workflow in the mirrored
repository, not via forgejo's built-in push-mirror configuration. The mirror
logic SHALL be implemented as a composite action in `kevindurb/gh-mirror`
(forgejo on this instance cannot run cross-repo reusable workflows, but a
composite action call works); each repo opts in with a ~6-line caller
workflow.

#### Scenario: A repository opts in

- **WHEN** a forgejo repository gains a `.forgejo/workflows/mirror.yml`
  caller for the shared composite action
- **THEN** that repository is mirrored to GitHub on every trigger of the
  workflow, reusing the shared action rather than a copied implementation

#### Scenario: Pipelines are visible and debuggable

- **WHEN** a mirror run fails (e.g. GitHub unreachable, token rejected)
- **THEN** the failure appears as a failed workflow run in the caller
  repository with step logs, and not as a silently stale mirror

### Requirement: Authentication uses a short-lived GitHub App installation token

The mirror SHALL authenticate to GitHub by minting a GitHub App installation
token at run time (via `actions/create-github-app-token` or equivalent). No
long-lived GitHub credential (PAT or App private key used directly as an API
token) SHALL be passed to `git push`, and no GitHub credential SHALL be
committed to any repository.

#### Scenario: Token minted per run

- **WHEN** the mirror workflow runs
- **THEN** a token scoped to the installation of the mirror app is created for
  the run and is used for the push and the verification step

#### Scenario: Token lifetime

- **WHEN** the token has been minted
- **THEN** it is an installation token with a maximum lifetime of one hour and
  is never written to git, logs, or artifacts

### Requirement: The app holds least privilege

The GitHub App SHALL request only `contents: write` (to push refs) and
`workflows: write` (to update workflow files on the mirror) plus the mandatory
`metadata: read`. It SHALL NOT request `packages`, `administration`, or any
organization/account permissions. The private key SHALL be stored only in
forgejo (owner-level Actions secret), never in any GitHub or git location.

#### Scenario: Permission audit

- **WHEN** the app's permissions are reviewed on github.com
- **THEN** only `contents: write`, `workflows: write`, and `metadata: read`
  are granted

#### Scenario: Private key location

- **WHEN** the App private key is searched for in git history across the
  mirrored repositories
- **THEN** it is not present in any of them

### Requirement: What gets mirrored

The mirror SHALL force-update `refs/heads/*` and `refs/tags/*` on the GitHub
repository so GitHub exactly matches forgejo for branches and tags. It SHALL
NOT delete refs on GitHub (no `--mirror`, no `--prune`): branches or tags
deleted on forgejo may linger on GitHub rather than risk deleting refs created
on GitHub (e.g. Renovate branches).

#### Scenario: Branch updated on forgejo

- **WHEN** a commit is pushed to a branch that exists on GitHub
- **THEN** the GitHub branch is force-updated to the same SHA as forgejo

#### Scenario: Branch deleted on forgejo

- **WHEN** a branch is deleted on forgejo
- **THEN** the mirror makes no change to GitHub refs, and the stale branch
  remains there until removed manually or by a separate deliberate process

#### Scenario: Tag pushed to forgejo

- **WHEN** a tag is pushed to forgejo
- **THEN** the tag appears on GitHub with an identical SHA

### Requirement: Result is verified after pushing

After pushing, the workflow SHALL compare the ref advertisement
(`git ls-remote`) of forgejo and GitHub for the mirrored namespaces and SHALL
fail the run if they differ.

#### Scenario: Successful mirror run

- **WHEN** the push completes and both remotes report identical
  `refs/heads/*` and `refs/tags/*`
- **THEN** the workflow exits successfully

#### Scenario: Divergent refs after push

- **WHEN** any mirrored ref differs between forgejo and GitHub after the push
- **THEN** the workflow fails and the discrepancy is visible in the run log

### Requirement: Missing GitHub repository fails loudly

The GitHub repository is a prerequisite created by the operator. The mirror
SHALL NOT attempt to create it (App installation tokens cannot create
repositories). If it is missing, the workflow SHALL fail with an explicit
message naming the repository to create.

#### Scenario: GitHub repository missing

- **WHEN** the mirror runs and the target GitHub repository does not exist
- **THEN** the workflow fails with a message naming the missing repository,
  and no refs are pushed anywhere

### Requirement: Scheduled self-healing

Opting-in repositories SHALL also run the mirror on a schedule and on manual
dispatch, so a missed or failed mirror run converges on a later run without
human intervention.

#### Scenario: Transient GitHub outage

- **WHEN** a push-triggered mirror run fails because GitHub is unreachable
- **THEN** a subsequent scheduled run pushes the missing refs successfully

### Requirement: Failure visibility

Mirror failures SHALL surface as failed workflow runs in forgejo for the
affected repository. The mirror SHALL NOT silently succeed when it pushed
nothing due to an error.

#### Scenario: Push rejected

- **WHEN** the push to GitHub is rejected (e.g. branch protection)
- **THEN** the workflow run is red and the log shows the rejection reason

#### Scenario: Nothing to sync is still green

- **WHEN** forgejo and GitHub already match
- **THEN** the workflow completes successfully without errors

### Requirement: GHCR pushes are out of scope

The mirror SHALL NOT attempt to push container images to ghcr.io or to any
registry. GitHub App installation tokens cannot push packages to GHCR, so any
GHCR push requirement remains on a GitHub PAT or on GitHub-hosted runners.

#### Scenario: Image-building repository opts in

- **WHEN** an image-building repository adopts the mirror workflow
- **THEN** only git refs are mirrored; image publishing remains on GitHub
  Actions and is unaffected
