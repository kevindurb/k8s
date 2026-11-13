# Design

## Context

See `proposal.md` for motivation. Constraints that shape the approach:

- This repository is GitOps-only: manifests plus Argo CD, no application source. A new app is a Kustomize root under `apps/` with an Argo CD `Application` registered in `apps/kustomization.yml`.
- Two reachability patterns already exist: `Service` + `Ingress{ingressClassName: tailscale}` served by the `ingress-proxy-group` ProxyGroup (linkding, dufs, syncthing), and a pod that joins the tailnet itself via tsnet and therefore has no `Service` (tsgit).
- Cluster storage is `zfs-generic-nvmeof-csi`: single-replica ZFS zvols on drone-04, ext4, ReadWriteOnce. `ansible/reboot-drone-04.yml` discovers workloads on that class and scales them to 0 around a reboot, so nothing about that playbook needs to change.
- sanoid takes 24 hourly / 14 daily / 4 weekly snapshots of those zvols, unencrypted, so anything plaintext on the volume is plaintext in every snapshot.
- Namespaces use `baseline` enforce with `restricted` warn/audit. `components/app-pod-hardening` hardcodes uid/gid 1000 and a read-only rootfs; database containers in this repo (immich/miniflux postgres) instead carry explicit `securityContext` blocks.
- There is no S3/MinIO in the cluster, so livesync's object-storage backend would require a second new stateful service.
- Client behaviour that the server cannot change: Obsidian on iOS is suspended in the background, so it only syncs while the app is open; the phone must have the Tailscale VPN profile connected.

## Goals / Non-Goals

**Goals:**

- One always-on CouchDB that both desktop and iOS Obsidian clients replicate through, reachable only from the tailnet.
- Deterministic, repeatable bring-up from git: namespace, credentials, config, volume, workload, service, ingress, health check.
- Encryption-in-doubt: with E2EE enabled client-side, the server, its volume, and every sanoid snapshot hold only ciphertext.
- A setup that survives drone-04 reboots and pod reschedules without operator action.

**Non-Goals:**

- High availability. One replica, one storage node; downtime during a drone-04 reboot is accepted.
- Server-side backup tooling beyond the existing ZFS snapshots and the clients' own copies. No dump Job, no offsite replication.
- Serving notes over a web UI, public sharing, or Funnel exposure.
- Changing or removing `apps/syncthing`; that app keeps its other folders.
- Managing Obsidian client configuration. Plugin installation, E2EE choice, and `.obsidian` sync strategy are documented operational steps.

## Decisions

### CouchDB, not object storage or P2P

Object storage gives no continuous sync ("periodic or on-save") and would need a MinIO deployment that does not exist. P2P needs both devices online at once, which is exactly what the always-on mailbox removes. CouchDB is the only backend that gives real-time replication with an offline phone.

### `Service` + tailnet `Ingress`, not a tsnet pod

The tsgit pattern exists because that app's authorization model *is* tailnet identity. CouchDB has its own user database, so a pod-owned tailnet node buys nothing and costs a `Recreate`-only identity plus a hand-rolled listener. The operator already terminates TLS for `<host>.<tailnet>.ts.net` and issues the certificate, which is what iOS requires.

### No Funnel

The endpoint is tailnet-only by intent. Funnel would publish an authentication surface to the internet for a personal notes database, and the repo's convention is not to. The cost is that clients must be on the tailnet; that is accepted and visible in the plugin's status indicator.

### Official `couchdb` image, digest-pinned, single container

No sidecar proxy and no custom image. Renovate already manages tag+digest updates across the repo. The container is named `app` and its port `http` (5984), per repo convention.

### Config through a seeded `emptyDir`, never through the admin API

The CouchDB entrypoint `chmod`s files under `/opt/couchdb/etc` at start-up, which fails on a read-only rootfs and on a read-only config mount — a documented silent-crash trap upstream. The pod therefore:

- runs an init container that copies the image's `/opt/couchdb/etc` into a shared `emptyDir` and adds a `local.d/*.ini` from a ConfigMap,
- mounts that `emptyDir` at `/opt/couchdb/etc` in the main container.

The rootfs stays read-only. The consequence, accepted deliberately: the config directory is ephemeral, so runtime configuration changes made through the admin API are discarded on restart. Git is the sole source of configuration truth; the admin credentials are re-seeded from environment variables on every start.

Alternatives considered: writable rootfs (rejected: loses a hardening property for no benefit), `subPath` ConfigMap mounts (rejected: still hits the `chmod` failure), a custom image (rejected: unnecessary build pipeline).

### Database, user, and `_security` from a `postStart` hook

CouchDB must be running before its database can be created, so an init container cannot do this. A `postStart` shell hook waits for the local authenticated endpoint, then idempotently:

- creates the vault database (`PUT /<db>`, treating `412` as success),
- upserts the vault user document in `_users` with the password from the environment (treating `409` by re-reading the revision and updating, so rotating the sealed password and restarting is enough),
- sets `_security` so the vault user is the only member and admins are the only admins.

Alternatives considered: an Argo CD sync-hook Job (adds an object whose lifecycle interacts with `selfHeal` and `prune: false`), a separate init image (extra build), admin-only credentials (violates the scoped-user requirement). The hook runs on every container start and is safe to repeat; failures retry inside the script and end with a non-fatal exit only after the data operations have been attempted.

### Auto-compaction via config, not a CronJob

LiveSync writes many revisions per note. CouchDB's built-in compaction daemon is enabled by setting `[compactions] _default` thresholds in the mounted ini, so no scheduled job, no new object, no secret-bearing cron container. Manual `_compact` remains available for a one-off if needed.

### E2EE enabled by default

Chosen at first sync, because enabling it later re-uploads the vault. With it on, the CouchDB zvol and its sanoid snapshots contain opaque chunks, which is the only meaningful at-rest protection on a shared NAS. The real disaster-recovery artifact becomes the passphrase plus the Setup URI, stored outside the cluster; that is documented as an operational step rather than automated.

### `.obsidian` via Customisation Sync, not Hidden File Sync

Syncthing silently syncs the whole `.obsidian` directory. Full hidden-file sync under LiveSync would reproduce that but also make `workspace.json` (window layout, open tabs) fight between a phone and a desktop. Customisation Sync syncs an explicit list — plugins, snippets, themes, hotkeys — and is recommended; the client brings it up after basic note sync is verified.

### Monitoring expects `401`, probes authenticate

Gatus checks `http://livesync-app-service.livesync/` and requires `[STATUS] == 401`, which fails both when the service is down and when it wrongly accepts anonymous access. Kubernetes probes cannot use `401` (`httpGet` treats it as failure) and the 3.5 image turns out to protect `/_up` as well, so readiness, liveness, and startup run an `exec` shell check that requests `/_up` with the admin credentials from the environment and requires `200`. `tcpSocket` remains the fallback if the credentials ever become unusable for probes.

### One sealed secret, four keys

`metadata.name: credentials` becomes `livesync-credentials` after `namePrefix`. Keys: `admin-user`, `admin-password`, `vault-user`, `vault-password`. Admin credentials feed `COUCHDB_USER`/`COUCHDB_PASSWORD` only (first-boot admin seeding and the `postStart` API calls); the vault user is the only credential handed to phones and laptops. Rotation is "re-seal, restart"; the `postStart` upsert makes the vault password converge.

## Risks / Trade-offs

- **iOS only syncs while Obsidian is foregrounded** -> Set expectations in the bring-up steps; the plugin's status indicator is the signal. Editing offline is fine; open the app before relying on recent changes.
- **Phone silently stops syncing when Tailscale disconnects** -> Enable Tailscale's on-demand/always-on profile on iOS; the plugin status dot shows "stopped".
- **CORS mismatch works on desktop and fails on mobile** -> The bring-up checklist exercises an actual phone before the vault is considered done; origins are asserted explicitly in the manifests.
- **Entrypoint `chmod` vs read-only rootfs** -> The seeded `emptyDir` design; verify at first rollout that the container starts rather than crash-looping.
- **`/_up` auth assumption** -> Confirmed wrong on 3.5.3: `/_up` returns `401` unauthenticated. Probes authenticate with the admin credentials from the environment via `exec`; the Gatus `401` check is unchanged.
- **Unbounded revision growth** -> `_default` compaction thresholds; watch PVC usage occasionally.
- **E2EE passphrase loss is unrecoverable server-side** -> Passphrase and Setup URI stored in a password manager; devices remain full copies, so recovery from any device is also possible.
- **Single storage node; CouchDB is down during a drone-04 reboot** -> Clients queue changes and reconnect; the existing reboot playbook scales the workload down and back up automatically.
- **Admin credential rotation does not touch a running instance's `_users` docs** -> Vault password converges via `postStart`; admin password is configuration and is re-seeded from env at each start. Rotate by re-sealing and restarting.

## Migration Plan

Greenfield: no data migration and no cutover from a live vault.

1. Apply the app through Argo CD; confirm the namespace, sealed secret, PVC, deployment, service, and tailnet ingress exist and the pod is ready.
2. Run a rehearsal vault (a disposable database or a throwaway vault name) from the desktop, then from the phone over Tailscale, including an offline edit on each side and a deliberate `kubectl delete pod`.
3. Only then create the real vault, enable E2EE, and copy the Setup URI to each device.
4. Remove the Obsidian vault from Syncthing on each device as a client-side action once the rehearsal passes; `apps/syncthing` is untouched.

Rollback: delete the Argo CD `Application` and the namespace (or scale the deployment to 0). With E2EE on, the authoritative copies are the devices; without it, take a final CouchDB dump or ZFS snapshot first. If the approach is abandoned, nothing else in the cluster depends on this app.

## Open Questions

- Whether the phone joins the tailnet as an untagged personal device or a tagged one is decided in `kevindurb/infra`'s `tailnet/policy.hujson`, not here; the endpoint only needs the device to be on the tailnet.
- The database name (`obsidiannotes`) is an environment value; rename only if a second vault is planned immediately.
