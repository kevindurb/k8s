# Design

## Context

See proposal.md. Decisive facts established during exploration:

- Rootless containers are blocked on this cluster: RuntimeDefault seccomp denies
  the user-namespace path (`rootlesskit: fork/exec /proc/self/exe: operation
  not permitted`), `/dev/fuse` is absent, and `hostUsers: false` doesn't help.
  Verified on drone-02 on 2026-11-27 with `docker:29.0.2-dind-rootless`.
- Privileged dind works (`--storage-driver=vfs`; overlay-on-overlay fails with
  `invalid argument`) — but every workflow job becomes host-root-equivalent.
- The cluster already runs privileged infra (metallb, tailscale, zfs-exporter),
  so the bar for privilege is "justified", not "zero" — but CI jobs are
  arbitrary-ish code from git, so we don't hand them the node.
- Hence: CI runs in a KubeVirt VM. podman inside a real kernel behaves exactly
  as on a GitHub-hosted runner, which is the environment these repos' workflows
  were authored for.
- forgejo is the community fork of gitea with first-class Actions and the
  better governance story; pocket-id (already in `platform/`) provides OIDC
  out of the box.

## Goals / Non-Goals

**Goals:** tailnet-only forgejo; OIDC SSO; full git hosting with PRs/issues;
Actions-compatible CI in a VM runner with native podman; repo migration with
history preserved; GHCR remains the image registry; GitHub remains the public
read path via push mirror; zero new LAN exposure.

**Non-Goals:** CD/GitOps from forgejo (Argo stays the deploy path); replacing
GitHub for `k8s` itself; multi-arch builds; HA forgejo (single replica is
correct for a personal forge); per-job ephemeral VMs (needs CDI + a
controller; explicitly deferred); notifications/integrations beyond email if trivial.

## Decisions

### 1. Forgejo over Gitea
Fork governance is healthier (non-profit stewardship, Linux-tight roadmap),
Actions is first-class in both but forgejo's runner story (`forgejo-runner`)
is the reference, and the pocket-id docs cover OIDC setup verbatim. Both are
SQLite-capable, single-binary, and Helm-installable; the delta is ecosystem
trajectory, and it favors forgejo.

### 2. Helm chart (official `forgejo` chart) pinned by version, SQLite, zfs-local PVC
Options were raw manifests vs Helm. Helm wins on upgrade ergonomics (chart
tracks upstream releases, Renovate can bump it) and matches how the tekton
chart was consumed. SQLite is the chart default and is fine for a single-admin
forge; repos + DB live on one zfs-local PVC, inheriting zrepl replication for
free. Postgres would buy nothing at this scale and cost an operator or a
second stateful app. Alternative rejected: hand-rolled manifests (chart drift).

### 3. runner = KubeVirt VM, image built in `kevindurb/bootc`
The runner image is a sibling of the machine images: `containers/ci-runner/`
in kevindurb/bootc, `fedora-bootc` base (same family as the nodes/uCore
philosophy), adding `podman`, `git`, `git-lfs`, `buildah` (podman builds want
it), `forgejo-runner` (pinned release), `systemd` unit for the daemon, and
`cloud-init` (stock in bootc images). Built and pushed like the other machine
images (ghcr.io/kevindurb/ci-runner), then converted to a qcow2 with
`bootc-image-builder` and wrapped as a containerDisk (`ci-runner-disk`) that
KubeVirt boots.

Alternatives considered and rejected:
- **Privileged dind sidecar + jobContainers**: works (proven) but every job is
  host-root; not worth it now that VMs are on the table.
- **k8s-native runner (johbo/k8s-runner etc.)**: no VM boundary, immature
  projects, and jobs land back in pods with the same seccomp problems for
  anything beyond trivial shell.
- **Runner on a spare host**: we don't have a spare host (drones are all in
  the cluster; unimatrix nodes are control-plane).
- **GitHub-hosted runners for the migrated repos**: defeats "self-hosted forge
  with no external dependency for CI"; also GHCR push stays free either way.

### 4. Runner VM topology
2 vCPU / 4 GiB, 20 GiB ephemeral disk (containerDisk overlay — lost on
delete, which is fine and keeps nodes clean), nodeSelector `kubernetes.io/hostname` ∈
{drone-01, drone-02, drone-03} — never control-plane, never drone-04. One run
at a time (maxConcurrentRuns=1 in the runner config). Reaches forgejo over
ClusterIP; reaches the internet/GHCR directly. cloud-init injects the forgejo
runner registration token from a SealedSecret (mounted via `secretRef` in the
VM spec) — the image carries zero secrets; image can stay public.

### 5. Web exposure
Web UI + HTTPS git: `ingressClassName: tailscale` Ingress, `forgejo.beaver-cloud.ts.net`,
tag `tag:apps`. SSH git: `Service type: LoadBalancer` with
`loadBalancerClass: tailscale` (the minecraft pattern), ssh on tailnet port 22
as `forgejo`. Nothing on MetalLB, nothing on the LAN — the previously reserved
`.222` (forgejo ssh) is dropped in `remove-tsgit-tekton`.

### 6. Identity: OIDC for humans, keys/tokens for git
pocket-id is the only identity provider; local password login disabled except
a break-glass `forgejo-admin` account whose password lives in a SealedSecret.
git over SSH uses per-user keys; API/mirror automation uses a fine-grained
GitHub PAT (for the push mirror to GH) stored only in forgejo's DB (set via
first-boot CLI/provisioning, not committed) — forgejo stores mirror creds
internally, which is the designed mechanism.

### 7. Migration path
1. Forgejo up; OIDC login verified; SSH clone/push smoke-tested from a laptop.
2. Runner VM up; a `hello-world` workflow registered and green.
3. dotfiles: `git push --mirror` from a laptop clone (full history), push
   mirror configured to github.com/kevindurb/dotfiles, `.forgejo/workflows/ci.yaml`
   replaces `ci/pipeline.yaml` (chezmoi dry-run + shellcheck via podman or
   directly in the image — podman guaranteed).
4. Image-building repos, one at a time, each verified green (they mostly call
   `podman build/push` → works unchanged inside the VM; `REGISTRY` secrets move
   to forgejo secrets).
5. `remove-tsgit-tekton` unblocks once all are green.
Rollback at any point: tsgit/tekton untouched until step 5.

### 8. GHCR stays the registry
No reason to re-home images; Renovate keeps working; GHCR tokens already exist.
Forgejo's built-in registry deliberately unused.

## Risks / Trade-offs

- [OIDC lockout (pocket-id down / client secret misconfigured)] → Break-glass
  admin account (sealed); document recovery in the new docs page.
- [Runner VM dies mid-build] → Ephemeral disk; job fails, retry re-queues;
  nothing else stateful lost. Persistent build cache is a non-goal for v1.
- [Image pull rate limits / boot time on fresh VM] → runner image is small
  (fedora-bootc + podman ≈ few hundred MB); ghcr anonymous pulls fine; node
  disk cache makes re-pulls cheap.
- [Push mirror fights direct GitHub pushes] → treat GitHub as read-only mirror
  once migrated; document; mirror only `dotfiles` initially.
- [Forgejo upgrade breakage] → sqlite + chart pin + Renovate; snapshot PVC via
  zfs before upgrades (aligns with existing zrepl replication).
- [Seeding forgejo means one more forge to forget about] → that's the point;
  docs land in `docs/forgejo.md` and gatus gets a check.

## Migration Plan

See Decisions (7). Rollback is free until `remove-tsgit-tekton` merges: destroy
the forgejo namespace/VM/app, nothing else has moved.

## Open Questions

- Final list of "image-building repos" to migrate — to be enumerated at the
  start of the implementation (likely the ghcr publishers: minecraft,
  consignment-app, etc.); scoped then, not now.
- Whether to also mirror `dotfiles`' issues/PRs — almost certainly no
  (fresh forge, fresh tracker); confirm during migration.
