# Design

## Context

See proposal.md. `add-forgejo` stands up the forge but adds no CI; the Tekton
stack still serves dotfiles. Two earlier experiments on this cluster settle how
jobs must run:

- Rootless podman/docker is impossible under the default seccomp profile
  (userns creation denied — reproduced 2026-11-27).
- Privileged `docker:dind` works, including `docker build`
  (`--storage-driver=vfs`; overlay-on-overlay fails with `EINVAL`), but every
  job becomes host-root-equivalent.
- Unprivileged "native k8s runner" projects are immature and would put jobs
  back into pods with the same syscall restrictions.
- A KubeVirt VM sidesteps all of it: real kernel, rootful podman, zero
  privileged pods.

## Goals / Non-Goals

**Goals:** CI for migrated repos on the forgejo runner with podman semantics
identical to GitHub-hosted runners; dotfiles CI parity with the Tekton pipeline;
GHCR publishing; GitOps-deployed runner VM (Argo CD).

**Non-Goals:** CD from forgejo; per-job ephemeral VMs (needs CDI + a controller —
revisit if queueing/cold-boot pain ever appears); multi-arch builds; replacing
`add-forgejo` (separate change); removing Tekton (that's `remove-tsgit-tekton`).

## Decisions

### 1. The runner lives in a VM, in a bootc-built image, in the bootc repo
`containers/ci-runner/Containerfile` in `kevindurb/bootc`:
`FROM quay.io/fedora/fedora-bootc:stable` + podman/buildah/git/forgejo-runner +
a systemd unit. Rationale: bootc is the machine-image factory this cluster
already trusts; runner image upgrades are then rename-and-bump like every other
node image. Publishing two artifacts from the same CI run:
`ghcr.io/kevindurb/ci-runner` (the OS image) **and**
`ghcr.io/kevindurb/ci-runner-disk` (same image compiled to qcow2 via
`bootc-image-builder`, wrapped `FROM scratch` as a KubeVirt containerDisk). The
containerDisk is what the VM actually boots; the OS image existing lets
`bootc switch` update semantics stay honest if the VM is ever long-lived.

### 2. KubeVirt containerDisk, not CDI
ContainerDisks need no CDI controller — virt-controller extracts the disk from
the OCI artifact directly. CDI would be needed only for per-job golden-image
clones, which are out of scope. This sidesteps installing a second operator
whose CRDs we just finished cleaning up.

### 3. One VM, capacity 1, ephemeral root
`2 vCPU / 4 GiB`, 20 Gi root on the containerDisk overlay, nodeAffinity to
drone-01..03, no drone-04, no control-plane. One job at a time (forgejo-runner
`capacity: 1`). Ephemeral overlay root: any state (podman storage, worktrees)
dies with the VM — intentional; nothing CI-worthy is precious. A stale VM is
recreated by deleting the virt-launcher pod.

### 4. Registration via SealedSecret + cloud-init, never in the image
cloudInitNoCloud (userData from a Secret) writes
`/etc/forgejo-runner/config.yaml` with the instance URL and a `tokenFile`
pointer, plus a `forgejo-runner-register.service` oneshot ordered before the
long-lived `forgejo-runner.service`. Token minted once in forgejo (admin API),
stored as `SealedSecret ci-runner-token`. Rotation = reseal + `kubectl delete
pod -l kubevirt.io=virt-launcher ...` equivalent (delete the VMI) — documented.

### 5. Workflows run on images from the registry, pinned by tag
`runs-on: [self-hosted, linux]`. Job images in workflows (`fedora-bootc`,
`alpine`, etc.) pin major tags like `:latest` today — acceptable for the runner
itself; workflows may pin as they please. GHCR credentials live in forgejo
secrets, not in the VM image.

### 6. Migration mechanics
- `dotfiles`: `.github/workflows` removed, `.forgejo/workflows/ci.yml` added:
  checkout → chezmoi (pinned, matching old pipeline) dry-run render → shellcheck
  on scripts/hooks. Verify red on a broken template before merging.
- image repos: same treatment; builds use `podman` unchanged; GHCR push via
  `REGISTRY_TOKEN`/`GITHUB_TOKEN`-style forgejo secret; GitHub workflows
  deleted in the same commit to avoid double-runs from the mirror.
- Rollback if forgejo CI proves flaky: repos still exist on GitHub via the
  mirror — re-enable there as a stopgap.

### 7. Where the VM runs and what happens on reboot
Drone worker, `RuntimeClass` default, QEMU with KVM. On node drain the VM
migrates... it does not (no live migration for a containerDisk-sourced VM
without CDI); instead the VM reschedules cold and re-registers. Rebuilds on
resumed nodes are unaffected. This is acceptable for an internal CI.

## Risks / Trade-offs

- [First-time `bootc-image-builder` in GH Actions is fiddly] → timeboxed; if
  it fights, fall back to `containerDisk` built from `fedora cloud + dnf
  install podman ... + cloud-init` via `osbuild-composer` or a manual qcow2
  wrapped in OCI — same artifact shape, different builder.
- [Runner registration token leaks] → sealed, mounted only into cloud-init;
  rotation path documented; token grants runner-scoped rights only.
- [Overlay disk fills with image cache mid-job] → podman `gc` cron in the
  image (hourly `podman system prune -f`); 20 GiB is generous vs job payloads.
- [VM downtime blocks all migrated CI] → single point of failure accepted
  (homelab); `systemd` restart + Argo selfHeal bounds outage to VM recreate
  (~1 min). Monitor via gatus blackbox TCP/HTTP check on forgejo only (VM has
  no stable URL — forgejo runner shows offline if VM dies, surfaced in UI).
- [job runs as root in VM] → inherent to podman-in-VM for this use case; the
  VM is disposable and single-tenant; acceptable for self-hosted repos.

## Migration Plan

1. Merge bootc change (image + disk) → confirm GHCR artifacts pull.
2. Apply `infrastructure/ci-runner` (Argo) → VM boots → runner appears Online.
3. `dotfiles`: new workflow file; merge; verify green; verify failure path.
4. Mirror the same pattern to the image-building repos, one at a time, each
   with a real push-driven green build.
5. When everything is green, `remove-tsgit-tekton` can proceed.

Rollback: delete the VM and the workflow files; repos are untouched.

## Open Questions

- Whether `ci-runner-disk` should be its own repo artifact vs a workflow
  artifact stored in GHCR as OCI — current plan: GHCR (keeps disk next to
  image; KubeVirt pulls it like any container image).
- Exact runner labels (`self-hosted, linux` vs adding `podman`) — cosmetic,
  decidable at implementation.
