# Proposal

## Why

CI jobs on the forgejo runner execute as **root on the VM** (the `forgejo-runner` systemd unit has no `User=`, and host-backend jobs inherit it). That is more privilege than any current workload needs: the motivating jobs (chezmoi/shellcheck for dotfiles, ansible syntax-check for networking, the GitHub mirror) never use host privileges — the only rootful consumer ever contemplated, image builds, stayed on GitHub Actions. Running as root needlessly exposes the VM's tailnet identity (`tag:ci`, incl. the `tag:ci → tag:router:22 root` SSH grant and `tag:ai` quota), `/root`, the podman store, and the runner's own credentials to every job step, including steps pulled from public action repos. The jobs themselves already work fine unprivileged.

## What Changes

- **Image (`kevindurb/bootc`, `containers/ci-runner/`)**: create a dedicated `runner` user in the image; run `forgejo-runner.service` (and `podman-gc.service`) as `runner` via `User=`/`Group=`; add `/etc/subuid` and `/etc/subgid` entries and enable user lingering so rootless podman works; set the working state directory (`/var/lib/forgejo-runner`) ownership to `runner`; registration during cloud-init runs as `runner` (or is chowned immediately after).
- **Image rebuild path**: rebuild the bootc image and qcow2, publish via the existing release-asset → `build-runner-disk.yml` flow, cosign, and bump the pinned `containerDisk` in `infrastructure/ci-runner/vm.yaml` (new tag). The VM recreates from the new image; cloud-init re-registers it.
- **No behavioral change to tailnet grants**: `tag:ci` keeps its current grants (including `tag:router:22` root SSH and Aperture) — explicitly out of scope for this change.
- **No change to job containers**: `pip`/other "running as root" warnings that originate *inside* job containers (e.g. `python:3.13-slim`) are out of scope; only the host uid of the job process changes.
- **Not supported after this change**: job steps that require host root (e.g. `dnf` on the host, writing outside the job workspace). No current workflow does this.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `forgejo-runner`: job steps run as a dedicated non-root user instead of root; podman runs rootless for that user. The existing "Podman works natively in job steps" requirement changes from a *rootful* to a *rootless* runtime expectation, and a new requirement pins the non-root execution contract.

## Impact

- `kevindurb/bootc` `containers/ci-runner/`: Containerfile (user creation, subuid/subgid, linger, package set if anything is missing), systemd unit drop-ins or edited unit files.
- `kevindurb/k8s` `infrastructure/ci-runner/vm.yaml`: bump pinned `ci-runner-disk` tag (+ comment). `docs/forgejo.md`: update the "Job environment" section.
- **Registration token caveat**: the current registration token's reusability is unverified; a fresh token should be minted and resealed before VM recreation, or `.runner` must be preserved/chowned instead of re-registering.
- Rootless podman must be verified end-to-end (the `networking` repo's `podman run -v $PWD:/work:Z` job is the acceptance test).
- Risk: rootless podman + SELinux enforcing, `:Z` relabel of the job workdir, and lingering/XDG_RUNTIME_DIR setup are the known friction points; kernel userns is available (`user.max_user_namespaces=15129`).
