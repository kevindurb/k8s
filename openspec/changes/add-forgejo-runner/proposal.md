# Proposal

## Why

`add-forgejo` gives the owner a forge they can push to, but it has no CI. The
existing Tekton stack works but is a heavyweight, bespoke path (vendored
Triggers + CEL webhook plumbing + tailnet egress). The image-building repos
migrated off GitHub need podman-capable runners — podman does not exist for
unprivileged pods on this cluster (verified: userns creation blocked by
RuntimeDefault seccomp), and privileged dind works but hands every job
host-root. The chosen answer: a KubeVirt VM (from `install-kubevirt`) booting a
purpose-built Fedora bootc runner image with podman — the podman UX the
owner's workflows already use.

## What Changes

- **Runner image** in `kevindurb/bootc`: new `containers/ci-runner/` building
  a Fedora bootc image (podman, git, buildah, pinned `forgejo-runner`), then a
  second stage packs it as a qcow2 → containerDisk, cosign-signed, published to
  ghcr.io.
- **Runner VM** in this repo (`infrastructure/ci-runner/`): a single-node
  `VirtualMachine` (2 vCPU / 4 GiB, 2–20 GiB disk, drones only), enrolled to
  forgejo via a SealedSecret registration token rendered by cloud-init;
  `forgejo-runner` runs as a systemd unit; one job at a time; ephemeral disk.
- **CI parity for `dotfiles`**: `ci/pipeline.yaml` (Tekton) is replaced by
  `.forgejo/workflows/ci.yml` performing chezmoi dry-run + shellcheck, going
  green on `main`.
- **CI for the image-building repos**: workflows migrated from
  `.github/workflows` to `.forgejo/workflows` (runner labels
  `[self-hosted, linux]`); `podman` commands unchanged; GHCR push via a
  scoped PAT in forgejo secrets; repos verified green one by one.
- Tekton is untouched by this change; removal happens in `remove-tsgit-tekton`.

## Capabilities

### New Capabilities
- `forgejo-runner`: a self-hosted Actions runner that executes workflow jobs
  inside a KubeVirt VM with full podman capability, registered to and managed
  by the forgejo instance.

### Modified Capabilities
- None.

## Impact

- Cross-repo work: `kevindurb/bootc` gains `containers/ci-runner/` + a
  bootc-image-builder → containerDisk packaging step + cosign signing.
- New Argo app `infrastructure/ci-runner/` (VM + SealedSecret), drone-node
  placement, `virt-launcher` pod in a dedicated namespace.
- Secrets: runner registration token (SealedSecret), GHCR push PAT (forgejo
  secret, not this repo).
- Behavior: every migrated repo's CI now runs on the forgejo runner; GitHub
  Actions for those repos are removed/disabled in their own repos.
- `install-kubevirt` must be applied first; `add-forgejo` must precede VM
  registration (needs a forgejo URL + token).
