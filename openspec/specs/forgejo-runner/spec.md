# forgejo-runner Specification

## Purpose
An Actions-compatible runner for the forgejo instance that executes workflow
jobs inside a KubeVirt VM — giving CI jobs a real kernel, native podman, and
the GitHub-hosted-runner experience without privileging any pod.

## Requirements

### Requirement: CI executes in a KubeVirt VM, not in pods

The runner SHALL be a KubeVirt `VirtualMachine` running a bootc-based Fedora
image built from `kevindurb/bootc` (`containers/ci-runner`). No pod in any
namespace SHALL gain new privileges to support CI; the VM boundary is the
isolation boundary.

#### Scenario: Workflow job executes

- **WHEN** a workflow run is triggered on a migrated repository
- **THEN** the job runs inside the runner VM and its steps execute there
- **AND** no privileged container exists in the kubernetes manifests for this change

### Requirement: The VM image is built and signed like the node image

The `ci-runner` image SHALL be built in CI from `kevindurb/bootc`, published to
GHCR, converted to a qcow2 containerDisk, and cosign-signed, exactly like the
cluster node image. The pinned containerDisk reference SHALL be recorded in the
VM manifest.

#### Scenario: Reproducible image

- **WHEN** the `ci-runner` build runs twice from the same source commit
- **THEN** the published disk artifact is traceable (digest + signature) to that commit

#### Scenario: VM boots the pinned disk

- **WHEN** the VM spec references `ghcr.io/kevindurb/ci-runner-disk:<tag>`
- **THEN** the VM boots that exact image or fails visibly; it never silently floats to a different tag

### Requirement: Podman works natively in job steps

Workflows SHALL be able to run `podman build`, `podman push`, and
`podman login` unmodified. The runner image SHALL include podman, git, and a
working rootful container runtime (storage driver native overlay; `vfs` as the
documented fallback).

#### Scenario: podman build in a job

- **WHEN** a workflow job runs `podman build -t test .`
- **THEN** the build completes and the image is stored in the VM's local store

#### Scenario: push to GHCR

- **WHEN** a job provides a valid GHCR token as a secret
- **THEN** `podman push ghcr.io/kevindurb/<name>:<tag>` succeeds

### Requirement: Runner placement and capacity

The VM SHALL schedule only on drone worker nodes (drone-01..03), never on
control-plane nodes or drone-04; it SHALL use at most 4 GiB RAM and 2 vCPUs;
it SHALL run at most one job at a time; its root disk SHALL be ephemeral
(recreate = clean slate).

#### Scenario: Node placement

- **WHEN** the VM is (re)created
- **THEN** it lands on drone-01, drone-02, or drone-03

#### Scenario: Concurrency

- **WHEN** two workflow runs are queued
- **THEN** the second waits for the first to finish

### Requirement: Registration is secret-managed and rotatable

The forgejo runner registration token SHALL be supplied via a SealedSecret
injected at boot (cloud-init), never stored in git or in the image. Rotating
the token SHALL require only recreating the VM.

#### Scenario: Clean boot registers the runner

- **WHEN** the VM boots from a fresh overlay
- **THEN** the runner appears Online in forgejo within a few minutes
- **AND** no plaintext token exists in git or in the image

### Requirement: Workflow CI parity for dotfiles

The `dotfiles` repo SHALL carry `.forgejo/workflows/ci.yml` running at least the
checks the retired Tekton pipeline ran: chezmoi template render (dry-run) and
shellcheck of shell sources. A deliberately broken template on a scratch branch
SHALL fail the workflow (verified before the migration is declared done).

#### Scenario: Healthy main is green

- **WHEN** a commit lands on dotfiles `main`
- **THEN** the workflow completes successfully and the result shows on the commit

#### Scenario: Broken template goes red

- **WHEN** a commit with an unmatched `{{` is pushed to a scratch branch
- **THEN** the workflow fails at the render step

### Requirement: Image-building repos build green on the runner

Each image-building repository migrated to forgejo SHALL have its workflow
running on the forgejo runner, producing images pushed to GHCR with the same
tags and tags/digests semantics as before the migration.

#### Scenario: Table-stakes image build

- **WHEN** an image-building repo pushes to its default branch
- **THEN** the workflow builds the image with podman and pushes to GHCR
- **AND** the job shows green in forgejo

### Requirement: The runner VM is a Tailscale device tagged `tag:ci`

The runner VM SHALL join the tailnet on every boot using a reusable,
pre-authorized, ephemeral auth key that carries the `tag:ci` tag. The key
SHALL come from a `SealedSecret` in the cluster and SHALL NOT be baked into
the image or committed in plaintext. The tailnet device entry SHALL be
ephemeral so VM recreation does not accumulate stale devices, and
re-creation SHALL require no manual tailnet administration.

#### Scenario: Fresh VM joins on boot
- **WHEN** the VM boots (first boot or recreation from a new image pin)
- **THEN** it registers with MagicDNS as `ci-runner` tagged `tag:ci` within a few minutes and `tailscale status` on the host shows it connected
- **AND** no plaintext key exists anywhere outside the sealed secret

#### Scenario: Ephemeral device hygiene
- **WHEN** the VM is recreated from a new `ci-runner-disk` tag
- **THEN** the previous device entry expires automatically and the new VM re-joins without human intervention in the tailnet admin console

### Requirement: The VM reaches forgejo through its own tailnet identity

The VM SHALL resolve and reach `forgejo.beaver-cloud.ts.net` over the tailnet as `tag:ci`, granted `tag:apps:443` in the tailnet policy. It SHALL NOT depend on the LAN router hairpin (`tag:router`) or on node-originated forwarding for its CI traffic.

#### Scenario: Runner polls forgejo over the tailnet
- **WHEN** the runner dials `https://forgejo.beaver-cloud.ts.net`
- **THEN** the connection is carried by the VM's tailnet interface, sourced from `tag:ci`, and authorized by an explicit `tag:ci → tag:apps:443` grant

#### Scenario: Router path is no longer required
- **WHEN** the LAN router stops forwarding CGNAT destinations
- **THEN** the runner's reachability to forgejo is unaffected

### Requirement: The runner has the same tailnet grants as GitHub Actions CI

`tag:ci` SHALL authorize the VM to reach Aperture (`tag:ai:443`, `ci-agents` bucket, `deepseek`-class models), tsgit (`tag:tsgit:443`, read, `cap/repo`), and Argo CD (`svc:argocd:443`). No additional per-service plumbing is required in the VM image for these.

#### Scenario: A CI job calls Aperture
- **WHEN** a job in the runner calls the Aperture gateway with `tag:ci` credentials
- **THEN** it receives the same `ci-agents` quota treatment as a GitHub Actions runner

### Requirement: Inbound access is Tailscale SSH for admins only

The VM SHALL run `tailscaled` with SSH enabled. The tailnet policy SHALL grant `group:admins` SSH access to `tag:ci` (users `root` and `autogroup:nonroot`). No other inbound access to the VM SHALL be granted, and no SSH path via the LAN/router SHALL be relied on.

#### Scenario: Admin SSHes to the runner
- **WHEN** a `group:admins` member runs `ssh root@ci-runner` (with Tailscale SSH enabled)
- **THEN** access is granted per the tailnet SSH policy without any VM-side sshd password or extra keys

#### Scenario: Non-admin has no inbound path
- **WHEN** a non-admin tailnet member attempts to SSH to `ci-runner`
- **THEN** the Tailscale SSH policy denies it

### Requirement: MagicDNS resolution inside the VM

The VM SHALL run with MagicDNS enabled (`accept-dns`), resolving `*.beaver-cloud.ts.net` names to tailnet addresses inside the VM. LAN DNS answers are not required for the runner's tailnet traffic.

#### Scenario: VM resolves a tailnet name
- **WHEN** a job resolves `forgejo.beaver-cloud.ts.net` inside the VM
- **THEN** it gets the tailnet VIP, not an answer from the LAN resolver
