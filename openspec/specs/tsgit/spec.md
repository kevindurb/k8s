# tsgit Specification

## Purpose

Provide a git forge that serves the Tailscale tailnet, authorizes peers from their tailnet identity, durably stores bare git repositories on cluster storage, and can publish a policy-selected, read-only subset of those repositories through Tailscale Funnel.

## Requirements

### Requirement: Tailnet access and opt-in public Funnel

The deployed tsgit instance SHALL join the tailnet as a node named `tsgit` and serve git smart HTTP and its repository index to tailnet peers only through that tailnet node. It MUST NOT publish any listener reachable from the cluster network or the LAN, and no cluster `Service` or `Ingress` SHALL be required to reach it. The only reachability from the public internet SHALL be the opt-in, read-only Funnel surface defined by the requirements below; with Funnel disabled, the instance SHALL remain tailnet-only.

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
- **AND** no container port is published on the node or the cluster network
- **AND** the pod reaches the internet only as outbound traffic or through the Funnel listener it opens inside its own tsnet stack

#### Scenario: Funnel is disabled

- **WHEN** the deployment does not set `TSGIT_FUNNEL` to a true value
- **THEN** no public listener is opened
- **AND** the forge is reachable only by tailnet peers

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

### Requirement: Funnel-capable image

The deployment SHALL run a published tsgit build that implements Funnel, referenced by digest so Argo CD cannot roll to a different build unnoticed. A build that does not accept the Funnel setting SHALL NOT be deployed.

#### Scenario: Deployed build supports Funnel

- **WHEN** the running pod is asked for its version and the Funnel setting is exercised
- **THEN** the reported build is a Funnel-capable build
- **AND** the process accepts the Funnel setting instead of rejecting it as an unknown flag

#### Scenario: Image reference is digest-pinned

- **WHEN** the rendered Deployment is inspected
- **THEN** the container image includes both a tag and a content digest
- **AND** no floating tag without a digest is used

### Requirement: Public read-only Funnel surface

When Funnel is enabled, the node carries the tailnet `funnel` attribute, and HTTPS certificate domains are available, the pod SHALL open a public listener that serves only clone/fetch and the discovery index filtered to the repositories selected by the node's `github.com/kevindurb/tsgit/cap/funnel` payload. Public requests SHALL use a synthetic read-only principal derived from that payload, never a tailnet identity, a remote address, a header, or a request body. The public view MUST NOT indicate that the viewer may push and MUST NOT show first-push instructions.

#### Scenario: Public clone succeeds

- **WHEN** a repository matches the `cap/funnel` payload and a client outside the tailnet clones it from the node's public URL
- **THEN** the client receives the repository contents

#### Scenario: Public index is filtered

- **WHEN** a client outside the tailnet opens the public URL
- **THEN** only repositories selected by the `cap/funnel` payload are listed
- **AND** no repository outside that selection is named

#### Scenario: Public write is refused

- **WHEN** a public client requests receive-pack or any other mutation
- **THEN** the request is refused with the same `404` used for an unreadable repository
- **AND** no backend process is started

#### Scenario: Public creation is refused

- **WHEN** a public client requests a repository path that does not exist
- **THEN** no repository is created and the response is `404`

#### Scenario: Public selection is empty

- **WHEN** no repository matches the `cap/funnel` payload
- **THEN** the public surface exposes no repository

#### Scenario: Policy change takes effect without a restart

- **WHEN** the tailnet policy adds or removes a public repository pattern
- **THEN** the next public request reflects the change
- **AND** the pod does not need to be restarted

### Requirement: Funnel enablement is explicit and fail-safe

The public listener SHALL be opened only when the deployment explicitly enables Funnel. If the node lacks the `funnel` attribute, HTTPS certificates, or a certificate domain, or if the public listener cannot bind, the pod SHALL log a prominent error, SHALL NOT open the public listener, and SHALL keep serving the tailnet exactly as before.

#### Scenario: All prerequisites are present

- **WHEN** the deployment enables Funnel and the node has the `funnel` attribute and a certificate domain
- **THEN** the public listener opens at the node's tailnet DNS name
- **AND** the tailnet listeners keep serving

#### Scenario: A prerequisite is missing

- **WHEN** the deployment enables Funnel but the `funnel` attribute, HTTPS, or a certificate domain is missing
- **THEN** the pod logs an error naming the missing prerequisite
- **AND** the public listener stays closed
- **AND** tailnet clone, push and discovery keep working

#### Scenario: Funnel is disabled after being enabled

- **WHEN** the deployment stops enabling Funnel and the pod is replaced
- **THEN** the public listener is no longer opened
- **AND** the tailnet path is unchanged

#### Scenario: Private repositories stay private

- **WHEN** Funnel is enabled and a tailnet identity with write access pushes to a repository that does not match the `cap/funnel` payload
- **THEN** the push succeeds as before
- **AND** the repository is not visible or clonable through the public URL

### Requirement: Bounded public requests

The public listener SHALL bound request headers, request bodies, request lifetimes, and concurrent pack exchanges. A declared body over the limit SHALL be refused before a backend starts, and an exhausted concurrency limit SHALL be refused with a retryable error rather than queued without bound.

#### Scenario: Oversized public request

- **WHEN** a public client declares a request body larger than the configured public limit
- **THEN** the request is refused with `413` before a backend starts

#### Scenario: Public concurrency limit reached

- **WHEN** the configured number of public pack exchanges is already running
- **THEN** a further public pack exchange is refused with `503` and a `Retry-After` header
- **AND** the tailnet listener is unaffected
