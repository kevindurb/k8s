# Design

## Context

See proposal.md for motivation. Current state (verified on the VM 2026-11-27): Fedora 44
bootc, SELinux enforcing, `user.max_user_namespaces=15129`, `fuse-overlayfs`, `passt`,
`crun`, `conmon`, `shadow-utils` (newuidmap/newgidmap) installed; `slirp4netns` not
installed (fine — podman 5 defaults to pasta). No `runner` user exists;
`/var/lib/forgejo-runner` (incl. `.runner` credentials and `.cache/act`) is root-owned;
both `forgejo-runner.service` and `podman-gc.service` are root with no `User=`;
`tailscaled` is a root system service (stays that way). Jobs execute via the host
backend as the daemon's uid (root).

## Goals / Non-Goals

**Goals:**
- Job steps (and the runner daemon) run as an unprivileged `runner` user.
- Rootless podman works for that user for the existing workloads
  (`podman run/build/push` with `-v $PWD:/work:Z` style bind mounts).
- Delivery through the standard image rebuild → disk repack → pinned-tag bump path,
  keeping the image the source of truth for VM configuration.
- `tailscaled` remains root; tailnet grants unchanged.

**Non-Goals:**
- No tailnet policy changes (`tag:ci` grants stay as-is, including `tag:router:22` root SSH).
- No changes to workflow files (pip warnings inside job containers remain; fix belongs in workflows).
- No container-per-job backend change; host backend stays.
- No SELinux policy changes; no `--privileged` anything.
- Not making job steps safe against *other* job steps: all jobs of a run share the
  `runner` uid and filesystem view. Isolation between jobs is out of scope (single
  trusted-tenant forge).

## Decisions

### 1. Dedicated `runner` user, daemon runs as it
`User=runner` / `Group=runner` drop-in (or edit the unit in the image) for
`forgejo-runner.service`; `podman-gc.service` switches likewise (it prunes the
*rootless* store of the runner user; a root prune would no longer see those images).
`/var/lib/forgejo-runner` and its contents are owned by `runner:runner`. Alternative
considered: keep the daemon as root and drop privileges per-step — the host backend has
no such knob; rejected. Alternative considered: cloud-init-only override of a
root-built image — rejected as drift away from the bootc image-as-source-of-truth
model; the user/units belong in the image.

### 2. Rootless podman via newuidmap + linger, no rootful fallback
- `/etc/subuid` / `/etc/subgid`: `runner:165536:65536` (non-overlapping with system uids).
- `loginctl enable-linger runner` so `XDG_RUNTIME_DIR`/`/run/user/<uid>` exists for the
  system service and rootless podman works without an interactive session. The unit sets
  `Environment=XDG_RUNTIME_DIR=/run/user/<uid>` explicitly so it does not depend on
  login-session semantics.
- SELinux stays enforcing; rootless podman with container-selinux and `:Z` on the
  job workdir is the expected path. No booleans, no permissive domains.
- `slirp4netns` is not added; pasta (installed) is podman 5's default rootless network.

### 3. Delivery via image rebuild, not cloud-init surgery
Add to `containers/ci-runner/` in `kevindurb/bootc`: user creation, subuid/subgid,
linger enablement, `User=` in the units, `chown` of the state dir. Then rebuild:
`ci-runner` image → release `ci-runner-disk/<date>` → `build-runner-disk.yml` repacks
and cosigns → bump `containerDisk` tag + pinned-digest comment in
`infrastructure/ci-runner/vm.yaml` → merge → Argo sync → VM recreation.
Cloud-init (`ci-runner-cloudinit`) is unchanged except it no longer needs any
privilege adjustments; registration runs as `runner` (or chowns the handful of files
it writes) and the token file handling is unchanged.

### 4. Re-registration on recreation: presume the token is single-use
The VM's disk is ephemeral; every recreate re-registers via cloud-init using the sealed
`ci-runner-cloudinit` token. Whether the current token tolerates reuse is unverified
and irreversible to test casually. Decision: **mint a fresh runner registration token
and re-seal `ci-runner-cloudinit` before the first VM recreation**, and delete the
stale `ci-runner` entry in forgejo → Site administration → Runners after the new one
comes online. (If the fresh-token path fails, fall back to chowning the old `.runner`
— but only with the old sealed secret intact, so resealing is additive, not destructive.)

### 5. tailscaled stays root; no grants change
Jobs lose the ability to drive tailscaled (root-only socket) without any policy edit —
that is the security win. `tag:ci`'s grants (router SSH, Aperture, Argo CD, forgejo)
remain untouched per owner decision; revoking them is a separate tailnet-policy
conversation in `kevindurb/infra`, deliberately out of scope here.

### 6. Scope guard: no new privileges for jobs
No sudoers entry, no setuid helpers, no group memberships beyond `runner`. Workflows
that need host root simply fail — that is the intended contract and is documented in
`docs/forgejo.md`.

## Risks / Trade-offs

- [Rootless podman + SELinux `:Z` relabel failure on the job workspace] → Verify
  end-to-end with the `networking` repo workflow (bind mount `$PWD:/work:Z`) before
  declaring done; fallback is `:z` (shared) or `--userns=keep-id` in the workflow, but
  the stock workflow is expected to work unmodified.
- [Rootless overlay unsupported → storage falls back or fails] → `fuse-overlayfs` is
  already in the image; kernel supports userns overlays (`user.max_user_namespaces` ok);
  fallback storage driver is fuse-overlayfs, not vfs.
- [Stale `.runner` ownership mismatch after switch] → state dir chowned in image; fresh
  token minted pre-recreation (Decision 4) removes dependence on reusing it.
- [`podman system prune` as `runner` misses nothing but operators run it as root
  expecting emptiness] → documented; the root store stays empty by construction.
- [Jobs that silently relied on host root] → none exist today (dotfiles, networking,
  mirror all run inside containers or pure userland); CI going red post-cutover is the
  detection mechanism, and rollback is reverting the image pin.

## Migration Plan

1. **bootc repo**: implement image changes; build; publish release asset; `build-runner-disk` → new `ci-runner-disk` tag; verify cosign signature.
2. **k8s repo**: bump `vm.yaml` pin (tag + digest comment); update `docs/forgejo.md` ("Job environment" section) in the same commit.
3. **Pre-flight**: mint fresh registration token; re-seal `ci-runner-cloudinit` (additive); confirm `just check-kustomize` passes.
4. **Cutover**: merge; Argo syncs; VM recreates on the new image; verify in forgejo that runner `ci-runner` is Online; delete the stale runner entry if duplicated.
5. **Verify**: re-run `networking` CI (exercises rootless podman + bind mount) and `dotfiles` CI (pure userland); spot-check `id` output in a job log shows uid ≠ 0; `kubectl get vmi` shows the new pin.
6. **Rollback**: revert the `vm.yaml` pin to the previous tag; VM recreates on the old image (root jobs return); re-register only if the old token is still valid, else re-seal the old-style secret from the pre-change backup.

## Open Questions

- None blocking. (Whether the old registration token is reusable remains unknown and is
  handled by Decision 4 rather than investigated.)
