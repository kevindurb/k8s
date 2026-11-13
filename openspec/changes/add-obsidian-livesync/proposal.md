# Proposal

## Why

Obsidian notes are currently synced with Syncthing, which has no iOS client. Adding a phone to the note workflow therefore means replacing file-level sync with a server the Obsidian LiveSync plugin can reach over HTTPS. Every device already holds a full vault, so a small always-on CouchDB acts as the rendezvous mailbox: the phone can pull changes while the desktop is asleep.

The vault is new and empty, so there is no migration, no version history, and no live-file cutover to preserve — this can be built and rehearsed before any real notes exist.

## What Changes

- Add `apps/livesync`: a single-replica CouchDB Deployment serving only the Obsidian LiveSync replication protocol, on a `zfs-generic-nvmeof-csi` PVC.
- Expose it to the tailnet only, via the standard `Service` + `Ingress{ingressClassName: tailscale}` + `ingress-proxy-group` pattern at `https://livesync.<tailnet>.ts.net`. No Funnel, no LAN or cluster-wide listener, no public exposure.
- Add CORS headers for the Obsidian desktop and mobile origins and require authentication for every request, so an unauthenticated request to `/` returns `401`.
- Seed the vault database and its non-admin user once at startup; the admin credentials and the plugin user password live only in committed `SealedSecret`s.
- Add a Gatus endpoint that treats `401` on `/` as healthy, proving both liveness and that authentication is enforced.
- Keep the Syncthing application unchanged: it continues to serve its other folders, and stops being used for the Obsidian vault.

## Capabilities

### New Capabilities

- `obsidian-sync`: Tailnet-only Obsidian vault synchronisation served by CouchDB — authenticated access, TLS on a tailnet hostname, per-vault database, single active writer, persistent storage, and no public reachability.

### Modified Capabilities

None.

## Impact

- New Kustomize root `apps/livesync` (`app.yml`, `kustomization.yml`, `deployment.yml`, `sealed-secret.yml`, `gatus.yml`), registered in `apps/kustomization.yml`.
- New namespace `livesync` with the standard baseline-enforce / restricted-warn pod security labels; Argo CD manages it through a new `Application` in the `apps` project.
- New persistent volume on the `zfs-generic-nvmeof-csi` class hosted on drone-04; `ansible/reboot-drone-04.yml` already discovers and scales workloads on that class, so no playbook change.
- New `SealedSecret`s created with the existing kubeseal flow; no plaintext secret is committed.
- Client-side setup (Obsidian plugin install, E2EE passphrase, Setup URI distribution, `.obsidian` sync strategy) is operational work documented in the design, not code changes in this repository.
- No change to `apps/syncthing`, the Syncthing volume, or any other application. No new infrastructure component and no HTTPRoute/Gateway resources.
