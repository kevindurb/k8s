# Spec Delta

## Purpose

Provide a git forge that is reachable only from the Tailscale tailnet, authorizes peers from their tailnet identity, and durably stores bare git repositories on cluster storage.

## ADDED Requirements

### Requirement: Tailnet-only reachability

The deployed tsgit instance SHALL join the tailnet as a node named `tsgit` and serve git smart HTTP and its repository index only through that tailnet node. It MUST NOT publish any listener reachable from the cluster network, the LAN, or the public internet, and no cluster `Service` or `Ingress` SHALL be required to reach it.

#### Scenario: Authorized peer uses the forge

- **WHEN** a tailnet peer covered by a `cap/repo` grant opens `https://tsgit/` or clones `https://tsgit/<namespace>/<repo>.git`
- **THEN** the request is served by the tsgit pod over its tailnet listener
- **AND** the peer sees only repositories its grant allows and whether it may push

#### Scenario: Peer without a grant is refused

- **WHEN** a tailnet peer without a matching `cap/repo` grant requests any tsgit path
- **THEN** tsgit returns `404` for every path, revealing nothing about repository existence

#### Scenario: No cluster-side exposure exists

- **WHEN** the rendered manifests for the app are inspected
- **THEN** they contain no `Service` and no `Ingress`
- **AND** the only ports declared on the container are documentation of the in-pod tailnet listeners, not host or cluster exposures

### Requirement: Persistent node identity and repository storage

The deployment SHALL keep the tsnet state directory and the repository root on two separate persistent volumes so that a pod replacement preserves both the node registration and every repository, and so the state volume can be excluded from repository backups.

#### Scenario: Pod is recreated

- **WHEN** the pod is deleted or rescheduled onto another node
- **THEN** it reuses the same state volume and the same repository volume
- **AND** the node keeps its tailnet registration without needing a new auth key
- **AND** previously pushed repositories remain clonable

#### Scenario: State volume is lost but repositories are kept

- **WHEN** only the state volume is recreated
- **THEN** the pod registers as a fresh node when given a valid auth key
- **AND** the repositories on the repository volume are unaffected

### Requirement: Single active instance

The deployment SHALL run at most one tsgit pod at any time.

#### Scenario: Rolling update or reschedule

- **WHEN** the pod is replaced, through an image update, a manual restart, or a node drain
- **THEN** the old pod is fully terminated before the new one starts
- **AND** two pods never hold the same node identity or the same read-write volumes concurrently

### Requirement: Repository creation on first push

A tailnet identity with write access SHALL be able to create a repository by pushing to a path that does not yet exist, and the new repository SHALL then be listed in the index and clonable by any identity with read access.

#### Scenario: First push creates the repository

- **WHEN** a write-capable identity runs `git push` to `https://tsgit/<namespace>/<name>.git`
- **THEN** tsgit creates a bare repository at that path using the configured default branch
- **AND** the push succeeds and later clones of that path work

#### Scenario: Read-only identity cannot create

- **WHEN** an identity with read-only access pushes to a repository that does not exist
- **THEN** the push is rejected and no repository is created

### Requirement: Secret handling for node registration

The Tailscale auth key SHALL be supplied to the pod only from a cluster `Secret` unsealed from a committed `SealedSecret`; no plaintext auth key SHALL appear in the repository. The auth key SHALL only be required for initial or replacement node registration.

#### Scenario: Fresh state volume registers with the sealed key

- **WHEN** the pod starts with an empty state volume and the unsealed auth key present
- **THEN** it registers on the tailnet, applies `tag:tsgit`, and writes its node state to the state volume

#### Scenario: No plaintext secret is committed

- **WHEN** the change is reviewed in git
- **THEN** the only auth-key artifact is a `SealedSecret`
- **AND** neither the manifests nor the change artifacts contain a `tskey-` value

### Requirement: Least-privilege runtime

The tsgit container SHALL run as its image's non-root user (`10001:10001`) with a read-only root filesystem, no privilege escalation, and all Linux capabilities dropped. Its only writable locations SHALL be the two persistent volumes and a temporary directory for `TMPDIR`.

#### Scenario: Pod admitted under the namespace policy

- **WHEN** the pod is created in the `tsgit` namespace, which enforces the `baseline` Pod Security Standard and warns/audits on `restricted`
- **THEN** it is admitted without Pod Security violations
- **AND** writes outside the persistent volumes and the temporary directory fail rather than silently persisting

### Requirement: GitOps-managed lifecycle

The app SHALL be delivered by Argo CD from this repository: an `Application` in the `apps` project pointing at `apps/tsgit`, registered in `apps/kustomization.yml`, with automated sync, self-healing, and pruning disabled. The `tsgit` namespace SHALL be created by that `Application` with the pod security labels used by the other apps.

#### Scenario: Sync from a clean cluster

- **WHEN** Argo CD syncs the `tsgit` application against a cluster without the namespace or workload
- **THEN** it creates the `tsgit` namespace with the standard pod security labels, the sealed secret, both PVCs, and the deployment

#### Scenario: Drift is corrected

- **WHEN** the live deployment is edited outside git
- **THEN** Argo CD reverts it on the next reconcile

#### Scenario: App is removed from git

- **WHEN** the `./tsgit/app.yml` line is removed from `apps/kustomization.yml`
- **THEN** Argo CD stops managing the application but does not delete its resources, matching the repo-wide `prune: false` policy

### Requirement: Outbound connectivity only

The tsgit pod SHALL reach the Tailscale control plane and tailnet peers over unrestricted egress; the deployment SHALL NOT add a `NetworkPolicy` that blocks those flows.

#### Scenario: No NetworkPolicy is attached

- **WHEN** the rendered manifests are inspected
- **THEN** no `NetworkPolicy` selects the tsgit pod
- **AND** the pod can resolve and connect to `controlplane.tailscale.com`, DERP relays, and peer endpoints
