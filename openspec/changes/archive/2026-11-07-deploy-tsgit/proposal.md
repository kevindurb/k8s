# Proposal

## Why

`kevindurb/tsgit` is a git forge that runs as a Tailscale node: it serves git smart HTTP only to tailnet peers and authorizes them from their Tailscale identity, so it needs no public listener, no TLS setup and no account database. It is already built and published as a container image, but nothing in this repo deploys it. Running it through Argo CD like every other app makes the forge reproducible, self-healing and stored next to the rest of the homelab configuration.

## What Changes

- Add a new `apps/tsgit` app directory following the standard app layout: `app.yml`, `kustomization.yml`, `deployment.yml`, and a sealed secret for the Tailscale auth key.
- Run one `Deployment` (strategy `Recreate`, `replicas: 1`) with two `zfs-generic-nvmeof-csi` PVCs: a small **state** volume (tsnet node key, never backed up) and a larger **repos** volume (bare git directories, the durable data).
- Wire the app into `apps/kustomization.yml` so Argo CD creates the namespace and syncs it.
- Configure the node via `TSGIT_HOSTNAME=tsgit` and `TS_ADVERTISE_TAGS=tag:tsgit`, supply `TS_AUTHKEY` from the sealed secret, and keep the image's own `TSGIT_STATE_DIR` / `TSGIT_REPO_ROOT` defaults.
- Give the pod an explicit `securityContext` for UID/GID `10001` (the image's user). The shared `app-pod-hardening` component hardcodes UID/GID `1000` and would break the container, so it is deliberately not used (same precedent as `apps/immich`).
- Mount an `emptyDir` at `/var/lib/tsgit/tmp` (the image's `TMPDIR`) because the root filesystem stays read-only; no other writable paths are added.
- Deliberately **no** `Service`, **no** `Ingress` and **no** Gatus endpoint check: tsgit's listeners live in its own userspace tailnet stack, so nothing inside the cluster can dial it. A `gatus.yml` will therefore not be created for this app, deviating from the usual per-app convention (documented in design.md).
- Prerequisites outside this repo, called out in tasks: the GHCR package must be made public (owner's decision, so no image pull secret is stored in the cluster), and the tailnet policy must own `tag:tsgit` and grant the `github.com/kevindurb/tsgit/cap/repo` capability. Without the policy, every request returns `404` by design.

No existing app or capability is modified. Nothing is removed.

## Capabilities

### New Capabilities

- `tsgit`: deploying and operating tsgit as a tailnet-only git forge on the homelab cluster — persisted node identity and repositories, tailnet-only reachability, sealed auth key, and the deliberate absence of in-cluster Service/Ingress/monitoring wiring.

### Modified Capabilities

_None._

## Impact

- New files: `apps/tsgit/app.yml`, `apps/tsgit/kustomization.yml`, `apps/tsgit/deployment.yml`, `apps/tsgit/auth-sealed-secret.yml`.
- Modified: `apps/kustomization.yml` (one `./tsgit/app.yml` resource).
- Argo CD: new `Application` `tsgit` in project `apps`, namespace `tsgit`, automated sync (`prune: false`, `selfHeal: true` like every other app).
- Cluster storage: two new PVCs on `zfs-generic-nvmeof-csi` (ZFS zvols on drone-04, exported over NVMe-oF/TCP), so tsgit depends on drone-04 and the `reboot-drone-04.yml` playbook already handles scaling it down.
- Cluster networking: no Service, no Ingress, no Tailscale operator involvement; the pod needs unrestricted egress to Tailscale's control plane, DERP relays and tailnet peers, so no `NetworkPolicy`.
- Secrets: one `SealedSecret` (`tsgit-auth`) holding `TS_AUTHKEY`, sealed against namespace `tsgit`.
- External repos/systems: GitHub package visibility for `ghcr.io/kevindurb/tsgit`; `kevindurb/infra` tailnet policy (`tagOwners` for `tag:tsgit` plus the capability grant); a Tailscale auth key that may apply `tag:tsgit`.
- Validation: `kustomize build apps/tsgit` and `just check-kustomize`.
