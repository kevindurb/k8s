# Design

## Context

See proposal.md. Depends on nothing that doesn't exist yet (pocket-id is
already deployed in `platform/pocket-id`; the tailscale ingress pattern and the
`tailscale` LoadBalancer pattern are established by other apps). The CI runner
is deliberately absent here; it is `add-forgejo-runner`.

## Goals / Non-Goals

**Goals:** a daily-driver forge on the tailnet; GitHub kept as public mirror;
full-history migration of `dotfiles` (and the image-building repos once their
owners confirm the list).

**Non-Goals:** CI of any kind (Tekton stays until the runner change lands);
CD from forgejo; public access; GHCR migration; per-repo ACLs beyond default
private; importing issues/PRs (fresh tracker).

## Decisions

### 1. Forgejo over Gitea
Fork governance and the OIDC docs pocket-id links to; both are boring and
SQLite-capable, but Forgejo's release cadence and direction are healthier.

### 2. Official Helm chart, SQLite, zfs-local PVC
`helm` source in the Argo Application (chart `forgejo` from
`code.forgejo.org/forgejo-helm`), pinned by version, pocket-id values inline in
values.yaml, no hand-templated manifests. SQLite is the chart default and is
correct for one admin and a handful of repos; the `zfs-local` PVC inherits zrepl
replication for free. Postgres would add a stateful component for zero benefit.
Alternative rejected: raw manifests — chart drift for no gain.

### 3. Exposure: tailscale ingress (web/HTTPS-git) + tailscale LoadBalancer (SSH)
The ingress pattern every other tailnet app uses for HTTP; SSH is a raw TCP
service, so it gets a `type: LoadBalancer` with the tailscale class (the
minecraft pattern), hostname `forgejo` in MagicDNS. No MetalLB member is
consumed; the `.222` reservation stays unused and is removed later in
`remove-tsgit-tekton`.

### 4. Identity: pocket-id OIDC only, break-glass local admin
Disable local password sign-in after OIDC works; the admin account exists but
its password is a SealedSecret used only for lockout recovery. SSH keys and
PATs (not OIDC) authenticate git/API — standard forgejo splits, and PATs are
scoped per use.

### 5. Migration: `git push --mirror` from a laptop clone
No cluster-internal copying: clone from tsgit (tailnet), push to forgejo.
`--mirror` over `--all`/`--tags` to carry refs exactly. Verify SHA equality
between tsgit and forgejo after push. `dotfiles` first (it's the CI input for
the next change), then the image-building repos, enumerated during
implementation and confirmed with the owner.

### 6. Mirror to GitHub, not a GitHub dependency
`dotfiles` mirrors to `github.com/kevindurb/dotfiles` (branch mirror of
`main`), fed by a fine-grained GitHub PAT (Contents: read/write on the one
repo) stored only in forgejo's database (configured post-install via UI/CLI);
never committed. GitHub stays read-only public mirror; all pushes land on
forgejo.

### 7. Single namespace `forgejo`, PSS restricted/baseline
forgejo is a single non-root container; baseline suffices with restricted
warn/audit like its neighbors. No host mounts, no capabilities.

## Risks / Trade-offs

- [OIDC misconfig locks everyone out] → break-glass admin sealed; verify OIDC
  round-trip in a private window before disabling local sign-in.
- [Mirror fights direct GitHub pushes] → document `dotfiles` as mirror-only;
  consider protecting `main` on GitHub (branch protection) to enforce it.
- [SQLite corruption] → zfs replication covers the volume; periodic verified
  backups are a follow-up if the forge grows.
- [Fresh tracker loses history] → accepted deliberately; the migration moves
  git data, not project-management data.
- [Runner image unpinned until `add-forgejo-runner`] → fine; this change ships
  zero CI behavior.

## Migration Plan

1. Deploy app; wait for Argo sync + gatus green.
2. Create pocket-id OIDC client; wire forgejo; verify login; then restrict
   local sign-in.
3. Create repos; `push --mirror` from local clones; verify SHAs.
4. Configure + verify mirror to GitHub with a test commit.
5. Hand off to `add-forgejo-runner` for CI.
Rollback: remove the app and namespace; no other system depends on forgejo yet.

## Open Questions

- Final enumeration of image-building repos to migrate (needs owner confirmation
  at execution time; does not block this design).
- Whether migrated image repos also strip `.github/workflows` so CI doesn't
  double-run from the mirror — decided per-repo at migration time.
