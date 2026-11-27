# Proposal

## Why

`tsgit` is the canonical host for the owner's git repos, but it has no web UI,
no pull requests, no issues, and no commit-status API, and its CI story (Tekton
+ poller replacement + a webhook EventListener) is a lot of bespoke plumbing
built solely because tsgit is minimal. The owner wants the opposite trade: a
real forge (browse, PRs, issues) with the industry-standard CI model
(GitHub-Actions-compatible workflows), self-hosted on the same tailnet, while
keeping the cluster's tailnet-only posture. The build pods that image-building
repos need cannot run as unprivileged pods (proven impossible on this cluster's
seccomp/PSS posture), and kubevirt (installed by `install-kubevirt`) restores
that capability by giving CI a real VM.

## What Changes

- **Forgejo** is deployed as the git forge (web UI + HTTPS git + SSH), reachable
  only over the tailnet (HTTP(S) via the shared Tailscale ingress; SSH via a
  tailnet `LoadBalancer` service — no LAN listener, no public exposure).
- **Pocket-ID OIDC** is the sign-in for the web UI; git CLI access uses SSH
  keys (or PATs for HTTPS). **No** allow-everything-anonymous mode.
- **Forgejo Actions** becomes the CI engine. A long-lived
  **`ci-runner` VM** (KubeVirt, guest = Fedora bootc image built in
  `kevindurb/bootc` as `containers/ci-runner`, published as a signed container
  disk) runs `forgejo-runner`. Inside the VM, `podman` is fully native, so
  existing `podman build`-style workflow steps run unchanged.
- **VM placement**: drone-01..03 (never the unimatrix control-plane nodes,
  never drone-04 the storage node). 2 vCPU / 4 GiB, one job at a time,
  ephemeral root disk; registration via a SealedSecret-provided token in
  cloud-init; VM reaches forgejo over the cluster network.
- **Repository migration**: `kevindurb/dotfiles` (and the image-building
  repositories, enumerated during implementation) move to forgejo with full
  history. Push mirrors to GitHub keep GitHub as the public read path; GHCR
  remains the container registry.
- **Tekton is NOT removed by this change** — removal is `remove-tsgit-tekton`,
  which lands only after forgejo CI is proven green on migrated repos.
- **dotfiles CI** moves from `ci/pipeline.yaml` (Tekton) to
  `.forgejo/workflows/` with the same checks (chezmoi dry-run + shellcheck).
- The `kevindurb/bootc` repository gains a `containers/ci-runner/` image and a
  build step producing a qcow2 → containerDisk artifact (`bootc-image-builder`),
  signed with the same cosign flow as the other images.

## Capabilities

### New Capabilities
- `forgejo`: the self-hosted forge — tailnet-only exposure, OIDC SSO, repository
  hosting and mirroring, and Actions CI executed in a KubeVirt VM running a
  bootc-based runner image with native podman.

### Modified Capabilities
- None.

## Impact

- New `platform/forgejo/` (or apps/, decided in design) Argo app; new
  `infrastructure/ci-runner/` VirtualMachine; new SealedSecrets (OIDC client,
  runner registration token, mirror credentials in forgejo config).
- New cross-repo work in `kevindurb/bootc`: `ci-runner` image + disk artifact.
- `apps/tsgit` and the Tekton stack stay untouched here (removed in
  `remove-tsgit-tekton`); this change also registers the dotfiles push-mirror
  to GitHub.
- `kevindurb/infra` (separate repo): no changes yet; tailnet grant cleanup
  happens in `remove-tsgit-tekton`.
- New RBAC: none for CI jobs (they run inside the VM, not as pods). The
  cluster gains the VM's virt-launcher pod and the forgejo app pod.
