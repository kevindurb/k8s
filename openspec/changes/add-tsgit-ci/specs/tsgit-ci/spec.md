# Spec Delta

## Purpose

Continuous integration for git repositories hosted on the `tsgit` forge — builds that run automatically when code is pushed, without tsgit itself needing webhooks, serverside hooks, or any CI feature of its own.

## ADDED Requirements

### Requirement: Pushes trigger builds without forge support

The system SHALL detect new commits pushed to a registered repository by polling and SHALL start a build for each newly observed commit within one poll interval plus build scheduling latency, without any webhook, server-side hook, or API call into tsgit beyond git smart-HTTP reads.

#### Scenario: New commit on main triggers a build
- **WHEN** a new commit lands on the tracked branch of a registered repository
- **THEN** a build for that commit starts within one poll interval

#### Scenario: No change means no build
- **WHEN** a poll finds no new commits on any tracked ref
- **THEN** no build is started and no state changes beyond the poll record

#### Scenario: First registration builds once
- **WHEN** a repository is registered with the poller for the first time
- **THEN** exactly one build of the current head runs, and later polls only build on subsequent pushes

### Requirement: Polling state survives restarts

The system SHALL persist the last-built commit per tracked ref outside any ephemeral pod filesystem so that a restart of the poller does not re-trigger already-built commits.

#### Scenario: Poller restarts between polls
- **WHEN** the poller pod is recreated and the last known state still exists
- **THEN** no duplicate builds are started for commits that were already seen

### Requirement: No credentials for tsgit access

Build pods and the poller SHALL reach tsgit without any tsgit credential (no token, SSH key, or password); access SHALL be authorized solely by the tailnet identity of an egress path from the cluster, limited to read access on the repositories being built.

#### Scenario: Build clones without secrets
- **WHEN** a build checks out the repository
- **THEN** the clone succeeds using only the cluster's tsgit egress identity, and no git credential is mounted or present in the pod

#### Scenario: Identity cannot write
- **WHEN** a build attempts a push to tsgit
- **THEN** the push is rejected by tsgit's authorization

### Requirement: Builds run in isolation

Each build SHALL execute in freshly created pods with no shared writable state with other builds, and a failed build SHALL NOT affect the outcome or artifacts of other builds.

#### Scenario: Failed build does not affect subsequent build
- **WHEN** a build fails partway through
- **THEN** a subsequent triggered build starts from a clean workspace and is unaffected by the failed build's leftovers

### Requirement: Build results are observable

An operator SHALL be able to see, for every build, its repository, commit, status, and full logs, through an interface served only on the tailnet.

#### Scenario: Inspect a failing build
- **WHEN** a build has failed and an operator opens the CI dashboard from the tailnet
- **THEN** the failing step and its logs are visible without shell access to the cluster

#### Scenario: Dashboard is not publicly reachable
- **WHEN** a request to the dashboard originates outside the tailnet
- **THEN** the request is refused

### Requirement: Repository registration is GitOps-managed

The set of repositories registered for polling SHALL be defined in this repository and applied by Argo CD; adding or removing a repository SHALL NOT require manual cluster interaction.

#### Scenario: Add a repository
- **WHEN** a change listing an additional repository is merged and synced
- **THEN** the poller begins watching that repository without any manual cluster operation

### Requirement: dotfiles validation pipeline

The `dotfiles` repository SHALL have a pipeline that renders every chezmoi template and statically checks the shell scripts it contains, and SHALL report success only when both pass.

#### Scenario: Template error fails the build
- **WHEN** a push leaves a chezmoi template that does not render
- **THEN** the build fails and the failure is visible in the dashboard

#### Scenario: Clean push passes
- **WHEN** a push renders all templates and passes the shell checks
- **THEN** the build succeeds

### Requirement: Bounded resource use

The CI system SHALL bound its footprint: builds SHALL run with requests/limits on CPU and memory, concurrent builds SHALL be capped, and completed run history SHALL be pruned to a bounded retention.

#### Scenario: Flood of pushes
- **WHEN** many commits land in quick succession across registered repositories
- **THEN** builds queue or are superseded rather than exhausting cluster memory or CPU
