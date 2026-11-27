# forgejo Specification

## Purpose
A self-hosted, tailnet-only git forge replacing tsgit: repository hosting with
a web UI, pull requests and issues, signed-in via the cluster's OIDC provider,
with git access over HTTPS and SSH.

## Requirements

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

- **WHEN** a tailnet peer runs `git clone ssh://forgejo-ssh.beaver-cloud.ts.net/…`
  (the SSH LoadBalancer is `forgejo-ssh` because the `forgejo` MagicDNS name is
  taken by the HTTPS ingress VIP)
- **THEN** the connection succeeds and authenticates as the peer's configured user

### Requirement: Single sign-on via pocket-id

The web UI SHALL authenticate users via OpenID Connect against the cluster's
pocket-id instance. Local password login SHALL NOT be usable for day-to-day
sign-in; CLI/API access SHALL use SSH keys or personal access tokens. A
break-glass local admin account SHALL exist for recovery, with its password in
a SealedSecret.

#### Scenario: Web login via OIDC

- **WHEN** a user opens the forge and chooses to sign in
- **THEN** they are redirected to pocket-id and returned with a session, with no local password prompt

#### Scenario: Git CLI authentication

- **WHEN** a user clones or pushes over SSH
- **THEN** authentication uses their SSH public key registered in forgejo
- **AND** no pocket-id interaction occurs per git operation

### Requirement: Repositories are private by default and mirrorable

Repositories SHALL be private unless explicitly made public, and SHALL support
push mirroring to external hosts. The `kevindurb/dotfiles` repository SHALL
push-mirror to `github.com/kevindurb/dotfiles` over HTTPS using a scoped
credential.

#### Scenario: New repository visibility

- **WHEN** a repository is created without an explicit visibility choice
- **THEN** it is created private

#### Scenario: Dotfiles mirror updates

- **WHEN** a commit lands on the default branch of the forge's `dotfiles`
- **THEN** the push mirror to `github.com/kevindurb/dotfiles` is updated without manual intervention

### Requirement: Migration completeness

The `kevindurb/dotfiles` repository SHALL exist on forgejo with its full git
history, and every repository migrated in this change SHALL be reachable (clone
and push) over both HTTPS and SSH before the change is considered complete.

#### Scenario: History preserved

- **WHEN** `git log` is compared between the old tsgit copy and forgejo's `dotfiles`
- **THEN** commit SHAs match for the shared history

### Requirement: Forge data durability

Forgejo's state (repository storage + metadata database) SHALL live on
persistent volumes on node-local storage surviving pod restarts and
rescheduling, and SHALL be covered by the cluster's zfs replication of
node-local pools.

#### Scenario: Pod restart preserves repositories

- **WHEN** the forgejo pod is deleted and recreated
- **THEN** all repositories, issues, and users are intact

### Requirement: Repository creation on first push

An authenticated user with write access to a namespace SHALL be able to create a repository in that namespace by pushing to a path that does not yet exist, without going through the web UI or API. A push to a nonexistent path in a namespace the user may not write to SHALL be rejected and SHALL NOT create a repository. Push-created repositories SHALL be private unless the pusher explicitly opts out with the `repo.private` push option.

#### Scenario: First push creates a private repository in the user's namespace

- **WHEN** a signed-in user runs `git push` to a path such as `<user>/<name>.git` that does not yet exist
- **THEN** forgejo creates the repository `<user>/<name>`, the push succeeds, and the repository is private

#### Scenario: First push creates a private repository in an organization

- **WHEN** a user who is a member of an organization with permission to create repositories there pushes to `<org>/<name>.git`, a path that does not yet exist
- **THEN** forgejo creates the repository `<org>/<name>`, the push succeeds, and the repository is private

#### Scenario: Push to an organization without permission is rejected

- **WHEN** a user without repository-creation permission for an organization pushes to `<org>/<name>.git`, a path that does not exist
- **THEN** the push is rejected and no repository is created

#### Scenario: Push-created repository made public explicitly

- **WHEN** a user pushes to a nonexistent path with the push option `repo.private=false`
- **THEN** the repository is created and is not private

#### Scenario: Repository created on push honors write access, not anonymity

- **WHEN** an unauthenticated client attempts to push to a path that does not exist
- **THEN** authentication fails and no repository is created
