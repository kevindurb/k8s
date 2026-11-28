# Spec Delta

## ADDED Requirements

### Requirement: Job steps execute as a non-root user

The runner daemon and every job step it spawns SHALL run as a dedicated unprivileged `runner` user inside the VM, not as root. The VM's `tailscaled` SHALL remain a root system service (unaffected). Job steps SHALL NOT be able to use `sudo` or otherwise escalate to root on the host.

#### Scenario: Job step runs unprivileged

- **WHEN** a workflow job runs a step such as `id` or `whoami`
- **THEN** the process runs as the `runner` user, not uid 0

#### Scenario: Job cannot reach the host's tailscaled control socket as root operations

- **WHEN** a job step attempts to run `tailscale ssh` or otherwise drive the host tailscaled
- **THEN** the attempt fails for lack of privilege (the socket is root-only), so job compromise does not yield tailnet SSH as root

#### Scenario: Job cannot modify the host system

- **WHEN** a job step attempts to write outside its workspace and the `runner`-owned state directories (e.g. `/etc`, `/var/lib/forgejo-runner/.runner`, other users' files)
- **THEN** the write fails with a permission error

#### Scenario: Runner daemon starts on a fresh VM

- **WHEN** the VM boots from a fresh overlay
- **THEN** the `forgejo-runner` service (and the podman GC timer) run as `runner`, the `runner` user owns the runner state directory, and the runner registers/comes online as before

## MODIFIED Requirements

### Requirement: Podman works natively in job steps

Workflows SHALL be able to run `podman build`, `podman push`, and
`podman login` unmodified. The runner image SHALL include podman, git, and a
working rootless (unprivileged) container runtime for the `runner` user; job
containers run under the `runner` user's user namespace, not as real root.

#### Scenario: podman build in a job

- **WHEN** a workflow job runs `podman build -t test .`
- **THEN** the build completes and the image is stored in the `runner` user's rootless image store

#### Scenario: push to GHCR

- **WHEN** a job provides a valid GHCR token as a secret
- **THEN** `podman push ghcr.io/kevindurb/<name>:<tag>` succeeds

#### Scenario: bind-mounted workspace is writable inside the container

- **WHEN** a job runs `podman run -v "$PWD:/work:Z" <image>` against the job workspace
- **THEN** the container can read (and writes only with the expected same-uid semantics) the mount without root privileges on the host
