# forgejo Specification

## Purpose

A self-hosted, tailnet-only git forge replacing tsgit: repository hosting with a
web UI, pull requests and issues; sign-in via the cluster's OIDC provider; and
GitHub-Actions-compatible CI executed inside a KubeVirt VM where workflows may
run `podman` natively.

## ADDED Requirements

### Requirement: Tailnet-only reachability

The forge SHALL be reachable only from within the tailnet or the cluster
network. The web UI and git-over-HTTPS SHALL be served through the shared
Tailscale ingress; git over SSH SHALL be served through a Tailscale
LoadBalancer service. No listener SHALL be exposed on the LAN or the public
internet, and no MetalLB reservation SHALL exist for the forge.

#### Scenario: Tailnet peer opens the web UI

- **WHEN** a tailnet peer opens `https://forgejo.beaver-cloud.ts.net/`
- **THEN** the forgejo web UI is served

#### Scenario: Peer outside the tailnet

- **WHEN** a client that is neither on the tailnet nor inside the cluster attempts to connect to the forge's HTTP or SSH endpoints
- **THEN** the connection fails (no route, no listener)

#### Scenario: Git over SSH

- **WHEN** a tailnet peer runs `git clone ssh://forgejo/…`
- **THEN** the connection succeeds and authenticates as the peer's configured user

### Requirement: Single sign-on via pocket-id

The web UI SHALL authenticate users via OpenID Connect against the cluster's
pocket-id instance. Local password login SHALL NOT be usable for day-to-day
sign-in; CLI/API access SHALL use SSH keys or personal access tokens.

#### Scenario: Web login via OIDC

- **WHEN** a user opens the forge and chooses to sign in
- **THEN** they are redirected to pocket-id and returned with a session, with no local password prompt

#### Scenario: Git CLI authentication

- **WHEN** a user clones or pushes over SSH
- **THEN** authentication uses their SSH public key registered in forgejo
- **AND** no pocket-id interaction occurs per git operation

### Requirement: Repositories are private by default and mirrorable

Repositories SHALL be private unless explicitly made public, and SHALL support
pull mirroring for ingestion and push mirroring to external hosts. The
`kevindurb/dotfiles` repository SHALL push-mirror to `github.com/kevindurb/dotfiles`
over HTTPS using a scoped credential.

#### Scenario: New repository visibility

- **WHEN** a repository is created without an explicit visibility choice
- **THEN** it is created private

#### Scenario: Dotfiles mirror updates

- **WHEN** a commit lands on the default branch of the forge's `dotfiles`
- **THEN** the push mirror to `github.com/kevindurb/dotfiles` is updated without manual intervention

### Requirement: In-forge CI via a KubeVirt runner VM

Workflow runs SHALL execute on a forgejo-runner registered to this instance and
running inside a KubeVirt VM built from the `ci-runner` image maintained in the
`kevindurb/bootc` repository. The runner VM SHALL provide a working, rootful
`podman`, `git`, and standard build tools so workflow steps can run
`podman build`, `podman push`, and language toolchains unchanged from their
GitHub-hosted equivalents.

#### Scenario: Public image build workflow

- **WHEN** a workflow on an image-building repository runs `podman build -t … .` on the runner
- **THEN** the image builds and, given registry credentials, pushes to GHCR without modification to the podman invocation

#### Scenario: Podman is usable unprivileged-looking but works

- **WHEN** a workflow step runs `podman info`
- **THEN** it succeeds (rootful podman inside the sandboxed VM), with overlay storage or a configured fallback driver

### Requirement: Runner placement and concurrency limits

The runner VM SHALL schedule only on the drone worker nodes (never the unimatrix
control plane, never drone-04), SHALL be sized 2–4 vCPUs and at least 4 GiB RAM,
and SHALL run one job at a time. The VM SHALL boot from an ephemeral disk;
runner state (workspace, podman cache) MAY be wiped on restart without data loss
beyond in-flight job failure.

#### Scenario: VM placement

- **WHEN** the VM is (re)created by Argo CD or manually
- **THEN** it lands on a drone worker, never on a control-plane node or drone-04

#### Scenario: Concurrent job deferral

- **WHEN** one workflow run is active and a second push triggers another
- **THEN** the second queues until the first finishes

### Requirement: Runner registration is secret-managed

The runner's registration token SHALL be delivered to the VM via a SealedSecret
injected at boot (cloud-init), never committed in plaintext, and rotation SHALL
be possible by updating the secret and recreating the VM.

#### Scenario: Fresh VM boot

- **WHEN** the runner VM is created from the VM manifest
- **THEN** it registers itself with forgejo and appears online within minutes
- **AND** no plaintext token exists in git

#### Scenario: Token rotation

- **WHEN** the sealed secret is replaced with a new token and the VM is recreated
- **THEN** the new runner instance registers and the old one is de-registered or expires

### Requirement: Repository CI parity for dotfiles

The `dotfiles` repository SHALL have a workflow in `.forgejo/workflows/`
performing at least the checks the retired Tekton pipeline performed: chezmoi
template render (dry-run) and shellcheck of shell sources. A deliberately
broken template SHALL fail the workflow on a throw-away branch before the
pipeline is declared done.

#### Scenario: Green dotfiles run

- **WHEN** a commit lands on `main` in the dotfiles repository
- **THEN** the workflow runs and passes, visible in the forgejo UI and as a commit status

#### Scenario: Broken template fails the check

- **WHEN** a branch introduces an unmatched `{{` in a template
- **THEN** the workflow fails and the failure is visible on the commit

### Requirement: Forge data durability

Forgejo's state (repository storage + metadata database) SHALL live on
persistent volumes on node-local storage surviving pod restarts and rescheduling,
and SHALL be included in whatever backup story the cluster has for PVCs.

#### Scenario: Pod restart preserves repositories

- **WHEN** the forgejo pod is deleted and recreated
- **THEN** all repositories, issues, and users are intact

### Requirement: Migration completeness

The `kevindurb/dotfiles` repository SHALL exist on forgejo with its full git
history, and pushes to forgejo's `dotfiles` SHALL propagate to GitHub via the
push mirror. Image-building repositories migrated to forgejo SHALL have their
workflows running green before this change is considered complete.

#### Scenario: History preserved

- **WHEN** `git log` is compared between the old tsgit mirror and forgejo's `dotfiles`
- **THEN** commit SHAs match for the shared history

#### Scenario: Mirror sync

- **WHEN** a new commit is pushed to forgejo's `dotfiles/main`
- **THEN** `github.com/kevindurb/dotfiles` reflects it shortly after
